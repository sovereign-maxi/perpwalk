defmodule PerpWalk.Federation.StoreIntegrationTest do
  @moduledoc """
  Integration tests for `Federation.Store` against the
  application-supervised store. WAL persistence is tested via
  the production Store; isolated-store fixture would mirror
  Markets's pattern but is overkill for a single-entity store.
  """

  use PerpWalk.IntegrationCase

  alias PerpWalk.Federation.{Payout, Store}
  alias PerpWalk.Markets.Position

  defp build_position(status \\ :settled_winner) do
    %Position{
      id: "pos-#{System.unique_integer([:positive])}",
      market_id: "market-#{System.unique_integer([:positive])}",
      account_id: "acct",
      side: :yes,
      contracts: 5,
      amount_paid: 50_000_000_000,
      spread_piconeros: 0,
      status: status,
      created_at: DateTime.utc_now(),
      settled_at: DateTime.utc_now()
    }
  end

  setup do
    :ok = Store.clear()
    :ok
  end

  describe "put_payout/1" do
    test "round-trips a request through the WAL + ETS" do
      req = Payout.new(build_position(), 50_000_000_000, "dest")

      assert :ok = Store.put_payout(req)
      assert {:ok, ^req} = Store.get_payout(req.id)
    end

    test "list_payouts returns every persisted request" do
      a = Payout.new(build_position(), 1_000, "dest-a")
      b = Payout.new(build_position(), 2_000, "dest-b")
      c = Payout.new(build_position(), 3_000, "dest-c")

      :ok = Store.put_payout(a)
      :ok = Store.put_payout(b)
      :ok = Store.put_payout(c)

      ids = Store.list_payouts() |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([a.id, b.id, c.id])
    end

    test "list_payouts_for_position filters by position id" do
      pos1 = build_position()
      pos2 = build_position()

      a = Payout.new(pos1, 1_000, "d")
      b = Payout.new(pos1, 2_000, "d")
      c = Payout.new(pos2, 3_000, "d")

      :ok = Store.put_payout(a)
      :ok = Store.put_payout(b)
      :ok = Store.put_payout(c)

      pos1_ids = Store.list_payouts_for_position(pos1.id) |> Enum.map(& &1.id) |> Enum.sort()

      assert pos1_ids == Enum.sort([a.id, b.id])
    end

    test "list_payouts_by_status filters by status" do
      a = Payout.new(build_position(), 1_000, "d")
      b_pending = Payout.new(build_position(), 2_000, "d")
      {:ok, b_cleared} = Payout.mark_rules_passed(b_pending)

      :ok = Store.put_payout(a)
      :ok = Store.put_payout(b_cleared)

      pending = Store.list_payouts_by_status(:pending)
      cleared = Store.list_payouts_by_status(:rules_passed)

      assert length(pending) == 1
      assert length(cleared) == 1
    end

    test "list_in_flight_payouts returns non-terminal requests" do
      in_flight = Payout.new(build_position(), 1_000, "d")
      to_fail = Payout.new(build_position(), 2_000, "d")
      {:ok, failed} = Payout.mark_failed(to_fail, "test")

      :ok = Store.put_payout(in_flight)
      :ok = Store.put_payout(failed)

      in_flight_ids = Store.list_in_flight_payouts() |> Enum.map(& &1.id)
      assert in_flight.id in in_flight_ids
      refute failed.id in in_flight_ids
    end
  end

  describe "WAL sequence numbers — apply_entries dispatch" do
    alias Locker.WAL.Entry

    setup do
      %{tables: build_apply_tables(Store.WalSeqApplyTest)}
    end

    defp build_apply_tables(namespace) do
      %{
        payouts: :ets.new(:"#{namespace}.Payouts", [:set, :public]),
        by_status: :ets.new(:"#{namespace}.ByStatus", [:bag, :public]),
        by_position: :ets.new(:"#{namespace}.ByPosition", [:bag, :public]),
        by_kind: :ets.new(:"#{namespace}.ByKind", [:bag, :public]),
        inflight_index: :ets.new(:"#{namespace}.Inflight", [:bag, :public])
      }
    end

    defp payout_payload(%Payout{} = req) do
      %{
        id: req.id,
        position_id: req.position_id,
        market_id: req.market_id,
        account_id: req.account_id,
        kind: req.kind,
        amount_piconeros: req.amount_piconeros,
        destination: req.destination,
        status: req.status,
        rule_failure_reason: req.rule_failure_reason,
        payout_txid: req.payout_txid,
        created_at: DateTime.to_iso8601(req.created_at),
        updated_at: DateTime.to_iso8601(req.updated_at)
      }
    end

    test "apply_entries reports the max seq it observed", %{tables: tables} do
      a = Payout.new(build_position(), 1_000, "d")
      b = Payout.new(build_position(), 2_000, "d")

      entries = [
        %Entry{type: :payout_requested, payload: Map.put(payout_payload(a), :seq, 9)},
        %Entry{type: :payout_requested, payload: Map.put(payout_payload(b), :seq, 10)}
      ]

      result = Store.apply_entries(entries, tables)
      assert result.applied == 2
      assert result.max_seq == 10
    end

    test "intra-type gaps do NOT emit anomalies", %{tables: tables} do
      req = Payout.new(build_position(), 1_000, "d")
      handler_id = {__MODULE__, :gap_test, System.unique_integer([:positive])}
      pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:perp_walk, :federation, :store, :wal_seq_anomaly],
          fn _event, measurements, metadata, _config ->
            send(pid, {:anomaly, measurements, metadata})
          end,
          nil
        )

      try do
        entries = [
          %Entry{type: :payout_requested, payload: Map.put(payout_payload(req), :seq, 1)},
          %Entry{type: :payout_requested, payload: Map.put(payout_payload(req), :seq, 7)}
        ]

        result = Store.apply_entries(entries, tables)
        assert result.applied == 2
        assert result.max_seq == 7

        refute_receive {:anomaly, _, _}, 100
      after
        :telemetry.detach(handler_id)
      end
    end

    test "small same-origin reorder within tolerance emits :wal_seq_anomaly :minor_reorder", %{tables: tables} do
      req = Payout.new(build_position(), 1_000, "d")
      handler_id = {__MODULE__, :reorder_test, System.unique_integer([:positive])}
      pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:perp_walk, :federation, :store, :wal_seq_anomaly],
          fn _event, measurements, metadata, _config ->
            send(pid, {:anomaly, measurements, metadata})
          end,
          nil
        )

      try do
        entries = [
          %Entry{type: :payout_requested, payload: Map.put(payout_payload(req), :seq, 5)},
          %Entry{type: :payout_requested, payload: Map.put(payout_payload(req), :seq, 3)}
        ]

        _ = Store.apply_entries(entries, tables)

        assert_receive {:anomaly, %{observed: 3, last: 5}, %{kind: :minor_reorder}},
                       100
      after
        :telemetry.detach(handler_id)
      end
    end

    test "large same-origin rewind trips the halt-on-corrupt raise", %{tables: tables} do
      req = Payout.new(build_position(), 1_000, "d")

      entries = [
        %Entry{type: :payout_requested, payload: Map.put(payout_payload(req), :seq, 100)},
        %Entry{type: :payout_requested, payload: Map.put(payout_payload(req), :seq, 10)}
      ]

      assert_raise RuntimeError, ~r/WAL reorder/, fn ->
        Store.apply_entries(entries, tables)
      end
    end

    test "entries without :seq are tolerated", %{tables: tables} do
      req = Payout.new(build_position(), 1_000, "d")

      entries = [%Entry{type: :payout_requested, payload: payout_payload(req)}]
      result = Store.apply_entries(entries, tables)

      assert result.applied == 1
      assert result.max_seq == 0
    end

    test "apply_entries populates ALL indexes atomically per entry", %{tables: tables} do
      # Regression: previously `apply_wal_entry(:payout_requested, ...)`
      # inserted into the primary table only, and the follower's
      # `handle_call({:replicate_entries, ...})` handler ran a wipe-and-
      # rebuild pass afterwards to catch by_status / by_position /
      # inflight_index up. A LiveView reading during the wipe window
      # saw an empty by_position and rendered a queued position as
      # unclaimed ("queued → claim → refresh reveals txid"). Incremental
      # per-entry updates (see `upsert_payout/2`) close the window.
      position = build_position()
      req = Payout.new(position, 5_000, "dest-idx")

      entries = [%Entry{type: :payout_requested, payload: payout_payload(req)}]
      Store.apply_entries(entries, tables)

      assert [{_id, %Payout{status: :pending}}] = :ets.lookup(tables.payouts, req.id)
      assert :ets.lookup(tables.by_status, :pending) == [{:pending, req.id}]
      assert :ets.lookup(tables.by_position, position.id) == [{position.id, req.id}]

      assert :ets.lookup(tables.inflight_index, {:position, position.id}) ==
               [{{:position, position.id}, req.id}]
    end

    test "apply_entries transitions status atomically (by_status bag is corrected)", %{tables: tables} do
      position = build_position()
      req = Payout.new(position, 1_000, "d")
      {:ok, cleared} = Payout.mark_rules_passed(req)

      pending_entry = %Entry{type: :payout_requested, payload: payout_payload(req)}
      cleared_entry = %Entry{type: :payout_requested, payload: payout_payload(cleared)}

      Store.apply_entries([pending_entry, cleared_entry], tables)

      # After the two transitions, by_status should have :rules_passed
      # only — no stale :pending row.
      assert :ets.lookup(tables.by_status, :rules_passed) == [{:rules_passed, req.id}]
      assert :ets.lookup(tables.by_status, :pending) == []
    end

    test "apply_entries removes payout from inflight_index on terminal transition", %{tables: tables} do
      position = build_position()
      req = Payout.new(position, 1_000, "d")
      {:ok, failed} = Payout.mark_failed(req, "unit-test")

      pending_entry = %Entry{type: :payout_requested, payload: payout_payload(req)}
      failed_entry = %Entry{type: :payout_requested, payload: payout_payload(failed)}

      Store.apply_entries([pending_entry, failed_entry], tables)

      # Terminal :failed → row dropped from inflight index.
      assert :ets.lookup(tables.inflight_index, {:position, position.id}) == []
    end
  end

  describe "apply_entries/3 emit_events: cross-node LiveView re-emission" do
    alias Locker.WAL.Entry
    alias PerpWalk.Events.EventBus
    alias PerpWalk.Events.Federation, as: FederationEvents

    setup do
      %{tables: build_apply_tables(Store.EmitEventsApplyTest)}
    end

    defp payout_payload_with(%Payout{} = req, overrides) do
      %{
        id: req.id,
        position_id: req.position_id,
        market_id: req.market_id,
        account_id: req.account_id,
        kind: req.kind,
        amount_piconeros: req.amount_piconeros,
        destination: req.destination,
        status: req.status,
        rule_failure_reason: req.rule_failure_reason,
        payout_txid: req.payout_txid,
        created_at: DateTime.to_iso8601(req.created_at),
        updated_at: DateTime.to_iso8601(req.updated_at)
      }
      |> Map.merge(overrides)
    end

    test "status=:pending republishes PayoutRequested", %{tables: tables} do
      req = Payout.new(build_position(), 42_000, "dest-pending")

      entry = %Entry{
        type: :payout_requested,
        payload: payout_payload_with(req, %{seq: 1})
      }

      :ok = EventBus.subscribe(FederationEvents.PayoutRequested)
      Store.apply_entries([entry], tables, emit_events: true)

      assert_receive %FederationEvents.PayoutRequested{
                       request_id: rid,
                       amount_piconeros: 42_000,
                       destination: "dest-pending"
                     },
                     500

      assert rid == req.id
    end

    test "status=:awaiting_operator republishes RuleCheckFailed", %{tables: tables} do
      req = Payout.new(build_position(), 1_000, "d")
      {:ok, awaiting} = Payout.mark_awaiting_operator(req, "destination_blocklisted")

      entry = %Entry{
        type: :payout_requested,
        payload: payout_payload_with(awaiting, %{seq: 1})
      }

      :ok = EventBus.subscribe(FederationEvents.RuleCheckFailed)
      Store.apply_entries([entry], tables, emit_events: true)

      assert_receive %FederationEvents.RuleCheckFailed{
                       request_id: rid,
                       reason: "destination_blocklisted"
                     },
                     500

      assert rid == req.id
    end

    test "status=:rules_passed with preserved reason republishes OperatorOverride", %{tables: tables} do
      req = Payout.new(build_position(), 1_000, "d")
      {:ok, awaiting} = Payout.mark_awaiting_operator(req, "temp_rule_block")
      {:ok, overridden} = Payout.mark_force_approved(awaiting)

      entry = %Entry{
        type: :payout_requested,
        payload: payout_payload_with(overridden, %{seq: 1})
      }

      :ok = EventBus.subscribe(FederationEvents.OperatorOverride)
      Store.apply_entries([entry], tables, emit_events: true)

      assert_receive %FederationEvents.OperatorOverride{
                       request_id: rid,
                       previous_reason: "temp_rule_block"
                     },
                     500

      assert rid == req.id
    end

    test "status=:rules_passed with nil reason does NOT republish OperatorOverride", %{tables: tables} do
      req = Payout.new(build_position(), 1_000, "d")
      {:ok, cleared} = Payout.mark_rules_passed(req)

      entry = %Entry{
        type: :payout_requested,
        payload: payout_payload_with(cleared, %{seq: 1})
      }

      :ok = EventBus.subscribe(FederationEvents.OperatorOverride)
      Store.apply_entries([entry], tables, emit_events: true)

      refute_receive %FederationEvents.OperatorOverride{}, 100
    end

    test "status=:paid_out republishes PayoutSubmitted with txid", %{tables: tables} do
      req = Payout.new(build_position(), 100_000, "d")
      {:ok, cleared} = Payout.mark_rules_passed(req)
      {:ok, signing} = Payout.mark_signing(cleared)
      {:ok, submitted} = Payout.mark_submitted(signing, "fed-txid-abc")
      {:ok, paid_out} = Payout.mark_paid_out(submitted)

      entry = %Entry{
        type: :payout_requested,
        payload: payout_payload_with(paid_out, %{seq: 1})
      }

      :ok = EventBus.subscribe(FederationEvents.PayoutSubmitted)
      Store.apply_entries([entry], tables, emit_events: true)

      assert_receive %FederationEvents.PayoutSubmitted{
                       request_id: rid,
                       payout_txid: "fed-txid-abc",
                       amount_piconeros: 100_000
                     },
                     500

      assert rid == req.id
    end

    test "status=:failed republishes PayoutFailed with reason", %{tables: tables} do
      req = Payout.new(build_position(), 1_000, "d")
      {:ok, failed} = Payout.mark_failed(req, "operator_abort: cleanup")

      entry = %Entry{
        type: :payout_requested,
        payload: payout_payload_with(failed, %{seq: 1})
      }

      :ok = EventBus.subscribe(FederationEvents.PayoutFailed)
      Store.apply_entries([entry], tables, emit_events: true)

      assert_receive %FederationEvents.PayoutFailed{
                       request_id: rid,
                       reason: "operator_abort: cleanup"
                     },
                     500

      assert rid == req.id
    end

    test "with emit_events: false (default) no lifecycle event is published", %{tables: tables} do
      req = Payout.new(build_position(), 1_000, "d")

      entry = %Entry{
        type: :payout_requested,
        payload: payout_payload_with(req, %{seq: 1})
      }

      :ok = EventBus.subscribe(FederationEvents.PayoutRequested)
      Store.apply_entries([entry], tables)

      refute_receive %FederationEvents.PayoutRequested{}, 100
    end

    test ":broadcast_marker_set entries do not directly emit events", %{tables: tables} do
      # The lifecycle event fires on the subsequent :payout_requested
      # entry that transitions status to :paid_out — the broadcast
      # marker is a persistence-layer artifact, not a UI transition.
      entry = %Entry{
        type: :broadcast_marker_set,
        payload: %{request_id: "req-x", payout_txid: "tx-y", seq: 1}
      }

      :ok = EventBus.subscribe(FederationEvents.PayoutSubmitted)
      Store.apply_entries([entry], tables, emit_events: true)

      refute_receive %FederationEvents.PayoutSubmitted{}, 100
    end
  end

  describe "persist_processor_promotion/4" do
    setup do
      :persistent_term.erase({PerpWalk.Federation.Store, :promotion})
      on_exit(fn -> :persistent_term.erase({PerpWalk.Federation.Store, :promotion}) end)
      :ok
    end

    test "writes to WAL AND updates persistent_term for hot-path reads" do
      now = DateTime.utc_now()
      assert :ok = Store.persist_processor_promotion([:p2], 1, :p1, now)

      assert {[:p2], 1} = Store.lookup_processor_promotion()
    end

    test "monotonic guard: stale epoch is refused" do
      now = DateTime.utc_now()
      assert :ok = Store.persist_processor_promotion([:p2], 5, :p1, now)

      # Same epoch refused.
      assert {:error, :stale_epoch} = Store.persist_processor_promotion([:p3], 5, :p1, now)

      # Lower epoch refused.
      assert {:error, :stale_epoch} = Store.persist_processor_promotion([:p3], 3, :p1, now)

      # Higher epoch accepted.
      assert :ok = Store.persist_processor_promotion([:p3], 6, :p1, now)
      assert {[:p3], 6} = Store.lookup_processor_promotion()
    end

    test "WAL replay advances persistent_term through apply_wal_entry" do
      # The replay path is the follower's read: apply the entry via
      # apply_entries (the same path Storage.Replicator invokes) and
      # verify persistent_term reflects the promotion. This is the
      # invariant that keeps followers converged on the leader's set
      # without needing the write to originate locally.
      alias Locker.WAL.Entry
      alias PerpWalk.Federation.Store, as: FS

      tables = %{
        payouts: :ets.new(:t_p, [:set]),
        by_status: :ets.new(:t_s, [:bag]),
        by_position: :ets.new(:t_pos, [:bag]),
        by_kind: :ets.new(:t_k, [:bag]),
        inflight_index: :ets.new(:t_i, [:bag])
      }

      entry = %Entry{
        type: :processor_promotion,
        payload: %{
          set: [:p3],
          epoch: 42,
          source: :p1,
          at: DateTime.utc_now(),
          seq: 1
        }
      }

      FS.apply_entries([entry], tables)

      assert {[:p3], 42} = Store.lookup_processor_promotion()
    end
  end
end
