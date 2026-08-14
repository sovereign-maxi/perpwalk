defmodule PerpWalk.Markets.Comments.Inbox do
  @moduledoc """
  In-memory inbox for verified Nostr comments on PERP WALK markets.

  Receives signed kind:1 Nostr events via `ingest/1` (called by the
  relay subscriber pool once the WebSocket plumbing lands in S5b),
  dedups by event id across relays — the same comment is typically
  echoed by every relay that holds it — and indexes by market id so
  the market detail LiveView can render a comment feed in O(1).

  Publishes `MarketsEvents.CommentReceived` on the EventBus when a
  *new* comment arrives (post-dedup), so a LiveView already mounted
  on the relevant market detail page appends without re-fetching.

  ## Persistence

  WAL-backed. Every new ingest appends a `:comment_ingested` WAL
  entry before the ETS insert lands, so a restart or deploy re-
  hydrates the cache from the local WAL rather than depending on
  relay retention. Comments are authored by anonymous per-venue
  keypairs derived from a six-word keyphrase — there's no "we
  hold your speech" concern because the venue has no identity to
  attach to the content. Replicated to peers via the standard
  bi-directional replicator (`Markets.Facade.replicate_entries/1`
  fans to both `Store` and `Inbox`).

  The in-memory cache is still bounded by the most-recently-seen
  comments per market and ages out via the periodic sweep; the WAL
  is the durability floor, not the working set.
  """

  use GenServer

  require Logger

  alias Locker.WAL.Entry
  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.Store, as: MarketsStore
  alias PerpWalk.Storage.Facade, as: StorageFacade
  alias PerpWalk.Storage.WAL, as: StorageWAL

  @table __MODULE__
  @by_market_table __MODULE__.ByMarket

  # Cap on the number of distinct comments retained per market in
  # the secondary index. Reads pull from this index so we cap to
  # bound LiveView render cost; older entries fall off but the
  # primary `@table` still indexes them for explicit `get/1` lookups
  # until the sweep runs. The bound is generous enough that no
  # realistic market hits it before resolution.
  @per_market_cap 500

  # Hard ceiling on the primary table size. Without this, a hostile
  # Nostr publisher can flood the venue's subscribed relays with
  # signed kind:1 events tagged at the venue's pubkey: each one
  # passes Schnorr verification (any keypair signs validly) and
  # lands in ETS for 14 days. The cap bounds total memory at
  # roughly `@primary_cap × @max_content_bytes` (~500MB at 100k
  # entries × 5KB). On overflow, the oldest entries (by primary
  # insert order) are evicted ahead of the natural age sweep.
  @primary_cap 100_000

  # Per-comment content ceiling, enforced at ingest AND on the
  # replication/replay path. Nostr kind:1 content is unbounded at
  # the protocol level — without this a single "comment" could
  # carry megabytes into ETS and the WAL.
  @max_content_bytes 5_000

  # How long a comment stays in the cache. Generous because relays
  # are the source of truth — the cache is just there to avoid
  # round-tripping for every render.
  @max_age_ms 14 * 24 * 60 * 60 * 1_000
  @sweep_interval_ms 60 * 60 * 1_000

  @typedoc "Verified, deduped comment as held by the inbox."
  @type comment :: %{
          event_id: String.t(),
          market_id: binary(),
          author_pubkey: String.t(),
          content: String.t(),
          created_at: integer(),
          received_at_ms: integer()
        }

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Ingests a verified comment. The shape matches
  `PerpWalk.Nostr.Event.comment_attributes/2` output. Returns
  `{:ok, :new}` if this is the first time we've seen the event id,
  `{:ok, :duplicate}` if it was already in the cache, and skips the
  EventBus emission in the duplicate case. `{:ok, :unknown_market}`,
  `{:ok, :oversized}`, and `{:ok, :inbox_full}` are polite drops —
  the event never reaches ETS or the WAL.
  """
  @spec ingest(map()) ::
          {:ok, :new | :duplicate | :unknown_market | :oversized | :inbox_full}
          | {:error, term()}
  def ingest(%{} = attrs) do
    GenServer.call(__MODULE__, {:ingest, attrs})
  end

  @doc """
  Lists comments for `market_id`, newest first (descending by
  `created_at`). Direct ETS read — no GenServer round-trip.

  Capped at `@per_market_cap` entries via the maintained secondary
  index. For the LiveView render path this is the only call site.
  """
  @spec list_for_market(binary()) :: [comment()]
  def list_for_market(market_id) when is_binary(market_id) do
    case :ets.lookup(@by_market_table, market_id) do
      [{^market_id, comments}] ->
        Enum.sort_by(comments, & &1.created_at, :desc)

      [] ->
        []
    end
  rescue
    ArgumentError -> []
  end

  @doc """
  Fetches a single comment by Nostr event id.
  """
  @spec get(String.t()) :: {:ok, comment()} | {:error, :not_found}
  def get(event_id) when is_binary(event_id) do
    case :ets.lookup(@table, event_id) do
      [{^event_id, comment}] -> {:ok, comment}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  @doc "Total number of distinct comments currently cached."
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table, :size) || 0
  rescue
    ArgumentError -> 0
  end

  @doc """
  Test helper — wipes both ETS tables. Production code never calls
  this; the periodic sweep handles aging-out.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc """
  Applies replicated `:comment_ingested` WAL entries to the local
  ETS cache. Called by `Markets.Facade.replicate_entries/1` — every
  guardian applies every peer's comment writes so the inboxes
  converge across the federation.
  """
  @spec replicate_entries([Entry.t()]) :: :ok
  def replicate_entries(entries) when is_list(entries) do
    entries
    |> Enum.filter(&comment_entry?/1)
    |> Enum.each(&apply_entry_local/1)

    :ok
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    create_tables()
    replay_wal()
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:ingest, attrs}, _from, state) do
    result = do_ingest(attrs)
    {:reply, result, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@by_market_table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.system_time(:millisecond) - @max_age_ms
    sweep_primary(cutoff)
    rebuild_by_market_from_primary()
    schedule_sweep()
    {:noreply, state}
  rescue
    ArgumentError ->
      schedule_sweep()
      {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  defp do_ingest(attrs) do
    event_id = Map.fetch!(attrs, :event_id)
    market_id = Map.fetch!(attrs, :market_id)

    cond do
      require_market_existence?() and not market_exists?(market_id) ->
        # A Nostr publisher can sign any kind:1 event with any keypair
        # and tag it at the venue's pubkey — the signature verifies
        # but the referenced market_id is attacker-chosen. Refuse so
        # the primary table doesn't fill with fake-market entries.
        {:ok, :unknown_market}

      oversized_content?(attrs) ->
        # Bound per-comment memory before the row touches ETS or the
        # WAL. Dropped politely — the publisher learns nothing.
        {:ok, :oversized}

      :ets.info(@table, :size) >= @primary_cap ->
        # At cap. Drop on the floor rather than evicting in-place;
        # the next hourly sweep will reclaim natural expiry slots.
        # Operator should see the situation via the size telemetry
        # well before this threshold trips for legitimate traffic.
        {:ok, :inbox_full}

      true ->
        case :ets.lookup(@table, event_id) do
          [{^event_id, _}] ->
            {:ok, :duplicate}

          [] ->
            comment = build_comment(attrs)

            # WAL-first: a crash between here and the ETS insert
            # is safe because replay on next boot re-inserts from
            # this entry. Replicated to peers via the standard
            # bi-directional replicator. If Sealer refuses (fed
            # mode + no local signing key) the comment is dropped
            # rather than half-persisted — no ETS insert, no event
            # publish, caller gets the error.
            case StorageFacade.seal_and_append(:comment_ingested, comment) do
              :ok ->
                :ets.insert(@table, {event_id, comment})
                update_by_market_index(market_id, comment)

                EventBus.publish(%MarketsEvents.CommentReceived{
                  event_id: event_id,
                  market_id: market_id,
                  author_pubkey: comment.author_pubkey,
                  content: comment.content,
                  created_at: comment.created_at,
                  timestamp: DateTime.utc_now()
                })

                {:ok, :new}

              {:error, reason} = err ->
                Logger.error(
                  "Inbox: WAL write failed for comment " <>
                    "market=#{inspect(market_id)}, reason=#{inspect(reason)}"
                )

                err
            end
        end
    end
  end

  # --- WAL replay + replication apply ---

  # Cold-boot rehydration. Reads every entry from the local WAL,
  # filters for `:comment_ingested`, and re-inserts into ETS
  # without re-writing to WAL (idempotent on event_id). The sweep
  # tick that fires shortly after boot drops any replayed entries
  # older than @max_age_ms.
  defp replay_wal do
    case safe_read_all() do
      {:ok, entries} ->
        entries
        |> Enum.filter(&comment_entry?/1)
        |> Enum.each(&apply_entry_local/1)

      {:error, reason} ->
        Logger.warning("Inbox: WAL replay failed, reason=#{inspect(reason)}")

      :unavailable ->
        Logger.warning("Inbox: WAL replay skipped, reason=wal_unavailable")
    end
  end

  defp safe_read_all do
    Locker.WAL.read_all(StorageWAL)
  catch
    :exit, _ -> :unavailable
  end

  defp comment_entry?(%Entry{type: :comment_ingested}), do: true
  defp comment_entry?(_), do: false

  # Applies a single `:comment_ingested` WAL payload to local ETS.
  # Used by both replay (cold-boot) and replicate_entries (peer
  # writes streaming in via the bi-directional replicator). Emits
  # `CommentReceived` on the local EventBus for LiveViews
  # subscribed on peer nodes.
  #
  # The ingest-time caps are re-enforced here: WAL entries and peer
  # batches bypass `do_ingest/1`, so a poisoned WAL or an over-
  # capacity peer stream must not smuggle oversized content in or
  # grow the table past @primary_cap.
  defp apply_entry_local(%Entry{type: :comment_ingested, payload: payload}) do
    event_id = Map.fetch!(payload, :event_id)

    cond do
      oversized_content?(payload) ->
        Logger.warning("Inbox: dropping replicated comment with oversized content, event_id=#{event_id}")
        :ok

      :ets.info(@table, :size) >= @primary_cap ->
        Logger.warning("Inbox: dropping replicated comment, inbox at capacity, event_id=#{event_id}")
        :ok

      true ->
        case :ets.lookup(@table, event_id) do
          [{^event_id, _}] ->
            :ok

          [] ->
            comment = %{
              event_id: event_id,
              market_id: Map.fetch!(payload, :market_id),
              author_pubkey: Map.fetch!(payload, :author_pubkey),
              content: Map.fetch!(payload, :content),
              created_at: Map.fetch!(payload, :created_at),
              received_at_ms: Map.fetch!(payload, :received_at_ms)
            }

            :ets.insert(@table, {event_id, comment})
            update_by_market_index(comment.market_id, comment)

            EventBus.publish(%MarketsEvents.CommentReceived{
              event_id: event_id,
              market_id: comment.market_id,
              author_pubkey: comment.author_pubkey,
              content: comment.content,
              created_at: comment.created_at,
              timestamp: DateTime.utc_now()
            })

            :ok
        end
    end
  rescue
    _ -> :ok
  end

  defp oversized_content?(attrs) do
    case Map.get(attrs, :content) do
      content when is_binary(content) -> byte_size(content) > @max_content_bytes
      _ -> false
    end
  end

  defp market_exists?(market_id) do
    case MarketsStore.get_market(market_id) do
      {:ok, _market} -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # Production defaults to true. Inbox unit tests set this to false so
  # they can drive `ingest/1` with synthetic market_ids without
  # standing up a real Markets.Store fixture per case.
  defp require_market_existence? do
    Application.get_env(:perpwalk, :inbox, [])
    |> Keyword.get(:require_market_existence, true)
  end

  defp build_comment(attrs) do
    %{
      event_id: Map.fetch!(attrs, :event_id),
      market_id: Map.fetch!(attrs, :market_id),
      author_pubkey: Map.fetch!(attrs, :author_pubkey),
      content: Map.fetch!(attrs, :content),
      created_at: Map.fetch!(attrs, :created_at),
      received_at_ms: System.system_time(:millisecond)
    }
  end

  defp update_by_market_index(market_id, comment) do
    current =
      case :ets.lookup(@by_market_table, market_id) do
        [{^market_id, list}] -> list
        [] -> []
      end

    next =
      [comment | current]
      |> Enum.sort_by(& &1.created_at, :desc)
      |> Enum.take(@per_market_cap)

    :ets.insert(@by_market_table, {market_id, next})
  end

  defp sweep_primary(cutoff_ms) do
    spec = [
      {{:_, :"$1"}, [{:<, {:map_get, :received_at_ms, :"$1"}, cutoff_ms}], [true]}
    ]

    removed = :ets.select_delete(@table, spec)

    if removed > 0,
      do: Logger.info("Inbox: swept expired comments, count=#{removed}")

    removed
  end

  # After a sweep, rebuild the by_market index from the surviving
  # primary rows so we don't keep references to expired entries in
  # the secondary index. Bounded by the total cache size and runs
  # at most hourly.
  defp rebuild_by_market_from_primary do
    grouped =
      :ets.foldl(
        fn {_id, comment}, acc ->
          Map.update(acc, comment.market_id, [comment], &[comment | &1])
        end,
        %{},
        @table
      )

    :ets.delete_all_objects(@by_market_table)

    Enum.each(grouped, fn {market_id, comments} ->
      capped =
        comments
        |> Enum.sort_by(& &1.created_at, :desc)
        |> Enum.take(@per_market_cap)

      :ets.insert(@by_market_table, {market_id, capped})
    end)
  end

  defp create_tables do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

      _ ->
        @table
    end

    case :ets.whereis(@by_market_table) do
      :undefined ->
        :ets.new(@by_market_table, [:named_table, :set, :public, read_concurrency: true])

      _ ->
        @by_market_table
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
