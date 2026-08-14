defmodule PerpWalk.Markets.StoreIntegrationTest do
  @moduledoc "Integration tests for PerpWalk.Markets.Store — GenServer, ETS, WAL replay."

  use PerpWalk.IntegrationCase

  alias Locker.WAL.Entry
  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.{AMM, Market, Position, Store}
  alias PerpWalk.Markets.Store.Serialize
  alias PerpWalk.TestHelpers.MarketsHelpers

  setup do
    # Isolated store per test so ETS ownership + WAL isolation are
    # scoped to the test process — the app-supervised store stays
    # untouched by these direct read/write assertions.
    MarketsHelpers.start_isolated_store()
  end

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  describe "put_market/2 and read API" do
    test "round-trips a market through ETS", %{store: store, tables: tables} do
      market = MarketsHelpers.build_market()
      assert :ok = Store.put_market(store, market)
      assert {:ok, ^market} = lookup(tables.markets, market.id)
    end

    test "list_markets returns all stored markets", %{store: store, tables: tables} do
      m1 = MarketsHelpers.build_market(category: :politics)
      m2 = MarketsHelpers.build_market(category: :crypto)
      m3 = MarketsHelpers.build_market(category: :sports)

      :ok = Store.put_market(store, m1)
      :ok = Store.put_market(store, m2)
      :ok = Store.put_market(store, m3)

      ids =
        :ets.foldl(fn {_id, m}, acc -> [m.id | acc] end, [], tables.markets)
        |> Enum.sort()

      assert ids == Enum.sort([m1.id, m2.id, m3.id])
    end

    test "put_market overwrites a prior version", %{store: store, tables: tables} do
      market = MarketsHelpers.build_market()
      :ok = Store.put_market(store, market)
      {:ok, active} = Market.activate(market)
      :ok = Store.put_market(store, active)

      {:ok, stored} = lookup(tables.markets, market.id)
      assert stored.status == :active
    end
  end

  describe "put_vote/2 and read API" do
    test "round-trips a vote through ETS", %{store: store, tables: tables} do
      vote = MarketsHelpers.build_vote("acct-a", "mkt-1", :up)
      assert :ok = Store.put_vote(store, vote)
      assert {:ok, ^vote} = lookup(tables.votes, {"acct-a", "mkt-1"})
    end

    test "second vote from same account on same market overwrites", %{
      store: store,
      tables: tables
    } do
      v1 = MarketsHelpers.build_vote("acct-a", "mkt-1", :up)
      v2 = MarketsHelpers.build_vote("acct-a", "mkt-1", :down)

      :ok = Store.put_vote(store, v1)
      :ok = Store.put_vote(store, v2)

      {:ok, stored} = lookup(tables.votes, {"acct-a", "mkt-1"})
      assert stored.direction == :down

      keys = :ets.foldl(fn {key, _v}, acc -> [key | acc] end, [], tables.votes)
      assert keys == [{"acct-a", "mkt-1"}]
    end
  end

  describe "put_trade/3 — atomic market + position" do
    test "writes both into ETS and replays them together", %{
      store: store,
      wal: wal,
      tables: tables
    } do
      market = MarketsHelpers.build_market()
      position = Position.new(market.id, "acct-a", :yes, 10, 100_000)

      # CAS gate on put_trade requires the market to already
      # exist in the store. Seed first (production trade flows go
      # create_market → put_market → many put_trade).
      :ok = Store.put_market(store, market)

      assert :ok = Store.put_trade(store, market, position, %{pool: market.pool, status: market.status})

      {:ok, m} = lookup(tables.markets, market.id)
      {:ok, p} = lookup(tables.positions, position.id)
      assert m.id == market.id
      assert p.id == position.id

      Locker.WAL.checkpoint(wal)
      MarketsHelpers.restart_store(%{store: store, wal: wal, tables: tables})

      assert {:ok, replayed_market} = lookup(tables.markets, market.id)
      assert {:ok, replayed_position} = lookup(tables.positions, position.id)
      assert replayed_market.id == market.id
      assert replayed_position.id == position.id
    end
  end

  describe "put_resolution/3 — atomic market + every position" do
    test "writes market and all positions in one append, replays together", %{
      store: store,
      wal: wal,
      tables: tables
    } do
      market = MarketsHelpers.build_market()

      positions =
        for i <- 1..3 do
          Position.new(market.id, "acct-#{i}", :yes, 5, 50_000)
        end

      assert :ok = Store.put_resolution(store, market, positions)

      assert {:ok, _} = lookup(tables.markets, market.id)

      for p <- positions do
        assert {:ok, _} = lookup(tables.positions, p.id)
      end

      Locker.WAL.checkpoint(wal)
      MarketsHelpers.restart_store(%{store: store, wal: wal, tables: tables})

      assert {:ok, replayed_market} = lookup(tables.markets, market.id)
      assert replayed_market.id == market.id

      for p <- positions do
        assert {:ok, replayed} = lookup(tables.positions, p.id)
        assert replayed.id == p.id
      end
    end

    test "empty position list is valid (market with no participants)", %{
      store: store,
      tables: tables
    } do
      market = MarketsHelpers.build_market()
      assert :ok = Store.put_resolution(store, market, [])
      assert {:ok, _} = lookup(tables.markets, market.id)
      assert :ets.tab2list(tables.positions) == []
    end
  end

  describe "WAL replay" do
    test "rebuilds ETS state on Store restart", ctx do
      market = MarketsHelpers.build_market()
      position = Position.new(market.id, "acct-a", :yes, 10, 5_000)
      vote = MarketsHelpers.build_vote("acct-a", market.id, :up)

      :ok = Store.put_market(ctx.store, market)
      :ok = Store.put_trade(ctx.store, market, position, %{pool: market.pool, status: market.status})
      :ok = Store.put_vote(ctx.store, vote)

      Locker.WAL.checkpoint(ctx.wal)

      MarketsHelpers.restart_store(ctx)

      assert {:ok, replayed_market} = lookup(ctx.tables.markets, market.id)
      assert replayed_market.id == market.id
      assert replayed_market.description == market.description
      assert replayed_market.pool.yes == market.pool.yes
      assert replayed_market.pool.no == market.pool.no

      assert {:ok, replayed_position} = lookup(ctx.tables.positions, position.id)
      assert replayed_position.id == position.id
      assert replayed_position.contracts == position.contracts

      assert {:ok, replayed_vote} =
               lookup(ctx.tables.votes, {vote.account_id, vote.market_id})

      assert replayed_vote.direction == :up
    end

    test "replay applies last write per key", ctx do
      market = MarketsHelpers.build_market()
      :ok = Store.put_market(ctx.store, market)
      {:ok, active} = Market.activate(market)
      :ok = Store.put_market(ctx.store, active)

      Locker.WAL.checkpoint(ctx.wal)

      MarketsHelpers.restart_store(ctx)

      {:ok, stored} = lookup(ctx.tables.markets, market.id)
      assert stored.status == :active
    end
  end

  describe "apply_entries/2 — corruption resilience" do
    setup do
      # Tables are owned by the test process — they die with it, no
      # explicit on_exit cleanup required. Names follow the
      # module-path convention with a per-describe suffix.
      ns = Store.ApplyEntriesTest
      tables = build_apply_tables(ns)
      %{apply_tables: tables}
    end

    test "raises on a corrupt WAL entry when halt_on_corrupt is true", %{apply_tables: tables} do
      previous = Application.get_env(:perpwalk, :wal, [])
      Application.put_env(:perpwalk, :wal, Keyword.put(previous, :halt_on_corrupt, true))
      on_exit(fn -> Application.put_env(:perpwalk, :wal, previous) end)

      assert_raise RuntimeError, ~r/refusing to continue — corrupt WAL entry/, fn ->
        Store.apply_entries(
          [%Entry{type: :market_put, payload: {:__corrupted__, <<1, 2, 3>>}}],
          tables
        )
      end
    end

    test "with halt_on_corrupt: false — skips corrupt entries and continues with valid ones",
         %{apply_tables: tables} do
      previous = Application.get_env(:perpwalk, :wal, [])
      Application.put_env(:perpwalk, :wal, Keyword.put(previous, :halt_on_corrupt, false))
      on_exit(fn -> Application.put_env(:perpwalk, :wal, previous) end)

      market = MarketsHelpers.build_market()

      market_payload = %{
        id: market.id,
        description: market.description,
        resolution_criterion: market.resolution_criterion,
        category: market.category,
        unit_size: market.unit_size,
        expiry: DateTime.to_iso8601(market.expiry),
        resolution_deadline: DateTime.to_iso8601(market.resolution_deadline),
        status: market.status,
        pool: %{yes: market.pool.yes, no: market.pool.no},
        creator_account_id: market.creator_account_id,
        deposit_amount: market.deposit_amount,
        deposit_subaddress: market.deposit_subaddress,
        deposit_subaddress_index: market.deposit_subaddress_index,
        deposit_confirmed_at: nil,
        reputation: market.reputation,
        disputes_acknowledged_count: market.disputes_acknowledged_count,
        created_at: DateTime.to_iso8601(market.created_at),
        resolved_at: nil,
        outcome: nil
      }

      vote_payload = %{
        account_id: "acct-a",
        market_id: market.id,
        direction: :up,
        created_at: DateTime.to_iso8601(DateTime.utc_now())
      }

      entries = [
        %Entry{type: :market_put, payload: market_payload},
        %Entry{type: :market_put, payload: {:__corrupted__, <<1, 2, 3>>}},
        %Entry{type: :trade_executed, payload: {:__corrupted__, <<4, 5>>}},
        %Entry{type: :vote_put, payload: vote_payload},
        %Entry{type: :unknown_type_for_test, payload: %{}}
      ]

      result = Store.apply_entries(entries, tables)

      assert result.applied == 2
      assert result.skipped == 2

      assert [{_id, %Market{} = m}] = :ets.tab2list(tables.markets)
      assert m.id == market.id

      assert :ets.tab2list(tables.positions) == []

      assert [{{"acct-a", _}, _vote}] = :ets.tab2list(tables.votes)
    end

    test "an empty list returns zeroed counts", %{apply_tables: tables} do
      assert Store.apply_entries([], tables) == %{applied: 0, skipped: 0, max_seq: 0}
    end

    test "non-Markets event types are silently skipped", %{apply_tables: tables} do
      entries = [
        %Entry{type: :checkpoint, payload: %{x: 1}},
        %Entry{type: :something_else, payload: %{y: 2}}
      ]

      assert Store.apply_entries(entries, tables) == %{applied: 0, skipped: 0, max_seq: 0}
      assert :ets.tab2list(tables.markets) == []
    end
  end

  describe "WAL sequence numbers" do
    test "consecutive writes carry strictly increasing seq stamps", %{
      store: store,
      wal: wal
    } do
      m1 = MarketsHelpers.build_market()
      m2 = MarketsHelpers.build_market()
      v = MarketsHelpers.build_vote("acct-a", m1.id, :up)

      :ok = Store.put_market(store, m1)
      :ok = Store.put_market(store, m2)
      :ok = Store.put_vote(store, v)

      {:ok, entries} = Locker.WAL.read_all(wal)
      seqs = Enum.map(entries, & &1.payload.seq)

      # Three writes ⇒ three monotonic seqs starting at 1
      assert seqs == [1, 2, 3]
    end

    test "compound writes (put_trade) get one seq per WAL entry", %{
      store: store,
      wal: wal
    } do
      market = MarketsHelpers.build_market()
      position = Position.new(market.id, "acct-a", :yes, 10, 100_000)

      :ok = Store.put_market(store, market)
      :ok = Store.put_trade(store, market, position, %{pool: market.pool, status: market.status})

      {:ok, entries} = Locker.WAL.read_all(wal)
      trade = Enum.find(entries, fn e -> e.type == :trade_executed end)
      # put_market (seq 1) precedes put_trade (seq 2).
      assert trade.payload.seq == 2
      # The compound payload still carries its sub-bodies.
      assert is_map(trade.payload.market)
      assert is_map(trade.payload.position)
    end

    test "next_seq survives a Store restart and continues from WAL high-water mark", ctx do
      m1 = MarketsHelpers.build_market()
      m2 = MarketsHelpers.build_market()
      :ok = Store.put_market(ctx.store, m1)
      :ok = Store.put_market(ctx.store, m2)

      MarketsHelpers.restart_store(ctx)

      m3 = MarketsHelpers.build_market()
      :ok = Store.put_market(ctx.store, m3)

      {:ok, entries} = Locker.WAL.read_all(ctx.wal)
      seqs = Enum.map(entries, & &1.payload.seq)
      assert seqs == [1, 2, 3]
    end
  end

  describe "secondary indexes (positions_by_market, votes_by_market)" do
    # These tests verify the bag indexes are populated correctly by
    # the isolated Store. The public `Store.list_*_for_market/1`
    # read API is exercised end-to-end by Facade integration tests
    # against the supervised store.

    test "positions_by_market mirrors put_trade writes", %{store: store, tables: tables} do
      m1 = MarketsHelpers.build_market()
      m2 = MarketsHelpers.build_market()
      :ok = Store.put_market(store, m1)
      :ok = Store.put_market(store, m2)

      p1a = Position.new(m1.id, "acct-a", :yes, 10, 1_000)
      p1b = Position.new(m1.id, "acct-b", :no, 5, 500)
      p2a = Position.new(m2.id, "acct-a", :yes, 7, 700)

      :ok = Store.put_trade(store, m1, p1a, %{pool: m1.pool, status: m1.status})
      :ok = Store.put_trade(store, m1, p1b, %{pool: m1.pool, status: m1.status})
      :ok = Store.put_trade(store, m2, p2a, %{pool: m2.pool, status: m2.status})

      ids_for_m1 =
        :ets.lookup(tables.positions_by_market, m1.id)
        |> Enum.map(fn {_mid, pid} -> pid end)
        |> Enum.sort()

      ids_for_m2 =
        :ets.lookup(tables.positions_by_market, m2.id)
        |> Enum.map(fn {_mid, pid} -> pid end)

      assert ids_for_m1 == Enum.sort([p1a.id, p1b.id])
      assert ids_for_m2 == [p2a.id]
      assert :ets.tab2list(tables.positions_by_market) |> length() == 3
    end

    test "votes_by_market mirrors put_vote writes", %{store: store, tables: tables} do
      m1_id = "mkt-1"
      m2_id = "mkt-2"

      v1a = MarketsHelpers.build_vote("acct-a", m1_id, :up)
      v1b = MarketsHelpers.build_vote("acct-b", m1_id, :down)
      v2a = MarketsHelpers.build_vote("acct-a", m2_id, :up)

      :ok = Store.put_vote(store, v1a)
      :ok = Store.put_vote(store, v1b)
      :ok = Store.put_vote(store, v2a)

      keys_for_m1 =
        :ets.lookup(tables.votes_by_market, m1_id)
        |> Enum.map(fn {_mid, key} -> key end)
        |> Enum.sort()

      assert keys_for_m1 == Enum.sort([{"acct-a", m1_id}, {"acct-b", m1_id}])
      assert :ets.tab2list(tables.votes_by_market) |> length() == 3
    end

    test "vote overwrite is idempotent in the index", %{store: store, tables: tables} do
      v1 = MarketsHelpers.build_vote("acct-a", "mkt-1", :up)
      v2 = MarketsHelpers.build_vote("acct-a", "mkt-1", :down)

      :ok = Store.put_vote(store, v1)
      :ok = Store.put_vote(store, v2)

      assert :ets.tab2list(tables.votes) |> length() == 1
      assert :ets.tab2list(tables.votes_by_market) |> length() == 1
    end

    test "indexes survive a Store restart and are rebuilt from WAL", ctx do
      market = MarketsHelpers.build_market()
      pa = Position.new(market.id, "acct-a", :yes, 10, 1_000)
      pb = Position.new(market.id, "acct-b", :no, 5, 500)
      v = MarketsHelpers.build_vote("acct-a", market.id, :up)

      :ok = Store.put_market(ctx.store, market)
      :ok = Store.put_trade(ctx.store, market, pa, %{pool: market.pool, status: market.status})
      :ok = Store.put_trade(ctx.store, market, pb, %{pool: market.pool, status: market.status})
      :ok = Store.put_vote(ctx.store, v)

      MarketsHelpers.restart_store(ctx)

      ids =
        :ets.lookup(ctx.tables.positions_by_market, market.id)
        |> Enum.map(fn {_mid, pid} -> pid end)
        |> Enum.sort()

      assert ids == Enum.sort([pa.id, pb.id])

      vote_keys =
        :ets.lookup(ctx.tables.votes_by_market, market.id)
        |> Enum.map(fn {_mid, key} -> key end)

      assert vote_keys == [{"acct-a", market.id}]
    end

    test "compound writes (put_resolution, put_fill, put_payout) also index", %{
      store: store,
      tables: tables
    } do
      market = MarketsHelpers.build_market()
      :ok = Store.put_market(store, market)

      pa = Position.new(market.id, "acct-a", :yes, 5, 500)

      # First write goes through put_trade
      :ok = Store.put_trade(store, market, pa, %{pool: market.pool, status: market.status})

      # put_resolution: re-inserts existing position; index still has one entry
      :ok = Store.put_resolution(store, market, [pa])

      assert :ets.tab2list(tables.positions_by_market) |> length() == 1

      # put_payout: again, idempotent in the index
      :ok = Store.put_payout(store, pa)
      assert :ets.tab2list(tables.positions_by_market) |> length() == 1
    end
  end

  describe "WAL sequence numbers — apply_entries dispatch" do
    setup do
      ns = Store.WalSeqApplyTest
      tables = build_apply_tables(ns)

      %{apply_tables: tables}
    end

    test "apply_entries reports the max seq it observed", %{apply_tables: tables} do
      market = MarketsHelpers.build_market()
      vote = MarketsHelpers.build_vote("acct-a", market.id, :up)

      entries = [
        %Entry{type: :market_put, payload: Map.put(market_payload(market), :seq, 7)},
        %Entry{type: :vote_put, payload: Map.put(vote_payload(vote), :seq, 8)}
      ]

      result = Store.apply_entries(entries, tables)
      assert result.applied == 2
      assert result.max_seq == 8
    end

    test "intra-type gaps do NOT emit anomalies (interleaved direct-path writers eat seqs)", %{
      apply_tables: tables
    } do
      market = MarketsHelpers.build_market()
      handler_id = {__MODULE__, :gap_test, System.unique_integer([:positive])}
      pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:perp_walk, :markets, :store, :wal_seq_anomaly],
          fn _event, measurements, metadata, _config ->
            send(pid, {:anomaly, measurements, metadata})
          end,
          nil
        )

      try do
        entries = [
          %Entry{type: :market_put, payload: Map.put(market_payload(market), :seq, 1)},
          # Skip from 1 to 5 — gap of 3. Other types (vote_put,
          # dispute_put) took seqs 2/3/4. Strictly increasing per
          # type is the invariant; gaps are normal.
          %Entry{type: :market_put, payload: Map.put(market_payload(market), :seq, 5)}
        ]

        result = Store.apply_entries(entries, tables)
        assert result.applied == 2
        assert result.max_seq == 5

        refute_receive {:anomaly, _, _}, 100
      after
        :telemetry.detach(handler_id)
      end
    end

    test "minor same-origin reorder is tolerated with telemetry; large rewind raises", %{
      apply_tables: tables
    } do
      previous = Application.get_env(:perpwalk, :wal, [])
      Application.put_env(:perpwalk, :wal, Keyword.put(previous, :halt_on_corrupt, false))
      on_exit(fn -> Application.put_env(:perpwalk, :wal, previous) end)

      market = MarketsHelpers.build_market()
      handler_id = {__MODULE__, :reorder_test, System.unique_integer([:positive])}
      pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:perp_walk, :markets, :store, :wal_seq_anomaly],
          fn _event, measurements, metadata, _config ->
            send(pid, {:anomaly, measurements, metadata})
          end,
          nil
        )

      try do
        entries = [
          %Entry{type: :market_put, payload: Map.put(market_payload(market), :seq, 5)},
          # A small backward step within the same (origin, type) — the
          # direct-write seal-then-append race can produce this with no
          # tampering. Tolerated, with telemetry.
          %Entry{type: :market_put, payload: Map.put(market_payload(market), :seq, 3)}
        ]

        _ = Store.apply_entries(entries, tables)

        assert_receive {:anomaly, %{observed: 3, last: 5}, %{kind: :minor_reorder}}, 100
      after
        :telemetry.detach(handler_id)
      end
    end

    test "large same-origin rewind trips the halt-on-corrupt raise", %{apply_tables: tables} do
      market = MarketsHelpers.build_market()

      entries = [
        %Entry{type: :market_put, payload: Map.put(market_payload(market), :seq, 100)},
        # A rewind beyond the tolerance window is tamper-grade.
        %Entry{type: :market_put, payload: Map.put(market_payload(market), :seq, 10)}
      ]

      assert_raise RuntimeError, ~r/WAL reorder/, fn ->
        Store.apply_entries(entries, tables)
      end
    end

    test "cross-type non-monotonic seqs do NOT emit anomalies (direct-path interleave)", %{
      apply_tables: tables
    } do
      market = MarketsHelpers.build_market()
      handler_id = {__MODULE__, :cross_type_test, System.unique_integer([:positive])}
      pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:perp_walk, :markets, :store, :wal_seq_anomaly],
          fn _event, measurements, metadata, _config ->
            send(pid, {:anomaly, measurements, metadata})
          end,
          nil
        )

      try do
        # WAL order: vote_put seq=11, market_put seq=10. The
        # market_put was allocated first but the vote_put landed in
        # the WAL first because direct-path writers race against the
        # GenServer's serial handler. Per-type tracking handles this
        # cleanly — neither entry is an anomaly.
        entries = [
          %Entry{
            type: :vote_put,
            payload: %{
              vote_id: "v1",
              account_id: "a1",
              market_id: market.id,
              direction: :up,
              created_at: DateTime.to_iso8601(DateTime.utc_now()),
              seq: 11
            }
          },
          %Entry{type: :market_put, payload: Map.put(market_payload(market), :seq, 10)}
        ]

        result = Store.apply_entries(entries, tables)
        assert result.applied == 2

        refute_receive {:anomaly, _, _}, 100
      after
        :telemetry.detach(handler_id)
      end
    end

    test "entries without :seq are tolerated (legacy / hand-crafted)", %{
      apply_tables: tables
    } do
      market = MarketsHelpers.build_market()

      entries = [%Entry{type: :market_put, payload: market_payload(market)}]
      result = Store.apply_entries(entries, tables)

      assert result.applied == 1
      assert result.max_seq == 0
    end
  end

  # --- payload builders for hand-crafted apply_entries tests ---

  defp market_payload(%Market{} = m) do
    %{
      id: m.id,
      description: m.description,
      resolution_criterion: m.resolution_criterion,
      category: m.category,
      unit_size: m.unit_size,
      expiry: DateTime.to_iso8601(m.expiry),
      resolution_deadline: DateTime.to_iso8601(m.resolution_deadline),
      status: m.status,
      pool: %{yes: m.pool.yes, no: m.pool.no},
      creator_account_id: m.creator_account_id,
      deposit_amount: m.deposit_amount,
      deposit_subaddress: m.deposit_subaddress,
      deposit_subaddress_index: m.deposit_subaddress_index,
      deposit_confirmed_at: nil,
      reputation: m.reputation,
      disputes_acknowledged_count: m.disputes_acknowledged_count,
      created_at: DateTime.to_iso8601(m.created_at),
      resolved_at: nil,
      outcome: nil
    }
  end

  defp vote_payload(%PerpWalk.Markets.Vote{} = v) do
    %{
      account_id: v.account_id,
      market_id: v.market_id,
      direction: v.direction,
      created_at: DateTime.to_iso8601(v.created_at)
    }
  end

  describe "clear/1" do
    test "empties all three tables", %{store: store, tables: tables} do
      market = MarketsHelpers.build_market()
      position = Position.new(market.id, "acct-a", :yes, 10, 5_000)
      vote = MarketsHelpers.build_vote("acct-a", market.id, :up)

      :ok = Store.put_market(store, market)
      :ok = Store.put_trade(store, market, position, %{pool: market.pool, status: market.status})
      :ok = Store.put_vote(store, vote)

      :ok = Store.clear(store)

      assert :ets.tab2list(tables.markets) == []
      assert :ets.tab2list(tables.positions) == []
      assert :ets.tab2list(tables.votes) == []
    end
  end

  # Builds the standalone ETS table set used by the apply_entries
  # describes. Names follow the same module-path convention as the
  # production tables; the per-describe namespace keeps them
  # disjoint between describes in the same suite run.
  defp build_apply_tables(namespace) do
    %{
      markets: :ets.new(Module.concat(namespace, Markets), [:set, :public]),
      positions: :ets.new(Module.concat(namespace, Positions), [:set, :public]),
      votes: :ets.new(Module.concat(namespace, Votes), [:set, :public]),
      quotes: :ets.new(Module.concat(namespace, Quotes), [:set, :public]),
      disputes: :ets.new(Module.concat(namespace, Disputes), [:set, :public]),
      positions_by_market: :ets.new(Module.concat(namespace, PositionsByMarket), [:bag, :public]),
      votes_by_market: :ets.new(Module.concat(namespace, VotesByMarket), [:bag, :public]),
      markets_by_status: :ets.new(Module.concat(namespace, MarketsByStatus), [:bag, :public]),
      positions_by_account: :ets.new(Module.concat(namespace, PositionsByAccount), [:bag, :public]),
      positions_by_status: :ets.new(Module.concat(namespace, PositionsByStatus), [:bag, :public]),
      disputes_by_market: :ets.new(Module.concat(namespace, DisputesByMarket), [:bag, :public]),
      disputes_by_account: :ets.new(Module.concat(namespace, DisputesByAccount), [:bag, :public]),
      quotes_by_market: :ets.new(Module.concat(namespace, QuotesByMarket), [:bag, :public]),
      quotes_by_account: :ets.new(Module.concat(namespace, QuotesByAccount), [:bag, :public]),
      markets_by_category: :ets.new(Module.concat(namespace, MarketsByCategory), [:bag, :public]),
      markets_by_creator: :ets.new(Module.concat(namespace, MarketsByCreator), [:bag, :public]),
      disputes_by_status: :ets.new(Module.concat(namespace, DisputesByStatus), [:bag, :public]),
      quotes_by_subaddress: :ets.new(Module.concat(namespace, QuotesBySubaddress), [:set, :public]),
      disputes_by_subaddress: :ets.new(Module.concat(namespace, DisputesBySubaddress), [:set, :public]),
      markets_by_subaddress: :ets.new(Module.concat(namespace, MarketsBySubaddress), [:set, :public])
    }
  end

  # --- Quote-half of Store (formerly store_quotes_test.exs) ---

  describe "put_quote/2" do
    test "round-trips a quote through ETS", %{store: store, tables: tables} do
      q = MarketsHelpers.build_quote()
      assert :ok = Store.put_quote(store, q)
      assert {:ok, ^q} = lookup(tables.quotes, q.id)
    end
  end

  describe "put_fill/4 — atomic fill" do
    test "writes market + position + removes quote in a single WAL entry", ctx do
      market = MarketsHelpers.build_market(pool: AMM.new(95, 105))
      :ok = Store.put_market(ctx.store, market)

      quote = MarketsHelpers.build_quote(market_id: market.id)
      :ok = Store.put_quote(ctx.store, quote)

      position = Position.new(market.id, quote.account_id, :yes, 5, 50_000_000_000)

      assert :ok = Store.put_fill(ctx.store, market, position, quote.id, %{pool: market.pool, status: market.status})

      assert {:ok, ^market} = lookup(ctx.tables.markets, market.id)
      assert {:ok, ^position} = lookup(ctx.tables.positions, position.id)
      assert {:error, :not_found} = lookup(ctx.tables.quotes, quote.id)
    end

    test "WAL replay rebuilds market + position + removes consumed quote", ctx do
      market = MarketsHelpers.build_market(pool: AMM.new(95, 105))
      :ok = Store.put_market(ctx.store, market)

      quote = MarketsHelpers.build_quote(market_id: market.id)
      :ok = Store.put_quote(ctx.store, quote)

      position = Position.new(market.id, quote.account_id, :yes, 5, 50_000_000_000)
      :ok = Store.put_fill(ctx.store, market, position, quote.id, %{pool: market.pool, status: market.status})

      MarketsHelpers.restart_store(ctx)

      assert {:ok, ^market} = lookup(ctx.tables.markets, market.id)
      assert {:ok, ^position} = lookup(ctx.tables.positions, position.id)
      assert {:error, :not_found} = lookup(ctx.tables.quotes, quote.id)
    end
  end

  describe "subaddress index collision — fail-closed" do
    test "put_market with a colliding subaddress index refuses (fail-closed)", ctx do
      # Pre-fix: `maybe_log_subaddress_collision/4` logged the
      # divergence and let the insert proceed, clobbering the
      # secondary index. Cross-cluster scenario: two nodes
      # independently ran wallet-rpc `create_address` and both
      # handed out "index N" for different records — one payer's
      # deposit then filled another user's obligation, positions
      # materialised for phantom collateral. Fix: collision is a
      # raise inside `maybe_log_subaddress_collision/4`, aborting
      # the write cleanly; the surrounding GenServer handler
      # surfaces the failure as an exit on the write_call.
      m1 = MarketsHelpers.build_market()
      m2 = MarketsHelpers.build_market(deposit_subaddress_index: m1.deposit_subaddress_index)

      :ok = Store.put_market(ctx.store, m1)

      # Pre-check inside handle_call refuses the collision without
      # touching the WAL or ETS.
      assert {:error, :subaddress_collision} = Store.put_market(ctx.store, m2)

      # m1 still owns the index.
      assert :ets.lookup(ctx.tables.markets_by_subaddress, m1.deposit_subaddress_index) ==
               [{m1.deposit_subaddress_index, m1.id}]
    end

    test "put_market of the SAME record at the same index is idempotent", ctx do
      # Idempotency: replaying the same market (WAL replay, retries)
      # must not raise.
      m = MarketsHelpers.build_market()

      :ok = Store.put_market(ctx.store, m)
      :ok = Store.put_market(ctx.store, m)

      assert :ets.lookup(ctx.tables.markets_by_subaddress, m.deposit_subaddress_index) ==
               [{m.deposit_subaddress_index, m.id}]
    end
  end

  describe "WAL replay (quotes)" do
    test "rebuilds the quotes table after a Store restart", ctx do
      q1 = MarketsHelpers.build_quote(account_id: "alice", subaddress_index: 1)
      q2 = MarketsHelpers.build_quote(account_id: "bob", subaddress_index: 2)

      :ok = Store.put_quote(ctx.store, q1)
      :ok = Store.put_quote(ctx.store, q2)

      MarketsHelpers.restart_store(ctx)

      assert {:ok, ^q1} = lookup(ctx.tables.quotes, q1.id)
      assert {:ok, ^q2} = lookup(ctx.tables.quotes, q2.id)
    end
  end

  describe "apply_entries/3 emit_events: cross-node LiveView re-emission" do
    setup do
      ns = Store.ApplyEntriesEmitTest
      tables = build_apply_tables(ns)
      %{apply_tables: tables}
    end

    test "with emit_events: true republishes MarketsEvents.QuoteFilled after applying :quote_filled",
         %{apply_tables: tables} do
      market = MarketsHelpers.build_market()
      position = Position.new(market.id, "acct-a", :yes, 10, 500_000, 25_000)

      entry = %Entry{
        type: :quote_filled,
        payload: %{
          market: Serialize.market(market),
          position: Serialize.position(position),
          quote_id: "quote-under-test",
          seq: 1
        }
      }

      :ok = EventBus.subscribe(MarketsEvents.QuoteFilled)

      Store.apply_entries([entry], tables, emit_events: true)

      assert_receive %MarketsEvents.QuoteFilled{
                       quote_id: "quote-under-test",
                       position_id: pid,
                       market_id: mid,
                       account_id: "acct-a",
                       side: :yes,
                       contracts: 10,
                       amount_paid_piconeros: 500_000
                     },
                     500

      assert pid == position.id
      assert mid == market.id
    end

    test "with emit_events: false (or default) no MarketsEvents.QuoteFilled is published",
         %{apply_tables: tables} do
      market = MarketsHelpers.build_market()
      position = Position.new(market.id, "acct-a", :yes, 10, 500_000, 25_000)

      entry = %Entry{
        type: :quote_filled,
        payload: %{
          market: Serialize.market(market),
          position: Serialize.position(position),
          quote_id: "quote-no-emit",
          seq: 1
        }
      }

      :ok = EventBus.subscribe(MarketsEvents.QuoteFilled)

      Store.apply_entries([entry], tables)

      refute_receive %MarketsEvents.QuoteFilled{}, 100
    end
  end
end
