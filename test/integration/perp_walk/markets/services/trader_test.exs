defmodule PerpWalk.Markets.Services.TraderIntegrationTest do
  @moduledoc "Integration tests for PerpWalk.Markets.Services.Trader."

  use PerpWalk.IntegrationCase

  import PerpWalk.TestHelpers.MarketsHelpers,
    only: [
      activate!: 1,
      build_market: 1,
      pending_market!: 0,
      pending_market!: 1,
      refund_address_stub: 0
    ]

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.{AMM, Quote, Store}
  alias PerpWalk.Markets.Services.Trader

  # Trader tests vary the AMM pool (and occasionally `:unit_size`) per
  # case to exercise pricing and liquidity edges — and
  # `Maker.create_market/1` deliberately doesn't accept either since
  # they're operator dials. Build the struct directly, stage it into
  # the store at :pending, then run the real activation path.
  defp active_market(opts) do
    market = build_market(opts)
    :ok = Store.put_market(market)
    activate!(market)
  end

  describe "place_position/4 — happy path" do
    test "opens a YES position on an active market and updates the pool" do
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))
      :ok = EventBus.subscribe(MarketsEvents.PositionOpened)

      assert {:ok, position} = Trader.place_position("acct-a", market.id, :yes, 10)

      assert position.market_id == market.id
      assert position.account_id == "acct-a"
      assert position.side == :yes
      assert position.contracts == 10
      assert position.amount_paid > 0
      assert position.status == :open

      assert_receive %MarketsEvents.PositionOpened{
                       position_id: id,
                       market_id: mid,
                       account_id: "acct-a",
                       side: :yes,
                       contracts: 10
                     },
                     1_000

      assert id == position.id
      assert mid == market.id

      {:ok, updated_market} = Store.get_market(market.id)
      assert updated_market.pool.yes < market.pool.yes
      assert updated_market.pool.no > market.pool.no
      # K should not decrease (it can drift up due to ceiling rounding).
      assert updated_market.pool.yes * updated_market.pool.no >=
               market.pool.yes * market.pool.no

      EventBus.unsubscribe(MarketsEvents.PositionOpened)
    end

    test "opens a NO position symmetrically" do
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))
      assert {:ok, position} = Trader.place_position("acct-b", market.id, :no, 10)

      assert position.side == :no

      {:ok, updated_market} = Store.get_market(market.id)
      assert updated_market.pool.no < market.pool.no
      assert updated_market.pool.yes > market.pool.yes
    end

    test "amount_paid matches AMM.cost_to_piconeros(cost_subunits, unit_size)" do
      unit_size = 10_000_000_000
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)), unit_size: unit_size)
      contracts = 10

      {:ok, position} = Trader.place_position("acct-a", market.id, :yes, contracts)
      {:ok, updated_market} = Store.get_market(market.id)

      # Re-derive cost from AMM at the original pool state; the Trader
      # scales contracts → subunits, quotes the AMM, then converts the
      # subunit cost back to piconeros via cost_to_piconeros/2.
      {:ok, expected_cost_subunits, _pool_after_quote} =
        AMM.quote(market.pool, :yes, AMM.to_subunits(contracts))

      assert position.amount_paid == AMM.cost_to_piconeros(expected_cost_subunits, unit_size)
      assert updated_market.pool.no - market.pool.no > 0
    end

    test "two trades on the same market accumulate positions and move the pool further" do
      market = active_market(pool: AMM.new(AMM.to_subunits(1_000), AMM.to_subunits(1_000)))

      {:ok, p1} = Trader.place_position("acct-a", market.id, :yes, 50)
      {:ok, m1} = Store.get_market(market.id)

      {:ok, p2} = Trader.place_position("acct-b", market.id, :yes, 50)
      {:ok, m2} = Store.get_market(market.id)

      # Pool kept moving in the same direction.
      assert m2.pool.yes < m1.pool.yes
      assert m2.pool.no > m1.pool.no

      # Both positions exist.
      assert length(Store.list_positions_for_market(market.id)) == 2
      assert p1.id != p2.id
    end

    test "creator cannot take a position on their own market" do
      # The creator already has economic exposure via the LP seed
      # (residual at settlement, full deposit on void) and the 1/6
      # spread share. Directional trading on top compounds a
      # private-information edge into a conflict with the creator's
      # resolution authority, so the service refuses both legacy
      # `place_position/4` and the quote-based `create_quote/5` path.
      market =
        active_market(
          pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)),
          creator_account_id: "creator-x"
        )

      assert {:error, :creator_cannot_trade_own_market} =
               Trader.place_position("creator-x", market.id, :yes, 5)

      assert {:error, :creator_cannot_trade_own_market} =
               Trader.create_quote("creator-x", market.id, :yes, 5, refund_address: refund_address_stub())

      # State unchanged on refusal: no position, no pool drift.
      assert Store.list_positions_for_market(market.id) == []
      {:ok, after_refusal} = Store.get_market(market.id)
      assert after_refusal.pool == market.pool
    end
  end

  describe "place_position/4 — errors" do
    test "errors when the market does not exist" do
      assert {:error, :market_not_found} =
               Trader.place_position("acct-a", "no-such-id", :yes, 10)
    end

    test "errors when the market is :pending" do
      pending = pending_market!([])

      assert {:error, :market_not_active} =
               Trader.place_position("acct-a", pending.id, :yes, 10)
    end

    test "errors on insufficient liquidity" do
      market = active_market(pool: AMM.new(10, 10))

      assert {:error, :insufficient_liquidity} =
               Trader.place_position("acct-a", market.id, :yes, 10)
    end

    test "failed trades publish no event and do not mutate state" do
      market = active_market(pool: AMM.new(10, 10))
      :ok = EventBus.subscribe(MarketsEvents.PositionOpened)

      assert {:error, :insufficient_liquidity} =
               Trader.place_position("acct-a", market.id, :yes, 10)

      refute_receive %MarketsEvents.PositionOpened{}, 100

      {:ok, after_attempt} = Store.get_market(market.id)
      assert after_attempt.pool == market.pool
      assert Store.list_positions_for_market(market.id) == []

      EventBus.unsubscribe(MarketsEvents.PositionOpened)
    end
  end

  # --- create_quote/5 (formerly trader_quote_test.exs) ---

  defp stub_subaddress(address \\ "8aabbccddeeff", index \\ 17) do
    fn -> {:ok, %{address: address, address_index: index}} end
  end

  describe "create_quote/5 — happy path" do
    test "creates a pending quote with locked-in cost and a fresh subaddress" do
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))
      :ok = EventBus.subscribe(MarketsEvents.QuoteCreated)

      assert {:ok, quote} =
               Trader.create_quote("acct-a", market.id, :yes, 10,
                 refund_address: refund_address_stub(),
                 subaddress_provider: stub_subaddress("subaddr-1", 7)
               )

      assert quote.market_id == market.id
      assert quote.account_id == "acct-a"
      assert quote.side == :yes
      assert quote.contracts == 10
      assert quote.amount_paid_piconeros > 0
      assert quote.subaddress == "subaddr-1"
      assert quote.subaddress_index == 7
      assert %DateTime{} = quote.expires_at
      assert %DateTime{} = quote.created_at

      assert_receive %MarketsEvents.QuoteCreated{
                       quote_id: id,
                       market_id: mid,
                       account_id: "acct-a",
                       side: :yes,
                       contracts: 10
                     },
                     500

      assert id == quote.id
      assert mid == market.id
    end

    test "AMM is NOT mutated at quote time — pool is unchanged" do
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))
      starting_pool = market.pool

      assert {:ok, _quote} =
               Trader.create_quote("acct-a", market.id, :yes, 10,
                 refund_address: refund_address_stub(),
                 subaddress_provider: stub_subaddress()
               )

      {:ok, refreshed} = Store.get_market(market.id)
      assert refreshed.pool == starting_pool
    end

    test "quote is persisted and findable via Store.get_quote/1" do
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))

      {:ok, quote} =
        Trader.create_quote("acct-a", market.id, :no, 5,
          refund_address: refund_address_stub(),
          subaddress_provider: stub_subaddress()
        )

      assert {:ok, ^quote} = Store.get_quote(quote.id)
    end

    test "expires_in_seconds option overrides the default 30-minute window" do
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))

      {:ok, quote} =
        Trader.create_quote("acct-a", market.id, :yes, 5,
          refund_address: refund_address_stub(),
          subaddress_provider: stub_subaddress(),
          expires_in_seconds: 60
        )

      window = DateTime.diff(quote.expires_at, quote.created_at, :second)
      assert window in 59..61
    end
  end

  describe "create_quote/5 — error paths" do
    test "{:error, :refund_address_required} when opt is missing" do
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))

      assert {:error, :refund_address_required} =
               Trader.create_quote("acct-a", market.id, :yes, 10, subaddress_provider: stub_subaddress())
    end

    test "{:error, :refund_address_invalid} when opt is a non-Monero string" do
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))

      assert {:error, :refund_address_invalid} =
               Trader.create_quote("acct-a", market.id, :yes, 10,
                 refund_address: "not-a-monero-address",
                 subaddress_provider: stub_subaddress()
               )
    end

    test "{:error, :market_not_found} when market id doesn't exist" do
      assert {:error, :market_not_found} =
               Trader.create_quote("acct-a", "missing-id", :yes, 10,
                 refund_address: refund_address_stub(),
                 subaddress_provider: stub_subaddress()
               )
    end

    test "{:error, :market_not_active} for a pending market" do
      market = pending_market!()

      assert {:error, :market_not_active} =
               Trader.create_quote("acct-a", market.id, :yes, 10,
                 refund_address: refund_address_stub(),
                 subaddress_provider: stub_subaddress()
               )
    end

    test "{:error, :insufficient_liquidity} when contracts exceed pool side" do
      market = active_market(pool: AMM.new(AMM.to_subunits(10), AMM.to_subunits(100)))

      # Buying 10 YES contracts would empty the YES side entirely.
      assert {:error, :insufficient_liquidity} =
               Trader.create_quote("acct-a", market.id, :yes, 10,
                 refund_address: refund_address_stub(),
                 subaddress_provider: stub_subaddress()
               )
    end

    test "{:error, {:subaddress_provider_failed, _}} when provider returns error" do
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))
      provider = fn -> {:error, :wallet_unreachable} end

      assert {:error, {:subaddress_provider_failed, :wallet_unreachable}} =
               Trader.create_quote("acct-a", market.id, :yes, 10,
                 refund_address: refund_address_stub(),
                 subaddress_provider: provider
               )
    end

    test "{:error, {:subaddress_provider_failed, _}} when provider raises" do
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))
      provider = fn -> raise "boom" end

      assert {:error, {:subaddress_provider_failed, %RuntimeError{}}} =
               Trader.create_quote("acct-a", market.id, :yes, 10,
                 refund_address: refund_address_stub(),
                 subaddress_provider: provider
               )
    end

    test "no QuoteCreated event published on error" do
      :ok = EventBus.subscribe(MarketsEvents.QuoteCreated)

      _ =
        Trader.create_quote("acct-a", "missing-id", :yes, 10,
          refund_address: refund_address_stub(),
          subaddress_provider: stub_subaddress()
        )

      refute_receive %MarketsEvents.QuoteCreated{}, 100
    end
  end

  # --- fill_quote/2 (formerly trader_fill_test.exs) ---

  defp create_quote!(market, opts \\ []) do
    {:ok, quote} =
      Trader.create_quote(
        Keyword.get(opts, :account_id, "acct-a"),
        market.id,
        Keyword.get(opts, :side, :yes),
        Keyword.get(opts, :contracts, 10),
        refund_address: refund_address_stub(),
        subaddress_provider: fn -> {:ok, %{address: "subaddr", address_index: 1}} end
      )

    quote
  end

  describe "fill_quote/2 — happy path" do
    test "consumes a quote into a position with the locked-in amount" do
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))
      quote = create_quote!(market, contracts: 10)

      :ok = EventBus.subscribe(MarketsEvents.QuoteFilled)

      assert {:ok, position} = Trader.fill_quote(quote.id)

      assert position.market_id == market.id
      assert position.account_id == "acct-a"
      assert position.side == :yes
      assert position.contracts == 10
      assert position.amount_paid == quote.amount_paid_piconeros
      assert position.status == :open

      assert_receive %MarketsEvents.QuoteFilled{
                       quote_id: qid,
                       position_id: pid,
                       contracts: 10,
                       amount_paid_piconeros: amount
                     },
                     500

      assert qid == quote.id
      assert pid == position.id
      assert amount == quote.amount_paid_piconeros
    end

    test "AMM moves at fill time (not at quote time)" do
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))
      starting_pool = market.pool

      quote = create_quote!(market, contracts: 10)

      # Pool unchanged at quote time
      {:ok, after_quote} = Store.get_market(market.id)
      assert after_quote.pool == starting_pool

      {:ok, _position} = Trader.fill_quote(quote.id)

      # Pool moved at fill time
      {:ok, after_fill} = Store.get_market(market.id)
      refute after_fill.pool == starting_pool
    end

    test "the consumed quote is removed from the store" do
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))
      quote = create_quote!(market)

      assert {:ok, ^quote} = Store.get_quote(quote.id)

      {:ok, _position} = Trader.fill_quote(quote.id)

      assert {:error, :not_found} = Store.get_quote(quote.id)
    end

    test "deposit_txid is included on the QuoteFilled event when supplied" do
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))
      quote = create_quote!(market)

      :ok = EventBus.subscribe(MarketsEvents.QuoteFilled)

      {:ok, _position} = Trader.fill_quote(quote.id, deposit_txid: "abc123")

      assert_receive %MarketsEvents.QuoteFilled{deposit_txid: "abc123"}, 500
    end
  end

  describe "fill_quote/2 — error paths" do
    test "{:error, :quote_not_found} when quote id doesn't exist" do
      assert {:error, :quote_not_found} = Trader.fill_quote("missing-id")
    end

    test "{:error, :quote_expired} for an expired quote" do
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))
      quote = create_quote!(market)

      # Backdate expires_at to 1s ago.
      expired = %{quote | expires_at: DateTime.add(DateTime.utc_now(), -1, :second)}
      :ok = Store.put_quote(expired)

      assert {:error, :quote_expired} = Trader.fill_quote(quote.id)
    end

    test "{:error, :market_not_active} when market has settled before fill" do
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))
      quote = create_quote!(market)

      # Force the market into a non-active state by direct put.
      settled = %{market | status: :settled}
      :ok = Store.put_market(settled)

      assert {:error, :market_not_active} = Trader.fill_quote(quote.id)
    end

    test "{:error, :price_moved} when AMM cost now exceeds locked amount" do
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))

      # Build a quote with an artificially low locked-in cost.
      low_quote =
        Quote.new(
          market_id: market.id,
          account_id: "acct-a",
          side: :yes,
          contracts: 10,
          amount_paid_piconeros: 1,
          spread_piconeros: 0,
          subaddress: "subaddr",
          subaddress_index: 1,
          refund_address: refund_address_stub(),
          expires_at: DateTime.add(DateTime.utc_now(), 1800, :second)
        )

      :ok = Store.put_quote(low_quote)

      assert {:error, :price_moved} = Trader.fill_quote(low_quote.id)
    end

    test "no QuoteFilled event published on error" do
      :ok = EventBus.subscribe(MarketsEvents.QuoteFilled)

      _ = Trader.fill_quote("missing-id")

      refute_receive %MarketsEvents.QuoteFilled{}, 100
    end
  end
end
