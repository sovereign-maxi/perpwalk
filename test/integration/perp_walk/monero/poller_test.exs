defmodule PerpWalk.Monero.PollerIntegrationTest do
  @moduledoc """
  Integration tests for the Monero deposit poller.

  Tests start the wrapper GenServer with `start_darks: false` so we
  never hit a live wallet RPC; lifecycle messages are sent
  synthetically via `send/2` and we observe state changes through
  the Markets facade and a wait helper.
  """

  use PerpWalk.IntegrationCase

  import PerpWalk.TestHelpers.MarketsHelpers,
    only: [activate!: 1, pending_market!: 1, refund_address_stub: 0]

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Federation.Store, as: FederationStore
  alias PerpWalk.Markets.{AMM, Store}
  alias PerpWalk.Markets.Services.Trader
  alias PerpWalk.Monero.{Orphans, Poller}

  setup do
    {:ok, pid} = start_supervised({Poller, [name: :test_poller, start_darks: false]})
    {:ok, pid: pid}
  end

  defp active_market(opts) do
    market = pending_market!(opts)
    activate!(market)
  end

  defp create_quote_with_subaddress(market, index, opts \\ []) do
    {:ok, quote} =
      Trader.create_quote(
        Keyword.get(opts, :account_id, "acct-a"),
        market.id,
        Keyword.get(opts, :side, :yes),
        Keyword.get(opts, :contracts, 10),
        refund_address: refund_address_stub(),
        subaddress_provider: fn -> {:ok, %{address: "subaddr-#{index}", address_index: index}} end
      )

    quote
  end

  # Forces synchronization against the Poller's mailbox by
  # round-tripping a sys call. By the time this returns, any
  # previously sent :deposit / :confirmed messages have been
  # handle_info'd. fill_quote is a synchronous GenServer call to the
  # Store from inside handle_info, so the Store mutation has also
  # already completed.
  defp drain_poller(pid), do: :sys.get_state(pid)

  describe "lookup_subaddress/1" do
    test "returns {:ok, {:quote, id}} for a pending quote with matching index" do
      market = active_market(pool: AMM.new(100, 100))
      quote = create_quote_with_subaddress(market, 42)

      assert {:ok, {:quote, found_id}} = Poller.lookup_subaddress(42)
      assert found_id == quote.id
    end

    test "returns {:ok, {:orphan, idx}} when no resource matches the non-zero index" do
      _market = active_market(pool: AMM.new(100, 100))
      # Any non-zero index with no active quote/dispute/market behind
      # it routes to the orphan path so the deposit can be recorded
      # in Orphans rather than silently dropped by Darks.Poller.
      assert {:ok, {:orphan, 999}} = Poller.lookup_subaddress(999)
    end

    test "returns :not_found for subaddress index 0 (wallet primary)" do
      # Index 0 is the wallet's primary address — never user-facing
      # and never routed to an orphan record.
      assert :not_found = Poller.lookup_subaddress(0)
    end

    test "ignores expired quotes and falls through to orphan" do
      market = active_market(pool: AMM.new(100, 100))
      quote = create_quote_with_subaddress(market, 7)

      expired = %{quote | expires_at: DateTime.add(DateTime.utc_now(), -1, :second)}
      :ok = Store.put_quote(expired)

      assert {:ok, {:orphan, 7}} = Poller.lookup_subaddress(7)
    end
  end

  describe "deposit + confirmed lifecycle" do
    test "fills a quote when amount is sufficient", %{pid: pid} do
      market = active_market(pool: AMM.new(100, 100))
      quote = create_quote_with_subaddress(market, 5, contracts: 10)

      send(pid, {:deposit, %{txid: "tx1", ref: {:quote, quote.id}, amount: quote.amount_paid_piconeros}})
      send(pid, {:confirmed, %{txid: "tx1", ref: {:quote, quote.id}, confirmations: 10}})

      drain_poller(pid)
      assert {:error, :not_found} = Store.get_quote(quote.id)
    end

    test "leaves quote pending when underpaid + auto-enqueues a refund payout", %{pid: pid} do
      :ok = FederationStore.clear()
      :ok = Orphans.clear()

      market = active_market(pool: AMM.new(100, 100))
      quote = create_quote_with_subaddress(market, 5, contracts: 10)
      underpaid = quote.amount_paid_piconeros - 1

      send(pid, {:deposit, %{txid: "tx2", ref: {:quote, quote.id}, amount: underpaid}})
      send(pid, {:confirmed, %{txid: "tx2", ref: {:quote, quote.id}, confirmations: 10}})

      drain_poller(pid)
      assert {:ok, ^quote} = Store.get_quote(quote.id)

      [payout] = FederationStore.list_payouts()
      assert payout.kind == :quote_underpayment_refund
      assert payout.source_quote_id == quote.id
      assert payout.account_id == quote.account_id
      assert payout.market_id == quote.market_id
      assert payout.destination == quote.refund_address
      assert payout.amount_piconeros == underpaid
      assert payout.status == :pending

      # Orphan should be marked resolved as soon as the refund is
      # queued — the counter drives the `:orphan_deposits_pending`
      # alert, and once the auto-refund is in flight the entry no
      # longer needs operator eyes. Audit-trail row is still present
      # in the DETS list; only the count filters it out.
      assert Orphans.count() == 0
      [orphan] = Orphans.list()
      assert orphan.txid == "tx2"
      assert orphan.kind == :underpayment
      assert orphan.status == :resolved
    end

    test "a resolved orphan never resurrects on re-fire" do
      :ok = Orphans.clear()

      :ok = Orphans.record(:underpayment, "tx-resurrect", 1_000, %{quote_id: "q"}, 10)
      :ok = Orphans.mark_resolved("tx-resurrect")

      # A rescan/eviction re-fire of the same txid must not reopen the
      # row — the operator runbook would issue a second, manual refund.
      :ok = Orphans.record(:underpayment, "tx-resurrect", 1_000, %{quote_id: "q"}, 10)

      [orphan] = Orphans.list()
      assert orphan.status == :resolved
      assert Orphans.count() == 0
    end

    test "logs and skips :confirmed when no prior :deposit was recorded", %{pid: pid} do
      market = active_market(pool: AMM.new(100, 100))
      quote = create_quote_with_subaddress(market, 5)

      send(pid, {:confirmed, %{txid: "tx3", ref: {:quote, quote.id}, confirmations: 10}})

      drain_poller(pid)
      assert {:ok, ^quote} = Store.get_quote(quote.id)
    end

    test "skips fill when the matching quote no longer exists", %{pid: pid} do
      market = active_market(pool: AMM.new(100, 100))
      quote = create_quote_with_subaddress(market, 5)

      send(pid, {:deposit, %{txid: "tx4", ref: {:quote, quote.id}, amount: quote.amount_paid_piconeros}})
      drain_poller(pid)

      :ok = Store.clear()

      send(pid, {:confirmed, %{txid: "tx4", ref: {:quote, quote.id}, confirmations: 10}})
      drain_poller(pid)
      assert {:error, :not_found} = Store.get_quote(quote.id)
    end

    test "non-designated-processor nodes skip processing — no fill, no orphan, no Markets write",
         %{pid: pid} do
      market = active_market(pool: AMM.new(100, 100))
      quote = create_quote_with_subaddress(market, 5, contracts: 10)

      # `:p1` is the designated processor for cluster-state writes in
      # the symmetric model; any other participant observes the chain
      # locally but does not write the ledger mutation — the other
      # node receives the result via bi-directional WAL replication.
      Application.put_env(:perpwalk, :participant_id, :p2)
      on_exit(fn -> Application.put_env(:perpwalk, :participant_id, :p1) end)

      send(pid, {:deposit, %{txid: "tx5", ref: {:quote, quote.id}, amount: quote.amount_paid_piconeros}})
      send(pid, {:confirmed, %{txid: "tx5", ref: {:quote, quote.id}, confirmations: 10}})

      drain_poller(pid)
      # Quote stays pending on :p2; the fill will land via WAL
      # replication from :p1 (the designated processor) instead.
      assert {:ok, ^quote} = Store.get_quote(quote.id)
    end

    test "publishes QuoteDepositObserved on :deposit for a quote ref", %{pid: pid} do
      EventBus.subscribe(MarketsEvents.QuoteDepositObserved)
      on_exit(fn -> EventBus.unsubscribe(MarketsEvents.QuoteDepositObserved) end)

      market = active_market(pool: AMM.new(100, 100))
      quote = create_quote_with_subaddress(market, 5, contracts: 10)

      send(pid, {:deposit, %{txid: "txQ", ref: {:quote, quote.id}, amount: quote.amount_paid_piconeros}})

      assert_receive %MarketsEvents.QuoteDepositObserved{
                       quote_id: qid,
                       market_id: mid,
                       txid: "txQ"
                     },
                     500

      assert qid == quote.id
      assert mid == market.id
    end

    test "publishes MarketDepositObserved on :deposit for a market_deposit ref", %{pid: pid} do
      EventBus.subscribe(MarketsEvents.MarketDepositObserved)
      on_exit(fn -> EventBus.unsubscribe(MarketsEvents.MarketDepositObserved) end)

      market = pending_market!(pool: AMM.new(100, 100))

      send(pid, {:deposit, %{txid: "txM", ref: {:market_deposit, market.id}, amount: 1_000_000_000_000}})

      assert_receive %MarketsEvents.MarketDepositObserved{
                       market_id: mid,
                       txid: "txM",
                       amount_piconeros: 1_000_000_000_000
                     },
                     500

      assert mid == market.id
    end

    test "crediting crash records an orphan and skips recently_confirmed", %{pid: pid} do
      # Pre-fix: an uncaught exception inside process_confirmed
      # (e.g. `Trader.fill_quote` raising `SystemHaltedError` via
      # `Guards.ensure_operational!`) was silently rescued, the log line
      # emitted, and the txid was inserted into recently_confirmed
      # anyway. Subsequent Darks rescans then skipped the txid — the
      # user's funds sat in custody forever with no orphan row, no
      # refund, no retry. Fix: only bump recently_confirmed on
      # success; record a :crediting_failed orphan on crash.
      :ok = Orphans.clear()

      market = active_market(pool: AMM.new(100, 100))
      quote = create_quote_with_subaddress(market, 5, contracts: 10)

      # Trigger a crash inside process_confirmed by halting the
      # system — `Trader.fill_quote/2` calls `Guards.ensure_operational!`
      # which raises `SystemHaltedError`. Same failure mode a real
      # federation halt overlapping a confirmation would produce.
      PerpWalk.Telemetry.Health.System.set_halted("test — crediting crash")
      on_exit(fn -> PerpWalk.Telemetry.Health.System.clear_halt() end)

      send(
        pid,
        {:deposit, %{txid: "tx-crash", ref: {:quote, quote.id}, amount: quote.amount_paid_piconeros}}
      )

      send(
        pid,
        {:confirmed, %{txid: "tx-crash", ref: {:quote, quote.id}, confirmations: 10}}
      )

      drain_poller(pid)

      # Orphan recorded so operator sees the failure.
      assert [orphan] = Enum.filter(Orphans.list(), &(&1.txid == "tx-crash"))
      assert orphan.kind == :crediting_failed
      assert orphan.amount_piconeros == quote.amount_paid_piconeros

      # recently_confirmed does NOT contain the txid — so a Darks
      # rescan would re-fire :confirmed and drive another attempt
      # after operator un-halts.
      state = :sys.get_state(pid)
      refute Map.has_key?(state.recently_confirmed, "tx-crash")
    end
  end

  describe "dispute deposit lifecycle" do
    alias PerpWalk.Markets.Services.{Disputer, Resolver, Trader}

    # Disputer requires the disputer to have traded; seed voter-1
    # with a 1-contract YES position during :active.
    defp resolving_market! do
      m = pending_market!([]) |> activate!()
      {:ok, _} = Trader.place_position("voter-1", m.id, :yes, 1)
      {:ok, _} = Resolver.expire(m.id)
      {:ok, m} = Resolver.submit_resolution(m.id, :yes)
      m
    end

    test "lookup_subaddress finds an :awaiting_deposit dispute" do
      m = resolving_market!()

      {:ok, dispute} =
        Disputer.start_dispute("voter-1", m.id,
          subaddress_provider: fn -> {:ok, %{address: "dispute-addr", address_index: 99}} end
        )

      assert {:ok, {:dispute, "voter-1", market_id}} = Poller.lookup_subaddress(99)
      assert market_id == dispute.market_id
    end

    test "confirms a dispute deposit when the amount meets the stake", %{pid: pid} do
      m = resolving_market!()

      {:ok, dispute} =
        Disputer.start_dispute("voter-1", m.id,
          subaddress_provider: fn -> {:ok, %{address: "dispute-addr-2", address_index: 88}} end
        )

      ref = {:dispute, "voter-1", m.id}

      send(pid, {:deposit, %{txid: "dtx1", ref: ref, amount: dispute.stake_amount_piconeros}})
      send(pid, {:confirmed, %{txid: "dtx1", ref: ref, confirmations: 10}})

      drain_poller(pid)

      {:ok, after_confirm} = Store.get_dispute("voter-1", m.id)
      assert after_confirm.status == :live
    end

    test "leaves dispute :awaiting_deposit when underpaid", %{pid: pid} do
      m = resolving_market!()

      {:ok, dispute} =
        Disputer.start_dispute("voter-1", m.id,
          subaddress_provider: fn -> {:ok, %{address: "dispute-addr-3", address_index: 77}} end
        )

      ref = {:dispute, "voter-1", m.id}
      underpaid = dispute.stake_amount_piconeros - 1

      send(pid, {:deposit, %{txid: "dtx2", ref: ref, amount: underpaid}})
      send(pid, {:confirmed, %{txid: "dtx2", ref: ref, confirmations: 10}})

      drain_poller(pid)

      {:ok, after_attempt} = Store.get_dispute("voter-1", m.id)
      assert after_attempt.status == :awaiting_deposit
    end
  end
end
