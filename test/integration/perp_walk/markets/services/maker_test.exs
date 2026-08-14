defmodule PerpWalk.Markets.Services.MakerIntegrationTest do
  @moduledoc "Integration tests for PerpWalk.Markets.Services.Maker."

  use PerpWalk.IntegrationCase

  import PerpWalk.TestHelpers.MarketsHelpers, only: [market_opts: 1]

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.{AMM, Market, Store}
  alias PerpWalk.Markets.Services.Maker

  describe "create_market/1" do
    test "persists a market in :awaiting_deposit and publishes MarketCreated" do
      :ok = EventBus.subscribe(MarketsEvents.MarketCreated)

      assert {:ok, %Market{} = market} = Maker.create_market(market_opts([]))
      assert market.status == :awaiting_deposit
      assert is_binary(market.deposit_subaddress)
      assert is_integer(market.deposit_subaddress_index)
      assert market.deposit_confirmed_at == nil

      assert_receive %MarketsEvents.MarketCreated{
                       market_id: id,
                       category: :politics,
                       creator_account_id: "creator-hash"
                     },
                     1_000

      assert id == market.id

      assert {:ok, stored} = Store.get_market(market.id)
      assert stored.id == market.id
      assert stored.status == :awaiting_deposit
      assert stored.deposit_subaddress == market.deposit_subaddress

      EventBus.unsubscribe(MarketsEvents.MarketCreated)
    end

    test "rejects an invalid category and does not persist" do
      :ok = EventBus.subscribe(MarketsEvents.MarketCreated)

      assert {:error, :invalid_category} =
               Maker.create_market(market_opts(category: :unknown))

      refute_receive %MarketsEvents.MarketCreated{}, 100
      assert Store.list_markets() == []

      EventBus.unsubscribe(MarketsEvents.MarketCreated)
    end

    test "derives resolution_deadline from expiry + configured window" do
      expiry = DateTime.add(DateTime.utc_now(), 86_400, :second)

      assert {:ok, %Market{} = market} = Maker.create_market(market_opts(expiry: expiry))

      window = Application.get_env(:perpwalk, :markets) |> Keyword.fetch!(:resolution_window_seconds)
      assert DateTime.diff(market.resolution_deadline, market.expiry, :second) == window
    end

    test "rejects an expiry in the past" do
      past = DateTime.add(DateTime.utc_now(), -3_600, :second)

      assert {:error, :expiry_not_in_future} = Maker.create_market(market_opts(expiry: past))
      assert Store.list_markets() == []
    end

    test "rejects a non-DateTime expiry with an error tuple, not a crash" do
      assert {:error, :expiry_not_datetime} = Maker.create_market(market_opts(expiry: "tomorrow"))
      assert Store.list_markets() == []
    end

    test "raises if a caller tries to pass :resolution_deadline directly" do
      assert_raise ArgumentError, ~r/does not accept \[:resolution_deadline\]/, fn ->
        Maker.create_market([resolution_deadline: DateTime.utc_now()] ++ market_opts([]))
      end
    end

    test "{:error, {:subaddress_provider_failed, _}} when allocator returns an error" do
      bad_provider = fn -> {:error, :rpc_unreachable} end

      assert {:error, {:subaddress_provider_failed, :rpc_unreachable}} =
               Maker.create_market(market_opts(subaddress_provider: bad_provider))

      assert Store.list_markets() == []
    end
  end

  describe "create_market/1 — deposit tuning" do
    test "creator-supplied :deposit_amount overrides the default" do
      # 5 XMR = 5_000_000_000_000 piconeros; 500 initial contracts per side
      # at 0.01 XMR unit size.
      deposit = 5_000_000_000_000

      assert {:ok, %Market{} = market} =
               Maker.create_market(market_opts(deposit_amount: deposit))

      assert market.deposit_amount == deposit
      assert market.pool.yes == AMM.to_subunits(500)
      assert market.pool.no == AMM.to_subunits(500)
    end

    test "omitting :deposit_amount falls back to the configured floor" do
      assert {:ok, %Market{deposit_amount: default}} =
               Maker.create_market(market_opts([]))

      assert default == Maker.min_deposit_piconeros()
    end

    test "rejects deposit below configured min" do
      previous = Application.get_env(:perpwalk, :markets, [])
      # 2 XMR floor for this test
      Application.put_env(
        :perpwalk,
        :markets,
        Keyword.put(previous, :min_deposit_piconeros, 2_000_000_000_000)
      )

      on_exit(fn -> Application.put_env(:perpwalk, :markets, previous) end)

      # 1 XMR — below the floor
      assert {:error, {:deposit_below_min, 1_000_000_000_000, 2_000_000_000_000}} =
               Maker.create_market(market_opts(deposit_amount: 1_000_000_000_000))

      assert Store.list_markets() == []
    end

    test "rejects deposit above configured max" do
      previous = Application.get_env(:perpwalk, :markets, [])
      # 10 XMR ceiling for this test
      Application.put_env(
        :perpwalk,
        :markets,
        Keyword.put(previous, :max_deposit_piconeros, 10_000_000_000_000)
      )

      on_exit(fn -> Application.put_env(:perpwalk, :markets, previous) end)

      # 50 XMR — above the ceiling
      assert {:error, {:deposit_above_max, 50_000_000_000_000, 10_000_000_000_000}} =
               Maker.create_market(market_opts(deposit_amount: 50_000_000_000_000))

      assert Store.list_markets() == []
    end

    test "rejects deposit that is not a multiple of deposit_step" do
      # 1.5 XMR — passes unit_size (0.01 XMR) but not deposit_step (1 XMR)
      bad_deposit = 1_500_000_000_000

      assert {:error, {:deposit_not_step_multiple, ^bad_deposit, _}} =
               Maker.create_market(market_opts(deposit_amount: bad_deposit))

      assert Store.list_markets() == []
    end
  end

  describe "confirm_deposit/1" do
    test "transitions :awaiting_deposit → :pending and publishes MarketDepositConfirmed" do
      :ok = EventBus.subscribe(MarketsEvents.MarketDepositConfirmed)

      {:ok, %Market{} = market} = Maker.create_market(market_opts([]))
      assert market.status == :awaiting_deposit

      assert {:ok, confirmed} = Maker.confirm_deposit(market.id)
      assert confirmed.status == :pending
      assert %DateTime{} = confirmed.deposit_confirmed_at

      assert_receive %MarketsEvents.MarketDepositConfirmed{market_id: id}, 1_000
      assert id == market.id

      {:ok, stored} = Store.get_market(market.id)
      assert stored.status == :pending

      EventBus.unsubscribe(MarketsEvents.MarketDepositConfirmed)
    end

    test "{:error, :market_not_found} for an unknown id" do
      assert {:error, :market_not_found} = Maker.confirm_deposit("missing-id")
    end

    test "{:error, :invalid_transition} when called twice" do
      {:ok, raw} = Maker.create_market(market_opts([]))
      {:ok, _confirmed} = Maker.confirm_deposit(raw.id)
      assert {:error, :invalid_transition} = Maker.confirm_deposit(raw.id)
    end
  end
end
