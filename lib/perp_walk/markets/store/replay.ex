defmodule PerpWalk.Markets.Store.Replay do
  @moduledoc """
  WAL replay + per-type seq tracking for the Markets domain Store.

  Drives two paths against the same logic:

  - Cold boot — `Store.init/1` calls `replay_wal/2` after creating
    the ETS tables, which reads every entry via
    `Locker.WAL.read_all/1` and dispatches through `apply_entries/2`.
  - Follower replication — `Store.handle_call({:replicate_entries,
    ...}, _, _)` calls `apply_entries/2` directly with the batch
    handed up from `Storage.Replicator`.

  ## Sequence monotonicity

  Each entry's `:seq` is tracked per-type. The expected invariant
  is "per-type seqs are strictly increasing in WAL order, with
  gaps allowed for interleaved other-type writes" — NOT strict
  global `last + 1`. The Markets.Store atomic seq counter is
  global, but WAL-append order does not match seq-allocation order
  because direct-path writes (`:vote_put`, `:dispute_put`,
  `:quote_put`, `:quote_expired`) race against the GenServer's
  serial handlers.

  Per-type duplicates (`seq == last`) are silent — they're the
  legitimate result of a peer retrying a partially-appended batch
  through the Replicator. Strict reorder (`seq < last`) is the
  real anomaly and trips `:wal_seq_anomaly` telemetry plus
  halt-on-corrupt in production.
  """

  require Logger

  alias Locker.WAL.Entry
  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.Store.{Inserts, Serialize}

  @wal_types [
    :market_put,
    :vote_put,
    :trade_executed,
    :market_resolved,
    :quote_put,
    :quote_filled,
    :quote_expired,
    :position_paid_out,
    :dispute_put
  ]

  @doc """
  Reads the WAL via `Locker.WAL.read_all/1` and dispatches every
  entry through `apply_entries/2`. Used by `Store.init/1`.

  Raises on `{:error, _}` from the WAL read so the supervisor
  restart loop surfaces a substantive failure rather than booting
  with empty ETS plus `max_seq = 0` (which would silently restart
  the seq counter at 1 while the on-disk WAL holds entries past
  some higher N).

  Returns `%{applied: 0, skipped: 0, max_seq: 0}` for the
  `:unavailable` branch — that's the WAL GenServer briefly not up
  during supervisor start, which is recoverable.
  """
  @spec replay_wal(GenServer.server(), map()) :: %{
          applied: non_neg_integer(),
          skipped: non_neg_integer(),
          max_seq: non_neg_integer()
        }
  def replay_wal(wal_server, tables) do
    case safe_read_all(wal_server) do
      {:ok, entries} ->
        apply_entries(entries, tables)

      {:error, reason} ->
        raise "Markets.Store: WAL replay failed, reason=#{inspect(reason)}. " <>
                "Refusing to boot with empty state — investigate WAL directory " <>
                "and segment files before restart."

      :unavailable ->
        Logger.warning("Replay: skipped, reason=wal_unavailable")
        %{applied: 0, skipped: 0, max_seq: 0}
    end
  end

  defp safe_read_all(wal_server) do
    Locker.WAL.read_all_strict(wal_server)
  catch
    :exit, _ -> :unavailable
  end

  @doc """
  Applies a list of WAL entries to the given ETS table set,
  returning `%{applied: n, skipped: n, max_seq: n}`. Public so
  tests can drive the dispatch logic with hand-crafted entries
  (including `{:__corrupted__, _}` payloads to verify that one
  bad entry doesn't abort the rest of the replay).

  Walks entries in WAL order tracking the per-type seq watermark.
  Per-type strict reorders emit a `:wal_seq_anomaly` telemetry
  event (and raise in production via `halt_on_corrupt?/0`) but
  duplicates are silent — see the moduledoc for rationale.
  Entries without a `:seq` field are applied without seq tracking.
  """
  @spec apply_entries([Entry.t()], map()) :: %{
          applied: non_neg_integer(),
          skipped: non_neg_integer(),
          max_seq: non_neg_integer()
        }
  def apply_entries(entries, tables), do: apply_entries(entries, tables, [])

  @doc """
  Same as `apply_entries/2` but accepts an options keyword list.

  ## Options

  - `:emit_events` (default `false`) — when true, publishes the local
    `PerpWalk.Events.*` event that corresponds to each successfully
    applied WAL entry. Set by `Store.handle_call({:replicate_entries,
    ...})` so a follower node's LiveViews receive UI events for
    cluster-writes originated on the designated processor. Cold-boot
    replay leaves this off; no LiveView is subscribed yet, and even
    if one were, historical entries should not fire user-visible
    notifications.

  ## Which events are re-emitted

  Only events that a public LiveView actually subscribes to and that
  originate from designated-processor-only paths (i.e. would otherwise
  never reach a follower's `Phoenix.PubSub.local_broadcast` topic).
  See `maybe_emit_event/2` for the current set. Add more here as new
  cluster-write events start driving UI transitions.
  """
  @reorder_tolerance 32

  @spec apply_entries([Entry.t()], map(), keyword()) :: %{
          applied: non_neg_integer(),
          skipped: non_neg_integer(),
          max_seq: non_neg_integer()
        }
  def apply_entries(entries, tables, opts) do
    emit_events? = Keyword.get(opts, :emit_events, false)
    relevant = Enum.filter(entries, &relevant?/1)

    {applied, skipped, max_seq, _last_per_key} =
      Enum.reduce(relevant, {0, 0, 0, %{}}, fn entry, {a, s, ms, last_per_key} ->
        if boot_gate_halt?(entry) do
          {a, s + 1, ms, last_per_key}
        else
          apply_one_entry(entry, tables, emit_events?, {a, s, ms, last_per_key})
        end
      end)

    if skipped > 0 do
      Logger.warning("Replay: applied=#{applied}, skipped=#{skipped}")
    else
      Logger.debug("Replay: applied=#{applied}")
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
        # Duplicate re-applies (retried batches) must not re-emit
        # follower UI events — only fresh seqs do.
        if emit_events? and fresh?, do: maybe_emit_event(entry)
        {a + 1, s, max_with_nil(ms, seq), new_last_per_key}

      :skip ->
        {a, s + 1, ms, new_last_per_key}
    end
  end

  # Boot-time authenticity gate (also inert-pass on the replication
  # path, where the Replicator already verified the batch). Records a
  # sticky source halt on forged/unsigned entries in enforced mode;
  # raises in production so a tampered WAL never boots into service.
  defp boot_gate_halt?(entry) do
    if PerpWalk.Storage.WAL.Replay.halt_entry?(entry, :markets) do
      if halt_on_corrupt?() do
        raise "Markets.Store: boot replay refused entry, type=#{inspect(entry.type)} — " <>
                "signature/origin invalid for the current signing mode. " <>
                "Investigate the WAL before forcing skip via :perpwalk, :wal, halt_on_corrupt: false."
      else
        Logger.warning("Replay: skipping entry with invalid signature/origin, type=#{inspect(entry.type)}")
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
  # a follower applies a replicated entry that would normally drive a
  # UI transition, re-publish the corresponding event locally so the
  # follower's LiveViews receive it the same way they would on the
  # originating node.
  defp maybe_emit_event(%Entry{
         type: :quote_filled,
         payload: %{position: p, quote_id: quote_id} = payload
       })
       when is_map(p) and is_binary(quote_id) do
    EventBus.publish(%MarketsEvents.QuoteFilled{
      quote_id: quote_id,
      position_id: Map.get(p, :id),
      market_id: Map.get(p, :market_id),
      account_id: Map.get(p, :account_id),
      side: Map.get(p, :side),
      contracts: Map.get(p, :contracts),
      amount_paid_piconeros: Map.get(p, :amount_paid),
      deposit_txid: Map.get(payload, :deposit_txid),
      timestamp: DateTime.utc_now()
    })

    :ok
  end

  defp maybe_emit_event(_entry), do: :ok

  # --- Internal ---

  defp entry_seq(%Entry{payload: %{seq: seq}}) when is_integer(seq) and seq >= 0, do: seq
  defp entry_seq(_), do: nil

  defp max_with_nil(current, nil), do: current
  defp max_with_nil(current, seq) when is_integer(seq), do: max(current, seq)

  # First entry for a given (origin, type): nothing to compare against.
  defp check_seq_monotonic(_seq, nil, _key), do: :ok

  # Strictly increasing within an (origin, type) — gaps are normal
  # because other types and origins take seqs in between.
  defp check_seq_monotonic(seq, last, _key) when seq > last, do: :ok

  # Same seq as the previous entry of this (origin, type): an idempotent retry
  # of an entry that was already applied. The replicator's append
  # path is not guaranteed atomic with cursor advance, so a failed
  # mid-batch append followed by a retry can leave duplicate entries
  # in the local WAL. The peer's `(origin, seq)` is unchanged, so
  # re-applying the same payload is safe (ETS upsert is idempotent
  # for the WAL types we replay). Silent here so cold-boot replay
  # over a retry-fattened WAL doesn't page the operator.
  defp check_seq_monotonic(seq, last, _key) when seq == last, do: :ok

  # Small backward step within one (origin, type): the direct-write
  # path allocates the seq and THEN appends, so a scheduler interleave
  # between two concurrent writers can land [N+1, N] with no tampering
  # involved. Tolerate a bounded rewind — warn + telemetry so chronic
  # interleave stays visible — and only treat a LARGER rewind as
  # corruption.
  defp check_seq_monotonic(seq, last, key) when last - seq <= @reorder_tolerance do
    :telemetry.execute(
      [:perp_walk, :markets, :store, :wal_seq_anomaly],
      %{observed: seq, last: last},
      %{key: inspect(key), kind: :minor_reorder}
    )

    Logger.warning("Replay: minor seq reorder tolerated, key=#{inspect(key)}, last=#{last}, observed=#{seq}")
    :ok
  end

  # Large rewind within one (origin, type) is a genuine anomaly — the
  # WAL has been rewound, tampered with, or replayed incorrectly. Halt
  # by default in production; warn in non-production environments.
  defp check_seq_monotonic(seq, last, key) do
    :telemetry.execute(
      [:perp_walk, :markets, :store, :wal_seq_anomaly],
      %{observed: seq, last: last},
      %{key: inspect(key), kind: :reorder}
    )

    if halt_on_corrupt?() do
      raise "Markets.Store: refusing to continue — WAL reorder on key=#{inspect(key)} " <>
              "(last=#{last}, observed=#{seq}). Disable via " <>
              ":perpwalk, :wal, halt_on_corrupt: false."
    else
      Logger.warning("Replay: wal seq anomaly, key=#{inspect(key)}, last=#{last}, observed=#{seq}, kind=reorder")
    end

    :ok
  end

  defp relevant?(%Entry{type: type}) when type in @wal_types, do: true
  defp relevant?(_), do: false

  # Locker.WAL surfaces an undecodable payload as a
  # `{:__corrupted__, raw_bytes}` tuple. By default we halt: a
  # corrupt entry could indicate either a tampered replication
  # transport (entry arrived from a peer) or local disk corruption
  # (entry was written here) — both warrant operator attention
  # before the system continues with divergent state. Set
  # `:perpwalk, :wal, halt_on_corrupt: false` for development
  # workflows that boot against intentionally damaged WAL fixtures.
  defp apply_wal_entry(%Entry{payload: {:__corrupted__, _}} = e, _tables) do
    if halt_on_corrupt?() do
      raise "Markets.Store: refusing to continue — corrupt WAL entry of type #{inspect(e.type)}. " <>
              "Investigate before forcing skip via :perpwalk, :wal, halt_on_corrupt: false."
    else
      Logger.warning("Replay: skipping corrupt wal entry, type=#{inspect(e.type)}")
      :skip
    end
  end

  defp apply_wal_entry(%Entry{type: :market_put, payload: payload}, tables)
       when is_map(payload) do
    Inserts.insert_market(tables, Serialize.to_market(payload))
    :ok
  end

  defp apply_wal_entry(%Entry{type: :vote_put, payload: payload}, tables)
       when is_map(payload) do
    Inserts.insert_vote(tables, Serialize.to_vote(payload))
    :ok
  end

  defp apply_wal_entry(%Entry{type: :dispute_put, payload: payload}, tables)
       when is_map(payload) do
    Inserts.insert_dispute(tables, Serialize.to_dispute(payload))
    :ok
  end

  defp apply_wal_entry(
         %Entry{type: :trade_executed, payload: %{market: m, position: p}},
         tables
       )
       when is_map(m) and is_map(p) do
    Inserts.insert_market(tables, Serialize.to_market(m))
    Inserts.insert_position(tables, Serialize.to_position(p))
    :ok
  end

  defp apply_wal_entry(
         %Entry{type: :market_resolved, payload: %{market: m, positions: ps} = payload},
         tables
       )
       when is_map(m) and is_list(ps) do
    market = Serialize.to_market(m)
    positions = Enum.map(ps, &Serialize.to_position/1)

    prior_market_status = Inserts.lookup_market_status(tables, market.id)
    Inserts.insert_market(tables, market)
    Enum.each(positions, fn p -> Inserts.insert_position(tables, p) end)

    # Disputes were added to the :market_resolved payload to make
    # void-from-:resolving atomic across market + positions + disputes.
    # Older WAL entries don't carry the key; default to empty list.
    Enum.each(Map.get(payload, :disputes, []), fn d_map when is_map(d_map) ->
      Inserts.insert_dispute(tables, Serialize.to_dispute(d_map))
    end)

    # Spread accumulation has to fire here too — the live write path
    # increments the counter inside `do_put_resolution` because the
    # positions list is only in scope at that call. Without this,
    # cold-boot leaves `spread_total_piconeros` at zero until the
    # next live settle or reconcile, and the operator dashboard
    # under-reports federation revenue in the interim. Same
    # `prior_status != :settled` gate as the live path so re-apply
    # is idempotent.
    if prior_market_status != :settled and market.status == :settled do
      spread = Enum.reduce(positions, 0, fn p, acc -> acc + (p.spread_piconeros || 0) end)

      if spread > 0 do
        :ets.update_counter(
          tables.ledger_counters,
          :spread_total_piconeros,
          spread,
          {:spread_total_piconeros, 0}
        )
      end
    end

    :ok
  end

  defp apply_wal_entry(%Entry{type: :quote_put, payload: payload}, tables)
       when is_map(payload) do
    Inserts.insert_quote(tables, Serialize.to_quote(payload))
    :ok
  end

  defp apply_wal_entry(
         %Entry{type: :quote_expired, payload: %{quote_id: quote_id}},
         tables
       )
       when is_binary(quote_id) do
    Inserts.delete_quote(tables, quote_id)
    :ok
  end

  defp apply_wal_entry(
         %Entry{
           type: :quote_filled,
           payload: %{market: m, position: p, quote_id: quote_id}
         },
         tables
       )
       when is_map(m) and is_map(p) and is_binary(quote_id) do
    Inserts.insert_market(tables, Serialize.to_market(m))
    Inserts.insert_position(tables, Serialize.to_position(p))
    Inserts.delete_quote(tables, quote_id)
    :ok
  end

  defp apply_wal_entry(%Entry{type: :position_paid_out, payload: payload}, tables)
       when is_map(payload) do
    Inserts.insert_position(tables, Serialize.to_position(payload))
    :ok
  end

  # A recognized type (`relevant?/1`) that nonetheless doesn't match
  # any typed clause means the payload shape diverges from what this
  # code expects: a schema-evolution bug, or a forged batch from a
  # compromised peer. Silently skipping would let this node's ETS
  # diverge from its peers'; halting matches the corrupt-binary
  # posture above.
  defp apply_wal_entry(%Entry{type: type} = entry, _tables) do
    if halt_on_corrupt?() do
      raise "Markets.Store: refusing to continue — WAL entry of type #{inspect(type)} " <>
              "has unexpected payload shape. Investigate before forcing skip via " <>
              ":perpwalk, :wal, halt_on_corrupt: false. entry=#{inspect(entry, limit: 50)}"
    else
      Logger.warning("Replay: skipping unrecognised payload shape, type=#{inspect(type)}")

      :skip
    end
  end

  defp halt_on_corrupt? do
    Application.get_env(:perpwalk, :wal, [])
    |> Keyword.get(:halt_on_corrupt, true)
  end
end
