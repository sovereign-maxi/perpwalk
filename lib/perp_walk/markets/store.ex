defmodule PerpWalk.Markets.Store do
  @moduledoc """
  GenServer-backed persistence for the Markets domain.

  Owns five primary ETS tables (markets, positions, votes, quotes,
  disputes) plus secondary indexes for hot-path lookups (by market,
  by account, by status, by category, by creator, by subaddress) and
  a federation-revenue counter table. Every write serialises through
  the WAL so state can be rebuilt after a crash.

  ## Architecture

  - **Hot path (reads)**: Direct `:ets.lookup/2` calls. No GenServer
    round-trip; safe because tables are `:protected` and only this
    process writes.
  - **Write path**: Each `put_*` call either serialises through the
    GenServer (compound or CAS writes) or goes through the direct-
    path writer that uses an `:atomics` seq ref to allow concurrent
    appends. Both append a WAL entry first, then mutate ETS.
  - **Startup**: `init/1` creates the tables (if absent) and replays
    every relevant WAL type (see `Store.Replay`) to rebuild ETS state.

  ## Position writes

  Positions are never written standalone — every legitimate position
  mutation in this domain is paired with a market change (open a
  trade, settle, refund). The Store exposes atomic compound
  primitives (`put_trade/2`, `put_resolution_cas/3-4`) and refuses
  to expose a raw `put_position` API that could let callers skirt
  the atomicity invariant.

  ## Sequence numbers

  Every WAL payload written by this store carries a monotonic
  `:seq` counter drawn from an `:atomics` ref. The counter is bumped
  before each append; on append failure the bump is NOT rolled back,
  so a failed write leaves a hole in the global seq sequence.
  `apply_entries/2` tracks per-type watermarks and uses `seq > last`
  (not `last + 1`), so gaps are silently tolerated — they don't
  break monotonicity or replay correctness. Regressions (strict
  `seq < last`) emit a `[:perp_walk, :markets, :store, :wal_seq_anomaly]`
  telemetry event and halt-on-corrupt raises in production, so a
  truncated or reordered WAL is caught at boot.

  ## Schema

  - `markets`   — `{market_id, %Market{}}`
  - `positions` — `{position_id, %Position{}}`
  - `votes`     — `{{account_id, market_id}, %Vote{}}` (one vote
    per account per market — re-puts overwrite)
  - `quotes`    — `{quote_id, %Quote{}}` (pending trades waiting
    for deposit confirmation; consumed at fill or expiry)
  - `disputes`  — `{{account_id, market_id}, %Dispute{}}` (one
    dispute per account per market; status progresses through the
    Dispute lifecycle)

  Secondary indexes mirror the primaries — see the table-name
  attributes at the top of the module for the full set. The
  federation-revenue counters (slashed, burned, spread, plus
  matching counts) are maintained incrementally by the `insert_*`
  helpers; see `Markets.Federation.Ledger`.

  Pure storage. Command handling, event publishing, and
  cross-aggregate invariants live in the service layer above.
  """

  use GenServer

  require Logger

  alias Locker.WAL.Entry
  alias PerpWalk.Markets.{AMM, Categories, Dispute, Market, Position, Quote, Vote}
  alias PerpWalk.Markets.Store.{Inserts, Replay, Serialize}
  alias PerpWalk.Storage.Facade, as: StorageFacade

  # ETS table names follow the module-path convention: each table's
  # name IS its owning module's atom. Multi-table modules use
  # submodule suffixes. Makes ownership obvious in :ets.info dumps
  # and stack traces.
  @markets_table __MODULE__.Markets
  @positions_table __MODULE__.Positions
  @votes_table __MODULE__.Votes
  @quotes_table __MODULE__.Quotes
  @disputes_table __MODULE__.Disputes

  # Secondary indexes — :bag tables keyed by market_id, holding
  # position_id / vote_key. Maintained alongside the primary
  # tables so per-market lookups are O(items-in-market) instead
  # of O(all-items). Idempotent inserts mean replay can blindly
  # re-index; deletes (votes overwrite, positions never delete)
  # are not part of the public flow.
  @positions_by_market_table __MODULE__.PositionsByMarket
  @votes_by_market_table __MODULE__.VotesByMarket

  # Secondary index for `list_markets_by_status/1`. Without this,
  # every browse-by-status call (and every sim actor's per-tick
  # candidate lookup) was a full ETS foldl over the markets table
  # plus an Elixir-side filter — O(total_markets) regardless of
  # how many actually carried the requested status. With this
  # bag-keyed-by-status index the cost becomes O(markets_in_status).
  @markets_by_status_table __MODULE__.MarketsByStatus

  # Secondary indexes for markets by category and creator. Category
  # and creator_account_id are immutable for a given market, so
  # the bags dedupe on re-insert and never need deletion.
  @markets_by_category_table __MODULE__.MarketsByCategory
  @markets_by_creator_table __MODULE__.MarketsByCreator

  # Secondary indexes for positions. Without these, Portfolio
  # renders and the sim Claimer were each O(total_positions) per
  # call. With them: O(positions_in_account) / O(positions_in_status).
  @positions_by_account_table __MODULE__.PositionsByAccount
  @positions_by_status_table __MODULE__.PositionsByStatus

  # Secondary indexes for disputes. The moderation evaluator's
  # `live_dispute_count` is on the hot path for every dispute
  # confirm — without by-market it was a full-table select. The
  # by-account index covers per-user Portfolio dispute lists.
  # Dispute keys ({account_id, market_id}) are immutable for a
  # given row so the by-market and by-account bags dedupe and
  # never delete. The by-status bag follows the transition pattern
  # (delete old, insert new on status change) because disputes
  # progress through statuses.
  @disputes_by_market_table __MODULE__.DisputesByMarket
  @disputes_by_account_table __MODULE__.DisputesByAccount
  @disputes_by_status_table __MODULE__.DisputesByStatus

  # Secondary indexes for quotes. Quote.market_id and account_id
  # are immutable for a given quote_id, so the bags dedupe on
  # re-insert. Quotes ARE deleted (on fill / expiry); index rows
  # need explicit cleanup at delete time.
  @quotes_by_market_table __MODULE__.QuotesByMarket
  @quotes_by_account_table __MODULE__.QuotesByAccount
  # Ordered-set index keyed by `{unix_expires_at, quote_id}` so the
  # scheduler can pop expired quotes in O(K) via a bounded ETS select
  # instead of a full-list scan + Enum.filter every tick.
  @quotes_by_expiry_table __MODULE__.QuotesByExpiry

  # Secondary indexes on the Monero subaddress index. Subaddresses
  # are allocated monotonically from the wallet, so the index is
  # globally unique across quotes / disputes / markets — `:set`
  # tables, one resource per index. Powers `Monero.Poller.lookup_subaddress/1`
  # which used to walk full entity lists for every deposit; now O(1).
  @quotes_by_subaddress_table __MODULE__.QuotesBySubaddress
  @disputes_by_subaddress_table __MODULE__.DisputesBySubaddress
  @markets_by_subaddress_table __MODULE__.MarketsBySubaddress

  # Federation-revenue counter table. One row per metric; values are
  # maintained incrementally by `insert_market` / `insert_dispute` /
  # `do_put_resolution` whenever the relevant terminal-status
  # transition is committed. `Federation.Ledger.breakdown/0` reads
  # these in O(1) rather than re-deriving from index folds on every
  # call — operator dashboard refreshes and validator hot paths both
  # benefit. WAL replay rebuilds the counters naturally because
  # replay funnels through the same `insert_*` helpers as live
  # writes. `Ledger.reconcile/0` cross-checks the counters against
  # a fresh index-derivation for drift detection.
  @ledger_counters_table __MODULE__.LedgerCounters

  # Counter keys live on `Store.Inserts` since that's where the
  # counters are incremented and seeded. Read API references them
  # via `Inserts.ledger_counter_keys/0` to keep the list of keys
  # next to the code that maintains them.

  # --- Public Read API (direct ETS) ---

  @spec get_market(binary()) :: {:ok, Market.t()} | {:error, :not_found}
  def get_market(id) when is_binary(id) do
    case :ets.lookup(@markets_table, id) do
      [{^id, market}] -> {:ok, market}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  @spec list_markets() :: [Market.t()]
  def list_markets do
    :ets.foldl(fn {_id, market}, acc -> [market | acc] end, [], @markets_table)
  rescue
    ArgumentError -> []
  end

  @spec list_markets_by_status(Market.status()) :: [Market.t()]
  def list_markets_by_status(status) when is_atom(status) do
    case :ets.lookup(@markets_by_status_table, status) do
      [] ->
        []

      pairs ->
        for {^status, id} <- pairs,
            [{_, %Market{} = m}] <- [:ets.lookup(@markets_table, id)],
            do: m
    end
  rescue
    ArgumentError -> []
  end

  @spec list_markets_by_category(atom()) :: [Market.t()]
  def list_markets_by_category(category) when is_atom(category) do
    case :ets.lookup(@markets_by_category_table, category) do
      [] ->
        []

      pairs ->
        for {^category, market_id} <- pairs,
            [{_, %Market{} = m}] <- [:ets.lookup(@markets_table, market_id)],
            do: m
    end
  rescue
    ArgumentError -> []
  end

  @spec list_markets_for_creator(binary()) :: [Market.t()]
  def list_markets_for_creator(account_id) when is_binary(account_id) do
    case :ets.lookup(@markets_by_creator_table, account_id) do
      [] ->
        []

      pairs ->
        for {^account_id, market_id} <- pairs,
            [{_, %Market{} = m}] <- [:ets.lookup(@markets_table, market_id)],
            do: m
    end
  rescue
    ArgumentError -> []
  end

  @spec get_position(binary()) :: {:ok, Position.t()} | {:error, :not_found}
  def get_position(id) when is_binary(id) do
    case :ets.lookup(@positions_table, id) do
      [{^id, position}] -> {:ok, position}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  @spec list_positions() :: [Position.t()]
  def list_positions do
    :ets.foldl(fn {_id, position}, acc -> [position | acc] end, [], @positions_table)
  rescue
    ArgumentError -> []
  end

  @spec list_positions_for_market(binary()) :: [Position.t()]
  def list_positions_for_market(market_id) when is_binary(market_id) do
    case :ets.lookup(@positions_by_market_table, market_id) do
      [] ->
        []

      pairs ->
        for {^market_id, position_id} <- pairs,
            [{_, %Position{} = p}] <- [:ets.lookup(@positions_table, position_id)],
            do: p
    end
  rescue
    ArgumentError -> []
  end

  @doc """
  Returns the count of distinct account_ids holding any position on
  this market — settled, refunded, paid-out, all of them. The
  "trader population" denominator used by `Moderation.scaled_threshold/1`
  for scale-invariant dispute review.

  Derived from the existing `PositionsByMarket` index — O(positions
  on this market). At launch volumes (10s of positions per market)
  this is trivial; if a future market grows to thousands of positions
  and this hot path becomes noticeable, promote to a maintained
  `PositionHoldersByMarket` `:bag` index.
  """
  @spec count_distinct_position_holders(binary()) :: non_neg_integer()
  def count_distinct_position_holders(market_id) when is_binary(market_id) do
    market_id
    |> list_positions_for_market()
    |> Enum.map(& &1.account_id)
    |> Enum.uniq()
    |> length()
  end

  @spec list_positions_for_account(binary()) :: [Position.t()]
  def list_positions_for_account(account_id) when is_binary(account_id) do
    case :ets.lookup(@positions_by_account_table, account_id) do
      [] ->
        []

      pairs ->
        for {^account_id, position_id} <- pairs,
            [{_, %Position{} = p}] <- [:ets.lookup(@positions_table, position_id)],
            do: p
    end
  rescue
    ArgumentError -> []
  end

  @spec list_positions_by_status(Position.status()) :: [Position.t()]
  def list_positions_by_status(status) when is_atom(status) do
    case :ets.lookup(@positions_by_status_table, status) do
      [] ->
        []

      pairs ->
        for {^status, position_id} <- pairs,
            [{_, %Position{} = p}] <- [:ets.lookup(@positions_table, position_id)],
            do: p
    end
  rescue
    ArgumentError -> []
  end

  @spec get_vote(binary(), binary()) :: {:ok, Vote.t()} | {:error, :not_found}
  def get_vote(account_id, market_id) when is_binary(account_id) and is_binary(market_id) do
    case :ets.lookup(@votes_table, {account_id, market_id}) do
      [{_key, vote}] -> {:ok, vote}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  @spec list_votes() :: [Vote.t()]
  def list_votes do
    :ets.foldl(fn {_key, vote}, acc -> [vote | acc] end, [], @votes_table)
  rescue
    ArgumentError -> []
  end

  @spec list_votes_for_market(binary()) :: [Vote.t()]
  def list_votes_for_market(market_id) when is_binary(market_id) do
    case :ets.lookup(@votes_by_market_table, market_id) do
      [] ->
        []

      pairs ->
        for {^market_id, vote_key} <- pairs,
            [{_, %Vote{} = v}] <- [:ets.lookup(@votes_table, vote_key)],
            do: v
    end
  rescue
    ArgumentError -> []
  end

  @spec has_voted?(binary(), binary()) :: boolean()
  def has_voted?(account_id, market_id) when is_binary(account_id) and is_binary(market_id) do
    :ets.member(@votes_table, {account_id, market_id})
  rescue
    ArgumentError -> false
  end

  @spec get_dispute(binary(), binary()) :: {:ok, Dispute.t()} | {:error, :not_found}
  def get_dispute(account_id, market_id) when is_binary(account_id) and is_binary(market_id) do
    case :ets.lookup(@disputes_table, {account_id, market_id}) do
      [{_key, dispute}] -> {:ok, dispute}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  @spec list_disputes() :: [Dispute.t()]
  def list_disputes do
    :ets.foldl(fn {_key, dispute}, acc -> [dispute | acc] end, [], @disputes_table)
  rescue
    ArgumentError -> []
  end

  @spec list_disputes_for_market(binary()) :: [Dispute.t()]
  def list_disputes_for_market(market_id) when is_binary(market_id) do
    case :ets.lookup(@disputes_by_market_table, market_id) do
      [] ->
        []

      pairs ->
        for {^market_id, dispute_key} <- pairs,
            [{_, %Dispute{} = d}] <- [:ets.lookup(@disputes_table, dispute_key)],
            do: d
    end
  rescue
    ArgumentError -> []
  end

  @spec list_disputes_for_account(binary()) :: [Dispute.t()]
  def list_disputes_for_account(account_id) when is_binary(account_id) do
    case :ets.lookup(@disputes_by_account_table, account_id) do
      [] ->
        []

      pairs ->
        for {^account_id, dispute_key} <- pairs,
            [{_, %Dispute{} = d}] <- [:ets.lookup(@disputes_table, dispute_key)],
            do: d
    end
  rescue
    ArgumentError -> []
  end

  @spec list_disputes_by_status(Dispute.status()) :: [Dispute.t()]
  def list_disputes_by_status(status) when is_atom(status) do
    case :ets.lookup(@disputes_by_status_table, status) do
      [] ->
        []

      pairs ->
        for {^status, dispute_key} <- pairs,
            [{_, %Dispute{} = d}] <- [:ets.lookup(@disputes_table, dispute_key)],
            do: d
    end
  rescue
    ArgumentError -> []
  end

  @spec has_flagged?(binary(), binary()) :: boolean()
  def has_flagged?(account_id, market_id) when is_binary(account_id) and is_binary(market_id) do
    case :ets.lookup(@disputes_table, {account_id, market_id}) do
      # A cancelled dispute (user dismissed the modal without funding)
      # should not count as "flagged" — the button stays clickable so
      # they can try again.
      [{_key, %Dispute{status: :cancelled}}] -> false
      [{_key, _dispute}] -> true
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  @spec dispute_count(binary()) :: non_neg_integer()
  def dispute_count(market_id) when is_binary(market_id) do
    length(list_disputes_for_market(market_id))
  end

  @doc """
  Counts only `:live` disputes (deposit confirmed). Threshold
  evaluation uses this — unfunded disputes are noise.
  """
  @spec live_dispute_count(binary()) :: non_neg_integer()
  def live_dispute_count(market_id) when is_binary(market_id) do
    market_id
    |> list_disputes_for_market()
    |> Enum.count(&Dispute.live?/1)
  end

  @spec get_quote(binary()) :: {:ok, Quote.t()} | {:error, :not_found}
  def get_quote(id) when is_binary(id) do
    case :ets.lookup(@quotes_table, id) do
      [{^id, quote}] -> {:ok, quote}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  @doc """
  O(1) lookup of a Quote by its allocated Monero subaddress index.
  Returns the live Quote struct or `{:error, :not_found}`. Powers
  `Monero.Poller.lookup_subaddress/1` — replaces a per-deposit
  full-table scan of pending quotes.
  """
  @spec get_quote_by_subaddress(non_neg_integer()) :: {:ok, Quote.t()} | {:error, :not_found}
  def get_quote_by_subaddress(subaddress_index) when is_integer(subaddress_index) and subaddress_index > 0 do
    case :ets.lookup(@quotes_by_subaddress_table, subaddress_index) do
      [{^subaddress_index, quote_id}] ->
        case :ets.lookup(@quotes_table, quote_id) do
          [{^quote_id, %Quote{} = q}] -> {:ok, q}
          _ -> {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  def get_quote_by_subaddress(_), do: {:error, :not_found}

  @doc """
  O(1) lookup of a Dispute by its allocated Monero subaddress index.
  Powers `Monero.Poller.lookup_subaddress/1`.
  """
  @spec get_dispute_by_subaddress(non_neg_integer()) :: {:ok, Dispute.t()} | {:error, :not_found}
  def get_dispute_by_subaddress(subaddress_index) when is_integer(subaddress_index) and subaddress_index > 0 do
    case :ets.lookup(@disputes_by_subaddress_table, subaddress_index) do
      [{^subaddress_index, key}] ->
        case :ets.lookup(@disputes_table, key) do
          [{^key, %Dispute{} = d}] -> {:ok, d}
          _ -> {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  def get_dispute_by_subaddress(_), do: {:error, :not_found}

  @doc """
  O(1) lookup of a Market by its deposit subaddress index.
  Powers `Monero.Poller.lookup_subaddress/1`.
  """
  @spec get_market_by_subaddress(non_neg_integer()) :: {:ok, Market.t()} | {:error, :not_found}
  def get_market_by_subaddress(subaddress_index) when is_integer(subaddress_index) and subaddress_index > 0 do
    case :ets.lookup(@markets_by_subaddress_table, subaddress_index) do
      [{^subaddress_index, market_id}] ->
        case :ets.lookup(@markets_table, market_id) do
          [{^market_id, %Market{} = m}] -> {:ok, m}
          _ -> {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  def get_market_by_subaddress(_), do: {:error, :not_found}

  @spec list_quotes() :: [Quote.t()]
  def list_quotes do
    :ets.foldl(fn {_id, quote}, acc -> [quote | acc] end, [], @quotes_table)
  rescue
    ArgumentError -> []
  end

  @spec list_quotes_for_market(binary()) :: [Quote.t()]
  def list_quotes_for_market(market_id) when is_binary(market_id) do
    case :ets.lookup(@quotes_by_market_table, market_id) do
      [] ->
        []

      pairs ->
        for {^market_id, quote_id} <- pairs,
            [{_, %Quote{} = q}] <- [:ets.lookup(@quotes_table, quote_id)],
            do: q
    end
  rescue
    ArgumentError -> []
  end

  @spec list_quotes_for_account(binary()) :: [Quote.t()]
  def list_quotes_for_account(account_id) when is_binary(account_id) do
    case :ets.lookup(@quotes_by_account_table, account_id) do
      [] ->
        []

      pairs ->
        for {^account_id, quote_id} <- pairs,
            [{_, %Quote{} = q}] <- [:ets.lookup(@quotes_table, quote_id)],
            do: q
    end
  rescue
    ArgumentError -> []
  end

  @doc """
  Returns all quotes whose `expires_at` is at-or-before `now`.
  Backed by the `QuotesByExpiry` ordered-set index — the scheduler
  tick calls this to void expired quotes without full-scanning the
  primary quotes table.
  """
  @spec list_quotes_expired(DateTime.t()) :: [Quote.t()]
  def list_quotes_expired(%DateTime{} = now) do
    now_unix = DateTime.to_unix(now)

    match_spec = [
      {{{:"$1", :"$2"}}, [{:"=<", :"$1", now_unix}], [:"$2"]}
    ]

    ids = :ets.select(@quotes_by_expiry_table, match_spec)

    for id <- ids,
        [{_, %Quote{} = q}] <- [:ets.lookup(@quotes_table, id)],
        do: q
  rescue
    ArgumentError -> []
  end

  @doc """
  Reads a single ledger counter value. Returns 0 if the counter
  isn't initialised (e.g. table not yet started). Backs
  `Markets.Federation.Ledger.breakdown/0`.
  """
  @spec ledger_counter(atom()) :: non_neg_integer()
  def ledger_counter(key) when is_atom(key) do
    case :ets.lookup(@ledger_counters_table, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc """
  Reads all ledger counters as a map. One ETS read per counter
  (O(1) each); used by `Ledger.breakdown/0`.
  """
  @spec ledger_counters() :: %{atom() => non_neg_integer()}
  def ledger_counters do
    Map.new(Inserts.ledger_counter_keys(), &{&1, ledger_counter(&1)})
  end

  @doc """
  Current WAL state for this node — entry count and last sequence.
  `entry_count` is the union of locally-originated entries plus
  entries applied from peers via the Replicator. The `last_seq`
  field reads from the centralised `Storage.WAL.Sealer` counter so
  this number reflects WAL activity across ALL domains, not just
  Markets — the daily heartbeat uses it as a proof-of-life signal
  and a node whose Sealer is at 0 while a peer's is advancing is
  a clear "replication wedged" diagnostic.

  Published surface diagnostic. Pure read-only, returns stable-shape
  diagnostic metrics, designed to be called from any consumer (admin
  dashboard, telemetry publishers, heartbeat ticks).
  """
  @spec wal_info() :: %{entry_count: non_neg_integer(), last_seq: non_neg_integer()}
  def wal_info do
    %{wal_server: wal_server} = default_runtime()

    entry_count =
      case Locker.WAL.info(wal_server) do
        %{entry_count: n} when is_integer(n) and n >= 0 -> n
        _ -> 0
      end

    %{entry_count: entry_count, last_seq: StorageFacade.current_wal_seq()}
  rescue
    _ -> %{entry_count: 0, last_seq: 0}
  catch
    :exit, _ -> %{entry_count: 0, last_seq: 0}
  end

  # --- Write API ---
  #
  # Hybrid pattern: high-volume single-row writes that always target
  # distinct keys (votes, disputes, quotes) bypass the GenServer
  # mailbox and go straight to WAL+ETS. Sequence numbers come from
  # `:atomics` (lock-free atomic counter), WAL ordering is preserved
  # by `Locker.WAL`'s own serialised append, and the ETS tables for
  # these entities are `:public` with `write_concurrency: true`.
  #
  # Writes that touch the same row from concurrent paths
  # (`put_market`, `put_payout`) or that need cross-row atomicity
  # (`put_trade`, `put_resolution`, `put_fill`) keep the GenServer
  # path so the multi-step operation runs serialised.
  #
  # The bottleneck the sim found: with a single GenServer mailbox,
  # all writes contend for one process. 10K voters at realistic
  # activity saturate it. Direct-path writes scale with ETS write
  # concurrency, which is roughly two orders of magnitude higher.

  @spec put_market(Market.t()) :: :ok | {:error, term()}
  def put_market(market), do: put_market(__MODULE__, market)

  @spec put_market(GenServer.server(), Market.t()) :: :ok | {:error, term()}
  def put_market(server, %Market{} = market) do
    write_call(server, {:put_market, market})
  end

  @doc """
  Atomic check-and-commit of a `:rejected` market transition. The
  `Voter` rejection path is the canonical caller: when two voters
  concurrently cross the burn threshold, both arrive here with the
  same target market struct. Whichever request the GenServer
  handles first sees `prior_status != :rejected` and commits the
  write; the second sees `:rejected` already in place and returns
  `:already_rejected` without writing or emitting any side effect.
  The caller emits the `MarketRejected` and `DepositBurned` events
  only on `:transitioned`, so a single underlying transition
  produces exactly one event-stream emission.

  The previous flow (check via `get_market` then unconditionally
  call `put_market` then emit events) had a check-then-act race:
  both voters' `get_market` would see `:live`, both would call
  `put_market` (the second no-op'd at the counter layer but still
  durable in the WAL), and both would emit events — over-counting
  every event consumer (telemetry, audit log, sim Conservation
  invariant). The atomic variant collapses check and commit into
  a single GenServer handler invocation, eliminating the window.
  """
  @spec commit_market_rejection(Market.t()) ::
          {:ok, :transitioned} | {:ok, :already_rejected} | {:error, term()}
  def commit_market_rejection(market), do: commit_market_rejection(__MODULE__, market)

  @spec commit_market_rejection(GenServer.server(), Market.t()) ::
          {:ok, :transitioned} | {:ok, :already_rejected} | {:error, term()}
  def commit_market_rejection(server, %Market{status: :rejected} = market) do
    write_call(server, {:commit_market_rejection, market})
  end

  @doc """
  Direct-path write against the default singleton — bypasses the
  GenServer mailbox. Each vote has a unique `(account_id,
  market_id)` key, so concurrent writes never target the same
  ETS row.

  Tests that start a custom-named store use the `put_vote/2`
  arity with that server name, which routes through the
  GenServer for full isolation.
  """
  @spec put_vote(Vote.t()) :: :ok | {:error, term()}
  def put_vote(%Vote{} = vote) do
    direct_write(:vote_put, Serialize.vote(vote), fn ->
      Inserts.insert_vote(default_tables(), vote)
    end)
  end

  @spec put_vote(GenServer.server(), Vote.t()) :: :ok | {:error, term()}
  def put_vote(__MODULE__, %Vote{} = vote), do: put_vote(vote)
  def put_vote(server, %Vote{} = vote), do: write_call(server, {:put_vote, vote})

  @doc """
  Direct-path write against the default singleton. See
  `put_vote/1` for the rationale; same isolation contract for
  custom-named test stores via the 2-arity form.
  """
  @spec put_dispute(Dispute.t()) :: :ok | {:error, term()}
  def put_dispute(%Dispute{} = dispute) do
    direct_write(:dispute_put, Serialize.dispute(dispute), fn ->
      Inserts.insert_dispute(default_tables(), dispute)
    end)
  end

  @spec put_dispute(GenServer.server(), Dispute.t()) :: :ok | {:error, term()}
  def put_dispute(__MODULE__, %Dispute{} = dispute), do: put_dispute(dispute)
  def put_dispute(server, %Dispute{} = dispute), do: write_call(server, {:put_dispute, dispute})

  @doc """
  Atomic write of a market (with updated AMM pool) and a new
  position in a single WAL entry. Taking a position MUST atomically
  update the pool and the reservation, or fail entirely; on WAL
  append failure, neither table is mutated.

  The 3rd argument is the pre-trade snapshot the caller computed
  against (`%{pool: prev.pool, status: prev.status}`); the handler
  CAS-checks the live market against it and refuses with
  `{:error, :concurrent_modification}` if the pool or status has
  moved since the caller's read. Callers must re-quote against the
  fresh pool on that error.
  """
  @spec put_trade(Market.t(), Position.t(), map()) :: :ok | {:error, term()}
  def put_trade(market, position, expected),
    do: put_trade(__MODULE__, market, position, expected)

  @spec put_trade(GenServer.server(), Market.t(), Position.t(), map()) ::
          :ok | {:error, term()}
  def put_trade(server, %Market{} = market, %Position{} = position, expected)
      when is_map(expected) do
    write_call(server, {:put_trade, market, position, expected})
  end

  @doc """
  Atomic write of a market state change (settle/void) together with
  every position on that market in a single WAL entry. Settlement is
  atomic: winners credited and losers consumed in a single operation,
  or the system halts rather than partially apply.

  Empty position list is valid (a market with no participants
  settles cleanly).
  """
  @spec put_resolution(Market.t(), [Position.t()]) :: :ok | {:error, term()}
  def put_resolution(market, positions),
    do: put_resolution(__MODULE__, market, positions)

  @spec put_resolution(GenServer.server(), Market.t(), [Position.t()]) ::
          :ok | {:error, term()}
  def put_resolution(server, %Market{} = market, positions) when is_list(positions) do
    write_call(server, {:put_resolution, market, positions})
  end

  @doc """
  Like `put_resolution/2`, but compare-and-swap on the live market's
  status, outcome, and `disputes_acknowledged_count` BEFORE the WAL
  append. Used by `Resolver.settle/1` and `Resolver.void/1` to defend
  against:

  - **dispute → settle race** — a fresh dispute crossing the threshold
    between settle's check and its commit (if the live ack count
    differs from the snapshot, refuse).
  - **reverse → settle race** — `reverse_resolution` flipping
    `outcome` while settle is computing winners against the stale one.

  The `expected` map carries the snapshot fields the caller relied on:

      %{status: :resolving, outcome: :yes, disputes_acknowledged_count: 0}

  Returns `{:error, :concurrent_modification}` if the live market in
  ETS no longer matches; the caller MUST abort and re-read.
  """
  @spec put_resolution_cas(Market.t(), [Position.t()], map()) ::
          :ok | {:error, :concurrent_modification | term()}
  def put_resolution_cas(market, positions, expected),
    do: put_resolution_cas(__MODULE__, market, positions, [], expected)

  @spec put_resolution_cas(GenServer.server(), Market.t(), [Position.t()], map()) ::
          :ok | {:error, :concurrent_modification | term()}
  def put_resolution_cas(server, %Market{} = market, positions, expected)
      when is_list(positions) and is_map(expected) do
    write_call(server, {:put_resolution_cas, market, positions, [], expected})
  end

  @doc """
  Atomic market + positions + disputes write with CAS guard. Used by
  the void path when voiding from `:resolving` — the market state
  changes, open positions get refunded, and any live disputes get
  resolved-against (full refund, no slash), all as one WAL entry.

  The 3-arity `put_resolution_cas/3` delegates here with an empty
  disputes list for the settle path (no live disputes by that point)
  and for void from non-`:resolving` (no disputes to resolve).
  """
  @spec put_resolution_cas(Market.t(), [Position.t()], [Dispute.t()], map()) ::
          :ok | {:error, :concurrent_modification | term()}
  def put_resolution_cas(market, positions, disputes, expected)
      when is_list(disputes),
      do: put_resolution_cas(__MODULE__, market, positions, disputes, expected)

  @spec put_resolution_cas(
          GenServer.server(),
          Market.t(),
          [Position.t()],
          [Dispute.t()],
          map()
        ) :: :ok | {:error, :concurrent_modification | term()}
  def put_resolution_cas(server, %Market{} = market, positions, disputes, expected)
      when is_list(positions) and is_list(disputes) and is_map(expected) do
    write_call(server, {:put_resolution_cas, market, positions, disputes, expected})
  end

  @doc """
  Market-only CAS write. Like `put_resolution_cas/3` but without the
  position list — used for transitions that update the market alone
  (acknowledge_disputes / reverse_resolution). Fails with
  `{:error, :concurrent_modification}` if the in-store market no
  longer matches `expected`.
  """
  @spec put_market_cas(Market.t(), map()) ::
          :ok | {:error, :concurrent_modification | :market_not_found | term()}
  def put_market_cas(market, expected), do: put_market_cas(__MODULE__, market, expected)

  @spec put_market_cas(GenServer.server(), Market.t(), map()) ::
          :ok | {:error, :concurrent_modification | :market_not_found | term()}
  def put_market_cas(server, %Market{} = market, expected) when is_map(expected) do
    write_call(server, {:put_market_cas, market, expected})
  end

  @doc """
  Atomically re-tallies votes for a `:pending` market and writes
  the resulting reputation, all inside the serial handler so two
  concurrent voters can't race-overwrite each other's reputation
  with stale snapshots. The reputation_fn is applied to the live
  vote list inside the lock; the market is only re-written if it's
  still `:pending` at write time. No-op if the market has
  transitioned away from `:pending` (a concurrent burn won the race).
  Returns `{:ok, updated_market}` on a successful refresh,
  `{:ok, :not_pending}` if the market has moved on, or
  `{:error, :market_not_found}`.
  """
  @spec refresh_pending_market_reputation(binary(), ([Vote.t()] -> integer())) ::
          {:ok, Market.t() | :not_pending} | {:error, :market_not_found | term()}
  def refresh_pending_market_reputation(market_id, reputation_fn)
      when is_binary(market_id) and is_function(reputation_fn, 1) do
    write_call(__MODULE__, {:refresh_pending_market_reputation, market_id, reputation_fn})
  end

  @doc """
  Serialised write via the GenServer handler. Pre-fix `put_quote/1`
  ran the subaddress-collision check OUTSIDE the serial handler
  (caller process), then handed off to `direct_write/3` for the WAL
  append + insert. Two concurrent callers could both pass the
  pre-check on a shared free index before either wrote — a
  check-then-act race. The GenServer path (`handle_call({:put_quote,
  ...})`) collapses check + write into a single handler invocation
  under the serial write lock. Latency cost: one mailbox
  round-trip; correctness gain: no race.
  """
  @spec put_quote(Quote.t()) :: :ok | {:error, term()}
  def put_quote(%Quote{} = quote), do: put_quote(__MODULE__, quote)

  @spec put_quote(GenServer.server(), Quote.t()) :: :ok | {:error, term()}
  def put_quote(server, %Quote{} = quote), do: write_call(server, {:put_quote, quote})

  @doc """
  Removes an expired Quote from the store. Single-entity write —
  no AMM mutation since the Quote never filled. WAL-backed so the
  expiry is durable and replays correctly across restarts.
  """
  @spec put_quote_expired(binary()) :: :ok | {:error, term()}
  def put_quote_expired(quote_id), do: put_quote_expired(__MODULE__, quote_id)

  @spec put_quote_expired(GenServer.server(), binary()) :: :ok | {:error, term()}
  def put_quote_expired(server, quote_id) when is_binary(quote_id) do
    write_call(server, {:put_quote_expired, quote_id})
  end

  @doc """
  Atomic write of a quote fill: the updated market (AMM moved), the
  newly-created Position, removal of the consumed Quote — all in a
  single WAL entry. Same CAS shape as `put_trade/3`: `expected`
  carries the pre-fill snapshot the caller computed against, and
  the handler refuses with `{:error, :concurrent_modification}` if
  the live pool or status has moved since (e.g. Scheduler expired
  the market between fetch_market and put_fill).
  """
  @spec put_fill(Market.t(), Position.t(), binary(), map()) :: :ok | {:error, term()}
  def put_fill(%Market{} = market, position, quote_id, expected),
    do: put_fill(__MODULE__, market, position, quote_id, expected, [])

  @spec put_fill(GenServer.server(), Market.t(), Position.t(), binary(), map()) ::
          :ok | {:error, term()}
  def put_fill(server, %Market{} = market, position, quote_id, expected)
      when is_binary(quote_id) and is_map(expected) do
    write_call(server, {:put_fill, market, position, quote_id, expected, []})
  end

  @spec put_fill(Market.t(), Position.t(), binary(), map(), keyword()) :: :ok | {:error, term()}
  def put_fill(%Market{} = market, position, quote_id, expected, opts),
    do: put_fill(__MODULE__, market, position, quote_id, expected, opts)

  @spec put_fill(GenServer.server(), Market.t(), Position.t(), binary(), map(), keyword()) ::
          :ok | {:error, term()}
  def put_fill(server, %Market{} = market, position, quote_id, expected, opts)
      when is_binary(quote_id) and is_map(expected) do
    write_call(server, {:put_fill, market, position, quote_id, expected, opts})
  end

  @doc """
  Persists a position transitioning to `:paid_out`. Single-entity
  write — there is no AMM mutation at payout time, the pool was
  already settled at market resolution. The new WAL type
  (`:position_paid_out`) keeps payout records distinct in the audit
  trail from the original settlement.
  """
  @spec put_payout(Position.t()) :: :ok | {:error, term()}
  def put_payout(position), do: put_payout(__MODULE__, position)

  @spec put_payout(GenServer.server(), Position.t()) :: :ok | {:error, term()}
  def put_payout(server, %Position{} = position) do
    write_call(server, {:put_payout, position})
  end

  @spec clear() :: :ok
  def clear, do: clear(__MODULE__)

  @spec clear(GenServer.server()) :: :ok
  def clear(server), do: GenServer.call(server, :clear)

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

  # `:wal_overloaded` is Locker.WAL's mailbox-saturation backpressure
  # signal. Under burst load (sim stress, real-world surge claim
  # windows) it can fire transiently. Retry with exponential-backoff
  # so callers see a transparent `:ok` after the brief saturation
  # clears, falling back to surfacing the error if retries exhaust.
  # Used by both `direct_write/3` (caller-process) and `write_call/2`
  # (caller-process wrapper around GenServer.call) — the sleep runs
  # in the caller's process, not the Store GenServer, so it never
  # blocks other writes.
  @wal_retry_delays_ms [1, 5, 25, 100]

  # 30s timeout — generous so a backed-up mailbox under genuine
  # load (large sim runs, surge claim windows) doesn't surface as
  # a {:timeout, _} exit and obscure real progress. Production
  # writes complete in milliseconds; if they ever take more than
  # 30s the system has a structural problem worth investigating
  # rather than masking with a tighter budget.
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

  @spec table_names() :: %{
          markets: atom(),
          positions: atom(),
          votes: atom(),
          quotes: atom(),
          disputes: atom(),
          positions_by_market: atom(),
          votes_by_market: atom(),
          markets_by_status: atom(),
          positions_by_account: atom(),
          positions_by_status: atom(),
          disputes_by_market: atom(),
          disputes_by_account: atom(),
          quotes_by_market: atom(),
          quotes_by_account: atom(),
          markets_by_category: atom(),
          markets_by_creator: atom(),
          disputes_by_status: atom(),
          quotes_by_subaddress: atom(),
          disputes_by_subaddress: atom(),
          markets_by_subaddress: atom(),
          ledger_counters: atom()
        }
  def table_names do
    %{
      markets: @markets_table,
      positions: @positions_table,
      votes: @votes_table,
      quotes: @quotes_table,
      disputes: @disputes_table,
      positions_by_market: @positions_by_market_table,
      votes_by_market: @votes_by_market_table,
      markets_by_status: @markets_by_status_table,
      positions_by_account: @positions_by_account_table,
      positions_by_status: @positions_by_status_table,
      disputes_by_market: @disputes_by_market_table,
      disputes_by_account: @disputes_by_account_table,
      quotes_by_market: @quotes_by_market_table,
      quotes_by_account: @quotes_by_account_table,
      markets_by_category: @markets_by_category_table,
      markets_by_creator: @markets_by_creator_table,
      disputes_by_status: @disputes_by_status_table,
      quotes_by_subaddress: @quotes_by_subaddress_table,
      disputes_by_subaddress: @disputes_by_subaddress_table,
      markets_by_subaddress: @markets_by_subaddress_table,
      ledger_counters: @ledger_counters_table
    }
  end

  # --- GenServer ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    wal_server = Keyword.get(opts, :wal_server, PerpWalk.Storage.WAL)
    server_name = Keyword.get(opts, :name, __MODULE__)
    tables = build_table_config(opts)

    # Force-load every module whose atoms can appear as values inside
    # serialised payloads. `binary_to_term(bin, [:safe])` rejects atoms
    # not in the atom table at decode time, and Elixir loads modules
    # lazily — so on a cold boot the replay would otherwise drop every
    # entry referencing e.g. `:politics` (a Categories atom never
    # touched by code that has run yet).
    Enum.each(
      [Categories, Market, Position, Quote, Vote, Dispute, AMM],
      &Code.ensure_loaded!/1
    )

    Enum.each(tables, fn {role, name} -> create_ets_table(role, name) end)
    Inserts.init_ledger_counters(tables)
    Replay.replay_wal(wal_server, tables)

    # Seq allocation lives in the Storage domain — the centralised
    # global counter is initialised by the Storage supervisor before
    # the Markets supervisor boots, so writes from this store go
    # through `Storage.Facade.seal/1` or `Storage.Facade.seal_and_append/3`
    # and inherit the global monotonic seq invariant.
    if server_name == __MODULE__ do
      publish_default_runtime(wal_server, tables)
    end

    {:ok, %{wal_server: wal_server, tables: tables}}
  end

  @impl true
  def handle_call({:put_market, market}, _from, state) do
    case Inserts.subaddress_available_for_market(state.tables, market) do
      :ok ->
        write_simple(state, :market_put, Serialize.market(market), fn ->
          Inserts.insert_market(state.tables, market)
        end)

      {:error, :subaddress_collision} ->
        # Fail closed at the live-write boundary — letting the WAL
        # absorb a collision would silently orphan the prior Market's
        # deposit attribution. Same posture as `put_quote`.
        {:reply, {:error, :subaddress_collision}, state}
    end
  end

  def handle_call({:commit_market_rejection, market}, _from, state) do
    case :ets.lookup(state.tables.markets, market.id) do
      [{_, %Market{status: :rejected}}] ->
        {:reply, {:ok, :already_rejected}, state}

      [{_, %Market{status: :pending}}] ->
        case write_simple(state, :market_put, Serialize.market(market), fn ->
               Inserts.insert_market(state.tables, market)
             end) do
          {:reply, :ok, new_state} -> {:reply, {:ok, :transitioned}, new_state}
          {:reply, err, new_state} -> {:reply, err, new_state}
        end

      [{_, %Market{status: live_status}}] ->
        # Live status is neither `:pending` (rejectable) nor `:rejected`
        # (idempotent no-op). Reject the reject. The rejection vote
        # tally was accumulated against a stale `:pending` snapshot;
        # the market has since been activated and traders may have
        # opened positions against it. Clobbering `:active` → `:rejected`
        # would burn the creator's deposit AND strand every opened
        # position in `:open` forever (`Market.void` only accepts
        # `:expired | :resolving`).
        #
        # Correct behaviour: refuse the transition. The vote-threshold
        # logic upstream should treat this as a lost race and NOT
        # slash the creator. Positions on the now-active market carry
        # on normally.
        {:reply, {:error, {:not_rejectable, live_status}}, state}

      [] ->
        {:reply, {:error, :market_not_found}, state}
    end
  end

  def handle_call({:put_vote, vote}, _from, state) do
    write_simple(state, :vote_put, Serialize.vote(vote), fn ->
      Inserts.insert_vote(state.tables, vote)
    end)
  end

  def handle_call({:put_dispute, dispute}, _from, state) do
    case Inserts.subaddress_available_for_dispute(state.tables, dispute) do
      :ok ->
        write_simple(state, :dispute_put, Serialize.dispute(dispute), fn ->
          Inserts.insert_dispute(state.tables, dispute)
        end)

      {:error, :subaddress_collision} ->
        {:reply, {:error, :subaddress_collision}, state}
    end
  end

  def handle_call({:put_trade, market, position, expected}, _from, state) do
    case cas_trade_market(state, market.id, expected) do
      :ok ->
        payload = %{
          market: Serialize.market(market),
          position: Serialize.position(position)
        }

        write_simple(state, :trade_executed, payload, fn ->
          Inserts.insert_market(state.tables, market)
          Inserts.insert_position(state.tables, position)
        end)

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:put_resolution, market, positions}, _from, state) do
    do_put_resolution(market, positions, [], state)
  end

  def handle_call({:put_resolution_cas, market, positions, disputes, expected}, _from, state) do
    case :ets.lookup(state.tables.markets, market.id) do
      [{_id, %Market{} = live}] ->
        if Inserts.cas_matches?(live, expected, state.tables) do
          do_put_resolution(market, positions, disputes, state)
        else
          {:reply, {:error, :concurrent_modification}, state}
        end

      [] ->
        {:reply, {:error, :market_not_found}, state}
    end
  end

  def handle_call({:put_market_cas, market, expected}, _from, state) do
    case :ets.lookup(state.tables.markets, market.id) do
      [{_id, %Market{} = live}] ->
        if Inserts.cas_matches?(live, expected, state.tables) do
          write_simple(state, :market_put, Serialize.market(market), fn ->
            Inserts.insert_market(state.tables, market)
          end)
        else
          {:reply, {:error, :concurrent_modification}, state}
        end

      [] ->
        {:reply, {:error, :market_not_found}, state}
    end
  end

  def handle_call({:refresh_pending_market_reputation, market_id, reputation_fn}, _from, state) do
    case :ets.lookup(state.tables.markets, market_id) do
      [{_id, %Market{status: :pending} = live}] ->
        votes = lookup_votes_for_market(state.tables, market_id)
        reputation = reputation_fn.(votes)
        updated = Market.put_reputation(live, reputation)

        write_simple(state, :market_put, Serialize.market(updated), fn ->
          Inserts.insert_market(state.tables, updated)
        end)
        |> case do
          {:reply, :ok, new_state} -> {:reply, {:ok, updated}, new_state}
          {:reply, {:error, _} = err, new_state} -> {:reply, err, new_state}
        end

      [{_id, %Market{}}] ->
        {:reply, {:ok, :not_pending}, state}

      [] ->
        {:reply, {:error, :market_not_found}, state}
    end
  end

  def handle_call({:put_quote, quote}, _from, state) do
    case Inserts.subaddress_available_for_quote(state.tables, quote) do
      :ok ->
        write_simple(state, :quote_put, Serialize.quote(quote), fn ->
          Inserts.insert_quote(state.tables, quote)
        end)

      {:error, :subaddress_collision} ->
        {:reply, {:error, :subaddress_collision}, state}
    end
  end

  def handle_call({:put_quote_expired, quote_id}, _from, state) do
    write_simple(state, :quote_expired, %{quote_id: quote_id}, fn ->
      Inserts.delete_quote(state.tables, quote_id)
    end)
  end

  def handle_call({:put_fill, market, position, quote_id, expected, opts}, _from, state) do
    # Quote-existence check inside the serialised handler — the
    # public `fill_quote/2` path looks up the quote outside the
    # GenServer, so without this check a concurrent caller could
    # race past the lookup and double-fill (one deposit → two
    # positions). The only production caller (Darks.Poller) is
    # single-threaded and dedupes by txid, but defence-in-depth is
    # cheap and forecloses future callers introducing the race.
    case :ets.lookup(state.tables.quotes, quote_id) do
      [{^quote_id, _quote}] ->
        case cas_trade_market(state, market.id, expected) do
          :ok ->
            payload = %{
              market: Serialize.market(market),
              position: Serialize.position(position),
              quote_id: quote_id,
              deposit_txid: Keyword.get(opts, :deposit_txid)
            }

            write_simple(state, :quote_filled, payload, fn ->
              Inserts.insert_market(state.tables, market)
              Inserts.insert_position(state.tables, position)
              Inserts.delete_quote(state.tables, quote_id)
            end)

          {:error, _} = err ->
            {:reply, err, state}
        end

      [] ->
        {:reply, {:error, :quote_not_found}, state}
    end
  end

  def handle_call({:put_payout, position}, _from, state) do
    write_simple(state, :position_paid_out, Serialize.position(position), fn ->
      Inserts.insert_position(state.tables, position)
    end)
  end

  def handle_call({:replicate_entries, entries}, _from, state) do
    # In the symmetric bi-directional model both hot nodes receive
    # `replicate_entries` from their Replicator (each pulls entries
    # with `:origin == peer_id` from its peers). `apply_entries`
    # mutates ETS without re-appending to the local WAL — the WAL
    # append happens at the Replicator boundary so a local node only
    # applies entries it received from a peer here.
    #
    # `emit_events: true` re-publishes the corresponding local event
    # for each applied entry so the follower's LiveViews receive UI
    # notifications for cluster-writes originated on the designated
    # processor (`EventBus.publish` is `local_broadcast` only — see
    # `Replay.apply_entries/3` for the covered event set).
    Replay.apply_entries(entries, state.tables, emit_events: true)
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    Enum.each(state.tables, fn {_role, name} -> :ets.delete_all_objects(name) end)
    Inserts.init_ledger_counters(state.tables)
    {:reply, :ok, state}
  end

  # Stamps the next seq onto `payload` via `Storage.Facade.seal_and_append/3`,
  # appends to WAL, and on success runs `commit_fun` (the ETS
  # mutation). Seq allocation is NOT rolled back on WAL failure — a
  # failed append leaves a hole in the global seq sequence. Per-type
  # seq tracking during replay uses `seq > last`, not `last + 1`, so
  # gaps are silently tolerated; they don't break monotonicity or
  # replay correctness. The tradeoff is a non-contiguous global seq
  # counter in exchange for lock-free seq allocation across the
  # direct-path writers.
  # CAS gate for trade + fill writes. The caller reads the market,
  # computes an AMM update off that snapshot, and hands both the
  # snapshot (`expected`) and the post-trade market to the store.
  # Inside the serialised handler we re-read the live market and
  # refuse the write if the pool or status has moved since the
  # caller's read — same shape as `put_resolution_cas`.
  #
  # Two concurrent trades against the same pool used to both write
  # against the same starting pool state, with the second commit
  # erasing the first's update (`(k1, k2)` invariant collapses to
  # ~k1 while both positions persist → claims > collateral).
  # A late fill landing after Scheduler's `expire` used to revert
  # `:expired` to `:active`.
  defp cas_trade_market(state, market_id, expected)
       when is_map(expected) do
    case :ets.lookup(state.tables.markets, market_id) do
      [{^market_id, %Market{} = live}] ->
        if Inserts.cas_matches?(live, expected, state.tables),
          do: :ok,
          else: {:error, :concurrent_modification}

      [] ->
        {:error, :market_not_found}
    end
  end

  defp write_simple(state, type, payload, commit_fun)
       when is_atom(type) and is_map(payload) and is_function(commit_fun, 0) do
    case StorageFacade.seal_and_append(type, payload, state.wal_server) do
      :ok ->
        commit_fun.()
        {:reply, :ok, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  # Direct-path writers (put_vote, put_dispute, put_quote) call this
  # without an outer GenServer.call. The seq is allocated AND the
  # entry is Ed25519-signed by `Storage.Facade.seal/2` under the
  # local federation key; the local append-with-retry wraps the WAL
  # append so transient `:wal_overloaded` doesn't burn a write
  # attempt. The already-allocated seq and signature are preserved
  # across retries — same entry, same seq, same sig, just a re-attempt
  # at the append.
  #
  # In federated mode with no local signing key, `seal/2` returns
  # `{:error, :no_signing_key}` — the write is refused rather than
  # silently emitted unsigned, which would cascade into peer-side
  # replication halts.
  defp direct_write(type, payload, commit_fun)
       when is_atom(type) and is_map(payload) and is_function(commit_fun, 0) do
    %{wal_server: wal_server} = default_runtime()

    case StorageFacade.seal(type, payload) do
      {:ok, sealed} ->
        entry = %Entry{type: type, payload: sealed}

        case append_with_retry(wal_server, entry, @wal_retry_delays_ms) do
          :ok ->
            commit_fun.()
            :ok

          {:error, _} = err ->
            err
        end

      {:error, :no_signing_key} = err ->
        err
    end
  rescue
    # If the Store GenServer crashed and the new instance is mid-replay,
    # the named ETS tables referenced by the OLD persistent_term runtime
    # are dead. `commit_fun.()` would crash this caller (LiveView, Plug)
    # with ArgumentError when it tries `:ets.insert` on the dead table.
    # Return a friendly back-pressure error so the caller can retry.
    ArgumentError -> {:error, :store_restarting}
  end

  defp append_with_retry(wal_server, entry, delays) do
    case Locker.WAL.append(wal_server, entry) do
      :ok ->
        :ok

      {:error, :wal_overloaded} when delays != [] ->
        [delay | rest] = delays
        Process.sleep(delay)
        append_with_retry(wal_server, entry, rest)

      {:error, _} = err ->
        err
    end
  end

  defp lookup_votes_for_market(tables, market_id) do
    case :ets.lookup(tables.votes_by_market, market_id) do
      [] ->
        []

      pairs ->
        for {^market_id, vote_key} <- pairs,
            [{_, %Vote{} = v}] <- [:ets.lookup(tables.votes, vote_key)],
            do: v
    end
  end

  defp do_put_resolution(market, positions, disputes, state) do
    payload = %{
      market: Serialize.market(market),
      positions: Enum.map(positions, &Serialize.position/1),
      disputes: Enum.map(disputes, &Serialize.dispute/1)
    }

    write_simple(state, :market_resolved, payload, fn ->
      prior_market_status = Inserts.lookup_market_status(state.tables, market.id)
      Inserts.insert_market(state.tables, market)

      Enum.each(positions, fn p ->
        Inserts.insert_position(state.tables, p)
      end)

      Enum.each(disputes, fn d ->
        Inserts.insert_dispute(state.tables, d)
      end)

      # Spread is the per-trade fee captured into positions at fill
      # time, only realised as federation revenue when the market
      # actually settles. Voided / refunded markets refund the spread
      # with the trader, so they don't contribute. The transition
      # is detected here (not inside `insert_market`) because the
      # position list — the source of the spread numbers — is only
      # in scope at the resolution call.
      if prior_market_status != :settled and market.status == :settled do
        spread =
          Enum.reduce(positions, 0, fn p, acc -> acc + (p.spread_piconeros || 0) end)

        if spread > 0 do
          :ets.update_counter(
            state.tables.ledger_counters,
            :spread_total_piconeros,
            spread,
            {:spread_total_piconeros, 0}
          )
        end
      end
    end)
  end

  # --- Helpers ---

  defp build_table_config(opts) do
    %{
      markets: Keyword.get(opts, :markets_table, @markets_table),
      positions: Keyword.get(opts, :positions_table, @positions_table),
      votes: Keyword.get(opts, :votes_table, @votes_table),
      quotes: Keyword.get(opts, :quotes_table, @quotes_table),
      disputes: Keyword.get(opts, :disputes_table, @disputes_table),
      positions_by_market: Keyword.get(opts, :positions_by_market_table, @positions_by_market_table),
      votes_by_market: Keyword.get(opts, :votes_by_market_table, @votes_by_market_table),
      markets_by_status: Keyword.get(opts, :markets_by_status_table, @markets_by_status_table),
      positions_by_account: Keyword.get(opts, :positions_by_account_table, @positions_by_account_table),
      positions_by_status: Keyword.get(opts, :positions_by_status_table, @positions_by_status_table),
      disputes_by_market: Keyword.get(opts, :disputes_by_market_table, @disputes_by_market_table),
      disputes_by_account: Keyword.get(opts, :disputes_by_account_table, @disputes_by_account_table),
      quotes_by_market: Keyword.get(opts, :quotes_by_market_table, @quotes_by_market_table),
      quotes_by_account: Keyword.get(opts, :quotes_by_account_table, @quotes_by_account_table),
      quotes_by_expiry: Keyword.get(opts, :quotes_by_expiry_table, @quotes_by_expiry_table),
      markets_by_category: Keyword.get(opts, :markets_by_category_table, @markets_by_category_table),
      markets_by_creator: Keyword.get(opts, :markets_by_creator_table, @markets_by_creator_table),
      disputes_by_status: Keyword.get(opts, :disputes_by_status_table, @disputes_by_status_table),
      quotes_by_subaddress: Keyword.get(opts, :quotes_by_subaddress_table, @quotes_by_subaddress_table),
      disputes_by_subaddress: Keyword.get(opts, :disputes_by_subaddress_table, @disputes_by_subaddress_table),
      markets_by_subaddress: Keyword.get(opts, :markets_by_subaddress_table, @markets_by_subaddress_table),
      ledger_counters: Keyword.get(opts, :ledger_counters_table, @ledger_counters_table)
    }
  end

  # Roles whose backing ETS table is a `:bag`. Index tables are
  # bags keyed by either an attribute value (status / account /
  # market_id) so multiple ids can share a key. Primary tables
  # stay :set. The actual ETS table NAMES are module-qualified —
  # see the @*_table attributes above.
  @bag_roles [
    :positions_by_market,
    :votes_by_market,
    :markets_by_status,
    :positions_by_account,
    :positions_by_status,
    :disputes_by_market,
    :disputes_by_account,
    :disputes_by_status,
    :quotes_by_market,
    :quotes_by_account,
    :markets_by_category,
    :markets_by_creator
  ]

  # Roles whose backing ETS table is :public + write_concurrency,
  # because the direct-write path inserts into them from arbitrary
  # caller processes. Tables only the GenServer writes stay
  # :protected. `ledger_counters` is public because slash/burn
  # transitions arrive via `put_dispute` (direct path) — the
  # counter update needs to happen in the caller process alongside
  # the entity write.
  @public_write_roles [
    :votes,
    :votes_by_market,
    :disputes,
    :disputes_by_market,
    :disputes_by_account,
    :disputes_by_status,
    :disputes_by_subaddress,
    :quotes,
    :quotes_by_market,
    :quotes_by_account,
    :quotes_by_expiry,
    :quotes_by_subaddress,
    :ledger_counters
  ]

  # Roles whose backing ETS table is `:ordered_set` (range scan by
  # first key element). Insertions store rows shaped
  # `{{sort_key, entity_id}}` — key is the compound tuple, no value.
  @ordered_set_roles [:quotes_by_expiry]

  defp create_ets_table(role, name) do
    type =
      cond do
        role in @ordered_set_roles -> :ordered_set
        role in @bag_roles -> :bag
        true -> :set
      end

    access = if role in @public_write_roles, do: :public, else: :protected

    opts = [:named_table, type, access, read_concurrency: true]
    opts = if access == :public, do: opts ++ [write_concurrency: true], else: opts

    case :ets.whereis(name) do
      :undefined -> :ets.new(name, opts)
      _ref -> name
    end
  end

  # Seeds the ledger counter table with every key at zero so reads
  # never have to handle missing-key fallback. WAL replay (which
  # follows) drives the values up through the same `insert_*`
  # helpers that production writes go through, so a cold-boot leaves
  # the counters at the same totals an index-derivation would
  # produce. On restart of an already-populated store the counters
  # are also reset to zero before replay rebuilds them — this is
  # the only correct behaviour, since replay applies every WAL entry
  # from seq 1 and incremental counter updates must start from a
  # known zero baseline.

  # --- Atomic Seq Counter + Runtime Registry ---

  # The default singleton's runtime (wal_server + ETS table handles)
  # is published once for the direct-path readers (votes, disputes,
  # quotes) to consume without going through the GenServer. Seq
  # allocation no longer lives here — it's the centralised
  # `Storage.WAL.Sealer` responsibility. Test-only custom-named
  # store instances don't publish a runtime; their direct path
  # callers are routed through the GenServer.
  @runtime_key {__MODULE__, :default_runtime}

  defp publish_default_runtime(wal_server, tables) do
    :persistent_term.put(@runtime_key, %{
      wal_server: wal_server,
      tables: tables
    })
  end

  defp default_runtime, do: :persistent_term.get(@runtime_key)
  defp default_tables, do: default_runtime().tables

  @doc """
  Delegates to `Markets.Store.Replay.apply_entries/2`. Kept on the
  Store module so tests and external callers can drive the dispatch
  logic without reaching into the submodule. See `Store.Replay`
  for the per-type seq tracking and dispatch logic.
  """
  @spec apply_entries([Entry.t()], map()) :: %{
          applied: non_neg_integer(),
          skipped: non_neg_integer(),
          max_seq: non_neg_integer()
        }
  defdelegate apply_entries(entries, tables), to: Replay

  @doc "See `Markets.Store.Replay.apply_entries/3`."
  @spec apply_entries([Entry.t()], map(), keyword()) :: %{
          applied: non_neg_integer(),
          skipped: non_neg_integer(),
          max_seq: non_neg_integer()
        }
  defdelegate apply_entries(entries, tables, opts), to: Replay
end
