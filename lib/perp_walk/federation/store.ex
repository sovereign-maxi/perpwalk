defmodule PerpWalk.Federation.Store do
  @moduledoc """
  GenServer-backed persistence for Federation entities.

  Currently owns a single ETS table — `payouts` — and
  serialises every write through the WAL so requests survive
  crashes. Mirror of `Markets.Store` in pattern but lighter
  (single entity for now; future Federation entities like
  signing-session state will live here too).

  ## Schema

  - `payouts` — `{request_id, %Payout{}}`

  ## Hot-path reads

  Direct `:ets.lookup/2` calls — same single-writer-many-readers
  pattern used elsewhere. The Store is the only writer.

  ## Sequence numbers

  Every WAL payload carries a monotonic `:seq` counter, advanced
  only on successful append. `apply_entries/2` validates seq
  monotonicity and emits a
  `[:perp_walk, :federation, :store, :wal_seq_anomaly]` telemetry
  event on a gap or non-increasing seq. See `Markets.Store` for
  the matching pattern.
  """

  use GenServer

  require Logger

  alias Locker.WAL.Entry
  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents
  alias PerpWalk.Federation.Payout
  alias PerpWalk.Storage.Facade, as: StorageFacade

  # Single primary ETS table — the module atom itself, per the
  # module-path naming convention. The two index tables follow the
  # same convention (submodule suffixes).
  @payouts_table __MODULE__
  @inflight_index_table :"#{__MODULE__}.InflightIndex"
  @payouts_by_status_table :"#{__MODULE__}.PayoutsByStatus"
  @payouts_by_position_table :"#{__MODULE__}.PayoutsByPosition"
  @payouts_by_kind_table :"#{__MODULE__}.PayoutsByKind"

  # In-flight payout statuses, sourced from `Payout.@type status`.
  # `list_in_flight_payouts/0` unions the by-status bag across
  # these keys.
  @in_flight_statuses [:pending, :rules_passed, :signing, :submitted, :awaiting_operator]

  @wal_types [
    :payout_requested,
    :broadcast_marker_set,
    :broadcast_marker_cleared,
    :processor_promotion
  ]

  # persistent_term key for the current processor promotion. Only ever
  # written by `apply_wal_entry(:processor_promotion, ...)` — never by
  # RPC-broadcast app-env writes, never by an operator direct call. The
  # WAL is the single source of truth so `Role.designated_processors/0`
  # can't diverge across guardians (which was the pre-fix split-brain:
  # partial `:rpc.call` propagation left two "processors" both driving
  # writes cluster-wide).
  @promotion_key {__MODULE__, :promotion}

  # --- Public Read API (direct ETS) ---

  @spec get_payout(binary()) :: {:ok, Payout.t()} | {:error, :not_found}
  def get_payout(id) when is_binary(id) do
    case :ets.lookup(@payouts_table, id) do
      [{^id, request}] -> {:ok, request}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  @spec list_payouts() :: [Payout.t()]
  def list_payouts do
    :ets.foldl(fn {_id, req}, acc -> [req | acc] end, [], @payouts_table)
  rescue
    ArgumentError -> []
  end

  @spec list_payouts_for_position(binary()) :: [Payout.t()]
  def list_payouts_for_position(position_id) when is_binary(position_id) do
    lookup_by_index(@payouts_by_position_table, position_id)
  end

  @spec list_payouts_by_status(Payout.status()) :: [Payout.t()]
  def list_payouts_by_status(status) when is_atom(status) do
    lookup_by_index(@payouts_by_status_table, status)
  end

  @spec list_payouts_by_kind(Payout.kind()) :: [Payout.t()]
  def list_payouts_by_kind(kind) when is_atom(kind) do
    lookup_by_index(@payouts_by_kind_table, kind)
  end

  @spec list_in_flight_payouts() :: [Payout.t()]
  def list_in_flight_payouts do
    Enum.flat_map(@in_flight_statuses, &list_payouts_by_status/1)
  end

  @doc """
  Aggregate signing activity over the trailing window (default 24h).
  Counts payouts that reached `:submitted` or `:paid_out` during the
  window and returns the most recent submission timestamp. Used by
  the admin dashboard's Wallet & Signing panel.

  Published surface diagnostic. Pure read-only, returns stable-shape
  diagnostic metrics, designed to be called from any consumer (admin
  dashboard, monitoring publishers).
  """
  @spec signing_stats(non_neg_integer()) :: %{
          signs_window: non_neg_integer(),
          last_sign_at: DateTime.t() | nil
        }
  def signing_stats(window_seconds \\ 86_400) do
    cutoff = DateTime.add(DateTime.utc_now(), -window_seconds, :second)

    {count, last_at} =
      list_payouts()
      |> Enum.reduce({0, nil}, fn payout, {acc, latest} ->
        if payout.status in [:submitted, :paid_out] and
             DateTime.compare(payout.updated_at, cutoff) == :gt do
          new_latest =
            cond do
              is_nil(latest) -> payout.updated_at
              DateTime.compare(payout.updated_at, latest) == :gt -> payout.updated_at
              true -> latest
            end

          {acc + 1, new_latest}
        else
          {acc, latest}
        end
      end)

    %{signs_window: count, last_sign_at: last_at}
  rescue
    _ -> %{signs_window: 0, last_sign_at: nil}
  end

  defp lookup_by_index(index_table, key) do
    case :ets.lookup(index_table, key) do
      [] ->
        []

      pairs ->
        for {_, payout_id} <- pairs,
            [{_, %Payout{} = p}] <- [:ets.lookup(@payouts_table, payout_id)],
            do: p
    end
  rescue
    ArgumentError -> []
  end

  # --- Write API ---

  @spec put_payout(Payout.t()) :: :ok | {:error, term()}
  def put_payout(request), do: put_payout(__MODULE__, request)

  @spec put_payout(GenServer.server(), Payout.t()) :: :ok | {:error, term()}
  def put_payout(server, %Payout{} = request) do
    write_call(server, {:put_payout, request})
  end

  @doc """
  Atomically inserts `request` if no in-flight payout exists for
  the same `position_id`. Returns `{:ok, request}` on success,
  `{:error, :payout_already_pending}` if a non-terminal payout
  for this position already exists.

  This is the race-safe entry point for initial payout creation.
  Without it, two concurrent claimants on the same position can
  both pass an external check-then-act before either's WAL write
  lands, producing duplicate non-terminal payouts. Uniqueness
  enforcement happens inside the GenServer's serialised mailbox,
  so the read and write share a single critical section.

  Status transitions on existing payouts (`mark_rules_passed`,
  `mark_signing`, etc.) continue through `put_payout/1` — those
  are mutating an already-unique row, so no uniqueness check
  applies.
  """
  @spec put_payout_unique_for_position(Payout.t()) ::
          {:ok, Payout.t()} | {:error, :payout_already_pending | term()}
  def put_payout_unique_for_position(request),
    do: put_payout_unique_for_position(__MODULE__, request)

  @spec put_payout_unique_for_position(GenServer.server(), Payout.t()) ::
          {:ok, Payout.t()} | {:error, :payout_already_pending | term()}
  def put_payout_unique_for_position(server, %Payout{position_id: pid} = request)
      when is_binary(pid) do
    write_call(server, {:put_payout_unique, request, {:position, pid}})
  end

  @doc """
  Atomically inserts `request` if no in-flight dispute-refund
  exists for the same `(account_id, market_id)` tuple. Same
  race-safety contract as `put_payout_unique_for_position/1`.
  """
  @spec put_payout_unique_for_dispute(Payout.t()) ::
          {:ok, Payout.t()} | {:error, :refund_already_pending | term()}
  def put_payout_unique_for_dispute(request),
    do: put_payout_unique_for_dispute(__MODULE__, request)

  @spec put_payout_unique_for_dispute(GenServer.server(), Payout.t()) ::
          {:ok, Payout.t()} | {:error, :refund_already_pending | term()}
  def put_payout_unique_for_dispute(server, %Payout{} = request) do
    write_call(server, {:put_payout_unique, request, {:dispute, request.account_id, request.market_id}})
  end

  @doc """
  Atomically inserts a `:creator_lp_return` payout if no in-flight
  one exists for the same market. Same race-safety contract as the
  position and dispute variants. There is only one creator LP
  return per market, ever — uniqueness is keyed on market_id alone.
  """
  @spec put_payout_unique_for_creator_lp(Payout.t()) ::
          {:ok, Payout.t()} | {:error, :lp_return_already_pending | term()}
  def put_payout_unique_for_creator_lp(request),
    do: put_payout_unique_for_creator_lp(__MODULE__, request)

  @spec put_payout_unique_for_creator_lp(GenServer.server(), Payout.t()) ::
          {:ok, Payout.t()} | {:error, :lp_return_already_pending | term()}
  def put_payout_unique_for_creator_lp(server, %Payout{market_id: mid} = request)
      when is_binary(mid) do
    write_call(server, {:put_payout_unique, request, {:creator_lp_return, mid}})
  end

  @doc """
  Atomically inserts a `:federation_income` payout if no in-flight one
  already exists. Same race-safety contract as the other unique
  variants. Uniqueness is keyed on a sentinel atom so at most one
  federation income withdrawal is ever in flight — a concurrent
  operator console call (typo, double-click, parallel session) gets
  `{:error, :income_already_pending}` rather than both rows landing in
  the queue and both being rejected at sign time.
  """
  @spec put_payout_unique_for_federation_income(Payout.t()) ::
          {:ok, Payout.t()} | {:error, :income_already_pending | term()}
  def put_payout_unique_for_federation_income(request),
    do: put_payout_unique_for_federation_income(__MODULE__, request)

  @spec put_payout_unique_for_federation_income(GenServer.server(), Payout.t()) ::
          {:ok, Payout.t()} | {:error, :income_already_pending | term()}
  def put_payout_unique_for_federation_income(server, %Payout{kind: :federation_income} = request) do
    write_call(server, {:put_payout_unique, request, :federation_income})
  end

  @doc """
  Atomically inserts a `:quote_underpayment_refund` payout if no
  in-flight one exists for the same source Quote. Same race-safety
  contract as the other unique variants. One refund per underpaid
  quote — a Poller re-fire on the same txid can't produce a second
  refund row.
  """
  @spec put_payout_unique_for_quote_underpayment(Payout.t()) ::
          {:ok, Payout.t()} | {:error, :quote_underpayment_refund_already_pending | term()}
  def put_payout_unique_for_quote_underpayment(request),
    do: put_payout_unique_for_quote_underpayment(__MODULE__, request)

  @spec put_payout_unique_for_quote_underpayment(GenServer.server(), Payout.t()) ::
          {:ok, Payout.t()} | {:error, :quote_underpayment_refund_already_pending | term()}
  def put_payout_unique_for_quote_underpayment(
        server,
        %Payout{kind: :quote_underpayment_refund, source_quote_id: qid} = request
      )
      when is_binary(qid) do
    write_call(server, {:put_payout_unique, request, {:quote_underpayment, qid}})
  end

  @spec clear() :: :ok
  def clear, do: clear(__MODULE__)

  @spec clear(GenServer.server()) :: :ok
  def clear(server), do: GenServer.call(server, :clear)

  @doc """
  Durably records that the signing backend has broadcast a payout's
  on-chain transaction. WAL-appends a `:broadcast_marker_set` entry
  AND mirrors into `:persistent_term` for fast hot-path reads. The
  WAL append survives a BEAM restart so a deploy hitting between
  backend return and the `:signing` WAL persist cannot trigger a
  duplicate broadcast: the marker replays on boot, the Signer
  resumes from the marker, and the backend is never called twice.
  """
  @spec persist_broadcast_marker(binary(), String.t()) :: :ok | {:error, term()}
  def persist_broadcast_marker(request_id, txid) when is_binary(request_id) and is_binary(txid),
    do: persist_broadcast_marker(__MODULE__, request_id, txid)

  @spec persist_broadcast_marker(GenServer.server(), binary(), String.t()) ::
          :ok | {:error, term()}
  def persist_broadcast_marker(server, request_id, txid)
      when is_binary(request_id) and is_binary(txid) do
    write_call(server, {:persist_broadcast_marker, request_id, txid})
  end

  @doc """
  Durably drops the broadcast marker once a payout has reached
  `:paid_out`. WAL-appends a `:broadcast_marker_cleared` entry and
  erases from `:persistent_term`.
  """
  @spec drop_broadcast_marker(binary()) :: :ok | {:error, term()}
  def drop_broadcast_marker(request_id) when is_binary(request_id),
    do: drop_broadcast_marker(__MODULE__, request_id)

  @spec drop_broadcast_marker(GenServer.server(), binary()) :: :ok | {:error, term()}
  def drop_broadcast_marker(server, request_id) when is_binary(request_id) do
    write_call(server, {:drop_broadcast_marker, request_id})
  end

  @doc """
  Durably records a designated-processor promotion. WAL-appends a
  `:processor_promotion` entry AND updates `:persistent_term` so
  `Role.designated_processors/0` reads the new set immediately on
  the writer node. Followers pick it up via WAL replication and
  update their own `:persistent_term` inside `apply_wal_entry/2`.

  Epochs are monotonically increasing. A promotion with an epoch
  less than or equal to the currently-active one is refused —
  operator-initiated promotions ALWAYS bump the epoch so a stale
  RPC can never resurrect an older promotion.

  Returns `:ok` on WAL write success. `{:error, :stale_epoch}` if
  the supplied epoch is not strictly greater than the current one.
  WAL-append failures propagate (`:wal_overloaded`, etc.).
  """
  @spec persist_processor_promotion(
          [atom()],
          pos_integer(),
          atom(),
          DateTime.t()
        ) :: :ok | {:error, :stale_epoch | term()}
  def persist_processor_promotion(set, epoch, source, at)
      when is_list(set) and is_integer(epoch) and epoch > 0 and is_atom(source) do
    persist_processor_promotion(__MODULE__, set, epoch, source, at)
  end

  @spec persist_processor_promotion(
          GenServer.server(),
          [atom()],
          pos_integer(),
          atom(),
          DateTime.t()
        ) :: :ok | {:error, :stale_epoch | term()}
  def persist_processor_promotion(server, set, epoch, source, at) do
    write_call(server, {:persist_processor_promotion, set, epoch, source, at})
  end

  @doc """
  Reads the current processor promotion from `:persistent_term`.
  Returns `{set, epoch}` or `:none` if no promotion has landed.
  Bypasses the GenServer mailbox — `Role.designated_processors/0`
  is on the hot write path.
  """
  @spec lookup_processor_promotion() :: {[atom()], pos_integer()} | :none
  def lookup_processor_promotion do
    :persistent_term.get(@promotion_key, :none)
  end

  @doc """
  Reads the broadcast marker for a request from `:persistent_term`.
  Returns the txid as binary, or `:none` if no marker exists.
  Lookups bypass the GenServer mailbox — `:persistent_term` is
  globally accessible — so the Signer's hot path stays lock-free.
  """
  @spec lookup_broadcast_marker(binary()) :: String.t() | :none
  def lookup_broadcast_marker(request_id) when is_binary(request_id) do
    :persistent_term.get({__MODULE__.BroadcastMarker, request_id}, :none)
  end

  @doc """
  Replication-only entry application. Used by `Storage.Replicator`
  to apply WAL entries received from peers; the entries have
  `:origin == peer_id` so locally-originated entries never round-trip
  back through this path. Runs inside the table-owning process so
  the `:protected` ETS invariant holds.
  """
  @spec replicate_entries([Entry.t()]) :: :ok
  def replicate_entries(entries), do: replicate_entries(__MODULE__, entries)

  @spec replicate_entries(GenServer.server(), [Entry.t()]) :: :ok
  def replicate_entries(server, entries) when is_list(entries) do
    GenServer.call(server, {:replicate_entries, entries})
  end

  # See `Markets.Store.write_call/2` — 30s timeout for the same
  # reasons. Production writes finish in ms; sim/load surges
  # occasionally need more headroom.
  #
  # `:wal_overloaded` is Locker.WAL's mailbox-saturation back-pressure
  # signal. Retry with exponential-backoff so callers see a transparent
  # `:ok` after the brief saturation clears, surfacing the error only
  # if the retry budget exhausts. The sleep runs in the caller's
  # process, not the Store GenServer, so it never blocks other writes.
  @wal_retry_delays_ms [1, 5, 25, 100]

  defp write_call(server, msg) do
    call_with_retry(server, msg, @wal_retry_delays_ms)
  end

  defp call_with_retry(server, msg, delays) do
    case GenServer.call(server, msg, 30_000) do
      {:error, :wal_overloaded} when delays != [] ->
        [delay | rest] = delays
        Process.sleep(delay)
        call_with_retry(server, msg, rest)

      other ->
        other
    end
  end

  @spec table_names() :: %{payouts: atom()}
  def table_names do
    %{payouts: @payouts_table}
  end

  # --- GenServer ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    wal_server = Keyword.get(opts, :wal_server, PerpWalk.Storage.WAL)
    table = Keyword.get(opts, :payouts_table, @payouts_table)
    inflight_index = Keyword.get(opts, :inflight_index_table, @inflight_index_table)
    by_status = Keyword.get(opts, :payouts_by_status_table, @payouts_by_status_table)
    by_position = Keyword.get(opts, :payouts_by_position_table, @payouts_by_position_table)
    by_kind = Keyword.get(opts, :payouts_by_kind_table, @payouts_by_kind_table)

    create_ets_table(table, :set)
    create_ets_table(inflight_index, :bag)
    create_ets_table(by_status, :bag)
    create_ets_table(by_position, :bag)
    create_ets_table(by_kind, :bag)
    Code.ensure_loaded!(Payout)

    tables = %{
      payouts: table,
      by_status: by_status,
      by_position: by_position,
      by_kind: by_kind,
      inflight_index: inflight_index
    }

    # `apply_wal_entry/2` now updates all four ETS tables atomically
    # per entry (see `upsert_payout/2`), so cold-boot replay leaves
    # every index consistent without a subsequent rebuild pass.
    replay_wal(wal_server, tables)

    # Seq allocation lives in the Storage domain via
    # `Storage.Facade.seal_and_append/3`. The Federation store no
    # longer carries its own `next_seq` field — every WAL write goes
    # through the central seq counter so the global monotonic
    # invariant is enforced at the producer boundary.
    {:ok,
     %{
       wal_server: wal_server,
       table: table,
       inflight_index: inflight_index,
       by_status: by_status,
       by_position: by_position,
       by_kind: by_kind
     }}
  end

  defp state_tables(state) do
    %{
      payouts: state.table,
      by_status: state.by_status,
      by_position: state.by_position,
      by_kind: state.by_kind,
      inflight_index: state.inflight_index
    }
  end

  @impl true
  def handle_call({:put_payout, request}, _from, state) do
    payload = serialize(request)

    case StorageFacade.seal_and_append(:payout_requested, payload, state.wal_server) do
      :ok ->
        insert_payout(state, request)
        {:reply, :ok, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  # Atomic check-and-insert. Reads through the secondary in-flight
  # index and writes through the WAL+ETS pipeline inside one
  # serialised handle_call so concurrent claimants can't both pass
  # the existence check before either's row lands. The index is a
  # `:bag` keyed by `scope_key` (`{:position, id}` /
  # `{:dispute, account_id, market_id}`) so the membership check is
  # O(1) regardless of cumulative payout count.
  def handle_call({:put_payout_unique, request, scope}, _from, state) do
    if :ets.member(state.inflight_index, scope) do
      {:reply, {:error, scope_error(scope)}, state}
    else
      payload = serialize(request)

      case StorageFacade.seal_and_append(:payout_requested, payload, state.wal_server) do
        :ok ->
          insert_payout(state, request)
          :ets.insert(state.inflight_index, {scope, request.id})
          {:reply, {:ok, request}, state}

        {:error, _} = err ->
          {:reply, err, state}
      end
    end
  end

  def handle_call({:replicate_entries, entries}, _from, state) do
    # Each `apply_wal_entry/2` call updates primary + secondary indexes
    # atomically (see `upsert_payout/2`), so the wipe-and-rebuild pass
    # this handler used to run is unnecessary. Incremental updates keep
    # `by_position` / `by_status` / `inflight_index` consistent
    # throughout the batch — a LiveView subscriber that reloads state
    # in response to `maybe_emit_event/1` can never observe an empty
    # index during a rebuild window (that race manifested as
    # "queued → claim → refresh reveals txid").
    #
    # Centralised seq counter is bumped at the Replicator boundary
    # (every batch, regardless of domain) so no per-domain bump
    # is needed here.
    apply_entries(entries, state_tables(state), emit_events: true)
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    :ets.delete_all_objects(state.inflight_index)
    :ets.delete_all_objects(state.by_status)
    :ets.delete_all_objects(state.by_position)
    :ets.delete_all_objects(state.by_kind)
    {:reply, :ok, state}
  end

  def handle_call({:persist_broadcast_marker, request_id, txid}, _from, state) do
    payload = %{request_id: request_id, payout_txid: txid}

    case StorageFacade.seal_and_append(:broadcast_marker_set, payload, state.wal_server) do
      :ok ->
        :persistent_term.put({__MODULE__.BroadcastMarker, request_id}, txid)
        {:reply, :ok, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:persist_processor_promotion, set, epoch, source, at}, _from, state) do
    case current_promotion_epoch() do
      current when current >= epoch ->
        {:reply, {:error, :stale_epoch}, state}

      _ ->
        payload = %{set: set, epoch: epoch, source: source, at: at}

        case StorageFacade.seal_and_append(:processor_promotion, payload, state.wal_server) do
          :ok ->
            :persistent_term.put(@promotion_key, {set, epoch})
            {:reply, :ok, state}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  def handle_call({:drop_broadcast_marker, request_id}, _from, state) do
    payload = %{request_id: request_id}

    case StorageFacade.seal_and_append(:broadcast_marker_cleared, payload, state.wal_server) do
      :ok ->
        :persistent_term.erase({__MODULE__.BroadcastMarker, request_id})
        {:reply, :ok, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  # Writes a Payout to the primary table and synchronises every
  # secondary index in one pass. Called from every WRITE path — the
  # local direct handlers (`{:put_payout, ...}`, `{:put_payout_unique,
  # ...}`) via `insert_payout/2`, AND the follower replication path
  # via `apply_wal_entry(:payout_requested, ...)`. Status transitions
  # (e.g. :pending → :signing → :paid_out) require deleting the prior
  # `{old_status, id}` pair from the by-status bag before inserting
  # the new one. `position_id` is immutable for a given payout so the
  # by-position bag dedupes naturally.
  defp upsert_payout(tables, %Payout{} = payout) do
    prior_status =
      case :ets.lookup(tables.payouts, payout.id) do
        [{_, %Payout{status: s}}] -> s
        [] -> nil
      end

    :ets.insert(tables.payouts, {payout.id, payout})

    cond do
      prior_status == payout.status ->
        :ok

      is_nil(prior_status) ->
        :ets.insert(tables.by_status, {payout.status, payout.id})

      true ->
        :ets.delete_object(tables.by_status, {prior_status, payout.id})
        :ets.insert(tables.by_status, {payout.status, payout.id})
    end

    if is_binary(payout.position_id) do
      :ets.insert(tables.by_position, {payout.position_id, payout.id})
    end

    # Payout.kind is immutable — insert-once, no mutation cleanup.
    # :bag with the same row is a no-op on replay.
    if not is_nil(payout.kind) do
      :ets.insert(tables.by_kind, {payout.kind, payout.id})
    end

    update_inflight_index(tables.inflight_index, payout)
    :ok
  end

  defp insert_payout(state, %Payout{} = payout),
    do: upsert_payout(state_tables(state), payout)

  # Maintains the in-flight index for a given Payout. Adds the row
  # while in-flight; removes it when the Payout reaches a terminal
  # status. Called from every handler that writes a Payout.
  #
  # `:quote_underpayment` scope is PERMANENT on
  # `:paid_out` (never removed). Rationale: Poller re-fires are
  # guaranteed by Darks's ~25 min eviction window overlapping the
  # 30 min quote lifetime and by rescans on startup. If the scope
  # were dropped on :paid_out, a re-fire weeks later would find
  # the index empty, enqueue a fresh refund, sign it, and pay the
  # same underpayment a second time. Only :failed drops the scope
  # (that path means the refund never broadcast, so re-issue is
  # not a double-pay risk).
  defp update_inflight_index(index, %Payout{} = payout) do
    scope = scope_for_payout(payout)

    cond do
      is_nil(scope) ->
        :ok

      Payout.in_flight?(payout) ->
        # Idempotent — :bag with same row is a no-op.
        :ets.insert(index, {scope, payout.id})

      scope_permanent_after_paid_out?(scope) and payout.status == :paid_out ->
        # Preserve the scope row forever — double-refund shield.
        :ok

      true ->
        # Terminal — drop just this payout's row from the bag (don't
        # nuke the whole scope key in case another in-flight payout
        # exists under the same scope after a future refactor).
        :ets.delete_object(index, {scope, payout.id})
    end

    :ok
  end

  # Scopes that MUST retain their in-flight index row past `:paid_out`
  # to prevent duplicate issuance on upstream re-fires. Add sparingly:
  # every scope listed here permanently forecloses re-attempts under
  # the same key, which is the correct semantics for one-shot flows
  # driven by external (possibly re-emitting) triggers.
  defp scope_permanent_after_paid_out?({:quote_underpayment, _}), do: true
  defp scope_permanent_after_paid_out?(_), do: false

  # Current promotion epoch — 0 if no promotion has landed yet
  # (initial inventory-default state).
  defp current_promotion_epoch do
    case :persistent_term.get(@promotion_key, :none) do
      {_set, epoch} -> epoch
      :none -> 0
    end
  end

  defp scope_for_payout(%Payout{position_id: pid}) when is_binary(pid), do: {:position, pid}

  defp scope_for_payout(%Payout{kind: kind, account_id: aid, market_id: mid})
       when kind in [:dispute_refund_full, :dispute_refund_partial] and
              is_binary(aid) and is_binary(mid),
       do: {:dispute, aid, mid}

  defp scope_for_payout(%Payout{kind: :creator_lp_return, market_id: mid})
       when is_binary(mid),
       do: {:creator_lp_return, mid}

  defp scope_for_payout(%Payout{kind: :federation_income}), do: :federation_income

  defp scope_for_payout(%Payout{kind: :quote_underpayment_refund, source_quote_id: qid})
       when is_binary(qid),
       do: {:quote_underpayment, qid}

  defp scope_for_payout(%Payout{}), do: nil

  defp scope_error({:position, _}), do: :payout_already_pending
  defp scope_error({:dispute, _, _}), do: :refund_already_pending
  defp scope_error({:creator_lp_return, _}), do: :lp_return_already_pending
  defp scope_error(:federation_income), do: :income_already_pending
  defp scope_error({:quote_underpayment, _}), do: :quote_underpayment_refund_already_pending

  # --- Helpers ---

  defp create_ets_table(name, type) when type in [:set, :bag] do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, [:named_table, type, :protected, read_concurrency: true])
      _ref -> name
    end
  end

  defp replay_wal(wal_server, tables) do
    case safe_read_all(wal_server) do
      {:ok, entries} ->
        apply_entries(entries, tables)

      {:error, reason} ->
        # Mirrors `Markets.Store.replay_wal/2` — booting with empty
        # ETS while the WAL on disk has entries past some higher N
        # would silently desync the ETS state from the WAL. Raise so
        # the supervisor restart loop surfaces the failure rather
        # than letting the divergence land silently. Seq monotonicity
        # itself is now handled by the Storage domain's centralised
        # seq counter, which scans the WAL on its own boot and
        # refuses to under-count.
        raise "Federation.Store: WAL replay failed, reason=#{inspect(reason)}. " <>
                "Refusing to boot with empty state — investigate WAL directory " <>
                "and segment files before restart."

      :unavailable ->
        Logger.warning("Store: WAL replay skipped, reason=wal_unavailable")
        %{applied: 0, skipped: 0, max_seq: 0}
    end
  end

  defp safe_read_all(wal_server) do
    Locker.WAL.read_all_strict(wal_server)
  catch
    :exit, _ -> :unavailable
  end

  @doc """
  Public so tests can drive the dispatch logic with hand-crafted
  entries (including `{:__corrupted__, _}` payloads to verify
  one-bad-entry doesn't abort the rest of the replay).

  Walks entries in WAL order, validating that any `:seq` stamps
  found are strictly monotonic. A gap or non-increasing seq emits
  a `[:perp_walk, :federation, :store, :wal_seq_anomaly]` telemetry
  event but does not stop replay. See `Markets.Store.apply_entries/2`
  for the same pattern in the markets domain.
  """
  @typedoc """
  ETS table set threaded through the WAL apply path. Each entry
  application updates the primary `payouts` table AND every secondary
  index atomically, so a follower's ETS state stays consistent per
  entry — no wipe-and-rebuild pass is needed between entries or
  batches, and a LiveView subscriber that reloads on a
  `maybe_emit_event/1` fanout cannot observe a partially-rebuilt
  index.
  """
  @type tables :: %{
          payouts: atom(),
          by_status: atom(),
          by_position: atom(),
          by_kind: atom(),
          inflight_index: atom()
        }

  @spec apply_entries([Entry.t()], tables()) ::
          %{
            applied: non_neg_integer(),
            skipped: non_neg_integer(),
            max_seq: non_neg_integer()
          }
  def apply_entries(entries, tables), do: apply_entries(entries, tables, [])

  @doc """
  Same as `apply_entries/2` but accepts an options keyword list.

  ## Options

  - `:emit_events` (default `false`) — when true, publishes the local
    `PerpWalk.Events.Federation.*` event that corresponds to each
    successfully applied WAL entry. Set by
    `handle_call({:replicate_entries, ...})` so a follower node's
    LiveViews receive UI events for cluster-writes originated on the
    designated processor (`EventBus.publish` is `local_broadcast`
    only — see `maybe_emit_event/1` for the covered event set).
    Cold-boot replay leaves this off: no LiveView is subscribed yet,
    and historical entries should not fire user-visible notifications.
  """
  @reorder_tolerance 32

  @spec apply_entries([Entry.t()], tables(), keyword()) ::
          %{
            applied: non_neg_integer(),
            skipped: non_neg_integer(),
            max_seq: non_neg_integer()
          }
  def apply_entries(entries, tables, opts) do
    emit_events? = Keyword.get(opts, :emit_events, false)
    relevant = Enum.filter(entries, &relevant?/1)

    # Watermarks are per-(origin, type): a peer heal can interleave
    # origins in WAL order, and per-type-only tracking flagged that
    # legitimate pattern as corruption.
    {applied, skipped, max_seq, _last_per_key} =
      Enum.reduce(relevant, {0, 0, 0, %{}}, fn entry, {a, s, ms, last_per_key} ->
        if boot_gate_halt?(entry) do
          {a, s + 1, ms, last_per_key}
        else
          apply_one_entry(entry, tables, emit_events?, {a, s, ms, last_per_key})
        end
      end)

    if skipped > 0 do
      Logger.warning("Store: WAL replay applied=#{applied}, skipped=#{skipped}")
    else
      Logger.debug("Store: WAL replay applied=#{applied}")
    end

    %{applied: applied, skipped: skipped, max_seq: max_seq}
  end

  defp apply_one_entry(entry, tables, emit_events?, {a, s, ms, last_per_key}) do
    seq = entry_seq(entry)
    key = {entry_origin(entry), entry.type}
    last = Map.get(last_per_key, key)
    fresh? = is_nil(seq) or is_nil(last) or seq > last

    new_last_per_key =
      if is_integer(seq) do
        check_seq_monotonic(seq, last, key)
        Map.put(last_per_key, key, seq)
      else
        last_per_key
      end

    case apply_wal_entry(entry, tables) do
      :ok ->
        if emit_events? and fresh?, do: maybe_emit_event(entry)
        {a + 1, s, max_with_nil(ms, seq), new_last_per_key}

      :skip ->
        {a, s + 1, ms, new_last_per_key}
    end
  end

  # Boot-time authenticity gate. Records a sticky source halt on
  # forged/unsigned entries in enforced mode; raises in production so
  # a tampered WAL never boots into service.
  defp boot_gate_halt?(entry) do
    if PerpWalk.Storage.WAL.Replay.halt_entry?(entry, :federation) do
      if halt_on_corrupt?() do
        raise "Federation.Store: boot replay refused entry, type=#{inspect(entry.type)} — " <>
                "signature/origin invalid for the current signing mode. " <>
                "Investigate the WAL before forcing skip via :perpwalk, :wal, halt_on_corrupt: false."
      else
        Logger.warning("Store: skipping entry with invalid signature/origin, type=#{inspect(entry.type)}")
        true
      end
    else
      false
    end
  end

  defp entry_origin(%Entry{payload: %{origin: o}}) when is_atom(o), do: o
  defp entry_origin(_), do: :unknown

  # LiveView UI re-emission for cluster-write events. `EventBus.publish`
  # is a `Phoenix.PubSub.local_broadcast`, so events published on the
  # designated processor never reach a follower node's LiveViews. When
  # a follower applies a replicated `:payout_requested` entry, re-publish
  # the lifecycle event that corresponds to the new status so the
  # follower's LiveViews receive the same transition the originator saw.
  #
  # Discriminators:
  # - `:pending` → freshly created request (PayoutRequested)
  # - `:awaiting_operator` → rules engine rejected pre-signing
  # - `:rules_passed` with a non-nil `rule_failure_reason` →
  #   `mark_force_approved` (operator override); a fresh
  #   `mark_rules_passed` from `:pending` leaves the reason nil.
  # - `:paid_out` → `mark_paid_out` (submitted + finalise complete)
  # - `:failed` → `mark_failed` (terminal). Signer transient rejections
  #   no longer emit PayoutFailed — invariant is that PayoutFailed
  #   fires iff a Payout durably transitions to `:failed`.
  #
  # Cross-domain LP-returned re-emission (CreatorLpReturned) is not
  # needed here — that event fires from `Signer.finish_after_signing`
  # only on the designated processor's payout success path, but the
  # Markets-side `:market_resolved` / `:position_paid_out` WAL entries
  # for creator-LP returns propagate through Markets replay, and the
  # portfolio LiveView reacts to `PayoutSubmitted` above.
  defp maybe_emit_event(%Entry{type: :payout_requested, payload: %{status: :pending} = p}) do
    EventBus.publish(%FederationEvents.PayoutRequested{
      request_id: p.id,
      position_id: Map.get(p, :position_id),
      market_id: p.market_id,
      account_id: p.account_id,
      kind: p.kind,
      amount_piconeros: p.amount_piconeros,
      destination: p.destination,
      timestamp: DateTime.utc_now()
    })

    :ok
  end

  defp maybe_emit_event(%Entry{
         type: :payout_requested,
         payload: %{status: :awaiting_operator, rule_failure_reason: reason} = p
       })
       when is_binary(reason) do
    EventBus.publish(%FederationEvents.RuleCheckFailed{
      request_id: p.id,
      reason: reason,
      timestamp: DateTime.utc_now()
    })

    :ok
  end

  defp maybe_emit_event(%Entry{
         type: :payout_requested,
         payload: %{status: :rules_passed, rule_failure_reason: reason} = p
       })
       when is_binary(reason) do
    EventBus.publish(%FederationEvents.OperatorOverride{
      request_id: p.id,
      previous_reason: reason,
      timestamp: DateTime.utc_now()
    })

    :ok
  end

  defp maybe_emit_event(%Entry{
         type: :payout_requested,
         payload: %{status: :paid_out, payout_txid: txid} = p
       })
       when is_binary(txid) do
    EventBus.publish(%FederationEvents.PayoutSubmitted{
      request_id: p.id,
      position_id: Map.get(p, :position_id),
      payout_txid: txid,
      amount_piconeros: p.amount_piconeros,
      timestamp: DateTime.utc_now()
    })

    :ok
  end

  defp maybe_emit_event(%Entry{
         type: :payout_requested,
         payload: %{status: :failed, rule_failure_reason: reason} = p
       })
       when is_binary(reason) do
    EventBus.publish(%FederationEvents.PayoutFailed{
      request_id: p.id,
      reason: reason,
      timestamp: DateTime.utc_now()
    })

    :ok
  end

  defp maybe_emit_event(_entry), do: :ok

  defp entry_seq(%Entry{payload: %{seq: seq}}) when is_integer(seq) and seq >= 0, do: seq
  defp entry_seq(_), do: nil

  defp max_with_nil(current, nil), do: current
  defp max_with_nil(current, seq) when is_integer(seq), do: max(current, seq)

  defp check_seq_monotonic(_seq, nil, _key), do: :ok

  defp check_seq_monotonic(seq, last, _key) when seq > last, do: :ok

  # Idempotent retry — a partially-appended replication batch
  # produces a duplicate entry on the local WAL. Re-applying it is
  # safe because the payload is byte-identical and the ETS upsert
  # is idempotent. Silent so the operator isn't woken up by what
  # is, by design, a recoverable internal hiccup.
  defp check_seq_monotonic(seq, last, _key) when seq == last, do: :ok

  # Small backward step within one (origin, type) — the direct-write
  # path allocates the seq then appends, so a scheduler interleave can
  # land [N+1, N] with no tampering. Warn + telemetry, keep replaying.
  defp check_seq_monotonic(seq, last, key) when last - seq <= @reorder_tolerance do
    Logger.warning("Store: minor WAL seq reorder tolerated, key=#{inspect(key)}, last=#{last}, observed=#{seq}")

    :telemetry.execute(
      [:perp_walk, :federation, :store, :wal_seq_anomaly],
      %{observed: seq, last: last},
      %{key: inspect(key), kind: :minor_reorder}
    )

    :ok
  end

  # Large rewind within one (origin, type): tamper or truncation.
  # Fail closed in production — a reordered payout history can reopen
  # terminal rows into a double-broadcast.
  defp check_seq_monotonic(seq, last, key) do
    Logger.error("Store: WAL seq anomaly, key=#{inspect(key)}, last=#{last}, observed=#{seq}, kind=reorder")

    :telemetry.execute(
      [:perp_walk, :federation, :store, :wal_seq_anomaly],
      %{observed: seq, last: last},
      %{key: inspect(key), kind: :reorder}
    )

    if halt_on_corrupt?() do
      raise "Federation.Store: refusing to continue — WAL reorder on key=#{inspect(key)} " <>
              "(last=#{last}, observed=#{seq}). Disable via :perpwalk, :wal, halt_on_corrupt: false."
    end

    :ok
  end

  defp relevant?(%Entry{type: type}) when type in @wal_types, do: true
  defp relevant?(_), do: false

  defp apply_wal_entry(%Entry{payload: {:__corrupted__, _}} = e, _tables) do
    if halt_on_corrupt?() do
      raise "Federation.Store: refusing to continue — corrupt WAL entry of type #{inspect(e.type)}. " <>
              "Investigate before forcing skip via :perpwalk, :wal, halt_on_corrupt: false."
    else
      Logger.warning("Store: skipping corrupt WAL entry, type=#{inspect(e.type)}")
      :skip
    end
  end

  defp apply_wal_entry(%Entry{type: :payout_requested, payload: payload}, tables)
       when is_map(payload) do
    payload
    |> deserialize()
    |> then(&upsert_payout(tables, &1))

    :ok
  end

  defp apply_wal_entry(
         %Entry{type: :broadcast_marker_set, payload: %{request_id: rid, payout_txid: txid}},
         _tables
       )
       when is_binary(rid) and is_binary(txid) do
    :persistent_term.put({__MODULE__.BroadcastMarker, rid}, txid)
    :ok
  end

  defp apply_wal_entry(
         %Entry{type: :broadcast_marker_cleared, payload: %{request_id: rid}},
         _tables
       )
       when is_binary(rid) do
    :persistent_term.erase({__MODULE__.BroadcastMarker, rid})
    :ok
  end

  defp apply_wal_entry(
         %Entry{type: :processor_promotion, payload: %{set: set, epoch: epoch}},
         _tables
       )
       when is_list(set) and is_integer(epoch) and epoch > 0 do
    # Monotonic guard on apply: a follower replaying entries in
    # cluster order should never see a lower epoch AFTER a higher
    # one, but defensive replay ordering (out-of-order batch, WAL
    # replay ordering across origins) can produce that. Only advance.
    case :persistent_term.get(@promotion_key, :none) do
      {_, current} when current >= epoch -> :ok
      _ -> :persistent_term.put(@promotion_key, {set, epoch})
    end

    :ok
  end

  # See Markets.Store.Replay for the rationale: a recognized type that
  # doesn't match any typed clause indicates either schema drift or a
  # forged batch on a follower. Halt by default; silently skipping
  # would let follower ETS diverge from the leader's.
  defp apply_wal_entry(%Entry{type: type} = entry, _tables) do
    if halt_on_corrupt?() do
      raise "Federation.Store: refusing to continue — WAL entry of type #{inspect(type)} " <>
              "has unexpected payload shape. Investigate before forcing skip via " <>
              ":perpwalk, :wal, halt_on_corrupt: false. entry=#{inspect(entry, limit: 50)}"
    else
      Logger.warning("Store: skipping unrecognised payload shape, type=#{inspect(type)}")

      :skip
    end
  end

  defp halt_on_corrupt? do
    Application.get_env(:perpwalk, :wal, [])
    |> Keyword.get(:halt_on_corrupt, true)
  end

  # --- Serialisation ---
  #
  # Same convention as Markets.Store: plain maps with primitives
  # only, ISO8601 timestamps to avoid pulling Calendar.ISO into the
  # atom table during cold-boot WAL replay.

  defp serialize(%Payout{} = req) do
    %{
      id: req.id,
      position_id: req.position_id,
      source_quote_id: req.source_quote_id,
      market_id: req.market_id,
      account_id: req.account_id,
      kind: req.kind,
      amount_piconeros: req.amount_piconeros,
      destination: req.destination,
      status: req.status,
      rule_failure_reason: req.rule_failure_reason,
      payout_txid: req.payout_txid,
      created_at: encode_dt(req.created_at),
      updated_at: encode_dt(req.updated_at)
    }
  end

  defp deserialize(map) do
    %Payout{
      id: map.id,
      position_id: map.position_id,
      source_quote_id: Map.get(map, :source_quote_id),
      market_id: map.market_id,
      account_id: map.account_id,
      kind: map.kind,
      amount_piconeros: map.amount_piconeros,
      destination: map.destination,
      status: map.status,
      rule_failure_reason: Map.get(map, :rule_failure_reason),
      payout_txid: Map.get(map, :payout_txid),
      created_at: decode_dt(map.created_at),
      updated_at: decode_dt(map.updated_at)
    }
  end

  defp encode_dt(nil), do: nil
  defp encode_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp decode_dt(nil), do: nil

  defp decode_dt(iso) when is_binary(iso) do
    {:ok, dt, _offset} = DateTime.from_iso8601(iso)
    dt
  end
end
