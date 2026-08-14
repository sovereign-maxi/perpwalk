defmodule PerpWalk.Markets.MarketTest do
  @moduledoc "Unit tests for PerpWalk.Markets.Market."

  use ExUnit.Case, async: true

  alias PerpWalk.Markets.{AMM, Market}

  defp valid_opts(overrides \\ []) do
    now = DateTime.utc_now()

    [
      description: "Will Trump pardon Snowden by July 4 2026?",
      resolution_criterion: "Resolves YES if a presidential pardon is issued for Snowden before the closing time.",
      category: :politics,
      unit_size: 10_000_000_000,
      expiry: DateTime.add(now, 86_400, :second),
      resolution_deadline: DateTime.add(now, 86_400 * 4, :second),
      pool: AMM.new(100, 100),
      creator_account_id: "creator-hash",
      deposit_amount: 1_000_000_000_000,
      status: :pending
    ]
    |> Keyword.merge(overrides)
  end

  describe "new/1" do
    test "creates a market in :pending status when status is overridden" do
      {:ok, market} = Market.new(valid_opts())
      assert market.status == :pending
      assert market.outcome == nil
      assert market.resolved_at == nil
      assert market.reputation == 0
      assert is_binary(market.id) and byte_size(market.id) == 32
      assert %DateTime{} = market.created_at
    end

    test "rejects an invalid category" do
      assert {:error, :invalid_category} = Market.new(valid_opts(category: :unknown))
    end

    test "rejects a resolution_deadline at or before expiry" do
      now = DateTime.utc_now()
      same = DateTime.add(now, 1000, :second)

      assert {:error, :resolution_before_expiry} =
               Market.new(valid_opts(expiry: same, resolution_deadline: same))

      assert {:error, :resolution_before_expiry} =
               Market.new(
                 valid_opts(
                   expiry: DateTime.add(now, 1000, :second),
                   resolution_deadline: DateTime.add(now, 500, :second)
                 )
               )
    end

    test "rejects a non-positive unit_size" do
      assert {:error, :invalid_unit_size} = Market.new(valid_opts(unit_size: 0))
      assert {:error, :invalid_unit_size} = Market.new(valid_opts(unit_size: -1))
    end

    test "rejects a non-integer unit_size" do
      assert {:error, :invalid_unit_size} = Market.new(valid_opts(unit_size: 1.5))
      assert {:error, :invalid_unit_size} = Market.new(valid_opts(unit_size: nil))
    end

    test "rejects a non-positive deposit_amount" do
      assert {:error, :invalid_deposit_amount} = Market.new(valid_opts(deposit_amount: 0))
      assert {:error, :invalid_deposit_amount} = Market.new(valid_opts(deposit_amount: -100))
    end

    test "rejects a non-integer deposit_amount" do
      assert {:error, :invalid_deposit_amount} = Market.new(valid_opts(deposit_amount: 1.0))
      assert {:error, :invalid_deposit_amount} = Market.new(valid_opts(deposit_amount: nil))
    end
  end

  describe "new/1 — awaiting_deposit default" do
    defp deposit_opts(overrides \\ []) do
      valid_opts(
        Keyword.merge(
          [
            status: :awaiting_deposit,
            deposit_subaddress: "subaddr-deposit-#{System.unique_integer([:positive])}",
            deposit_subaddress_index: System.unique_integer([:positive])
          ],
          overrides
        )
      )
    end

    test "default status is :awaiting_deposit when no status override is supplied" do
      opts = valid_opts() |> Keyword.delete(:status)

      opts =
        opts ++
          [
            deposit_subaddress: "subaddr-x",
            deposit_subaddress_index: 1
          ]

      {:ok, market} = Market.new(opts)
      assert market.status == :awaiting_deposit
      assert market.deposit_subaddress == "subaddr-x"
      assert market.deposit_subaddress_index == 1
      assert market.deposit_confirmed_at == nil
    end

    test "rejects when default status implies awaiting_deposit but no subaddress is supplied" do
      opts = valid_opts() |> Keyword.delete(:status)
      assert {:error, :deposit_subaddress_required} = Market.new(opts)
    end

    test "confirm_deposit/1 transitions :awaiting_deposit → :pending and stamps confirmed_at" do
      {:ok, market} = Market.new(deposit_opts())
      assert market.status == :awaiting_deposit
      {:ok, confirmed} = Market.confirm_deposit(market)
      assert confirmed.status == :pending
      assert %DateTime{} = confirmed.deposit_confirmed_at
    end

    test "confirm_deposit/1 rejects from any non-awaiting-deposit status" do
      {:ok, market} = Market.new(valid_opts())
      assert market.status == :pending
      assert Market.confirm_deposit(market) == {:error, :invalid_transition}

      {:ok, active} = Market.activate(market)
      assert Market.confirm_deposit(active) == {:error, :invalid_transition}
    end
  end

  describe "activate/1" do
    test "transitions :pending → :active" do
      {:ok, market} = Market.new(valid_opts())
      {:ok, active} = Market.activate(market)
      assert active.status == :active
    end

    test "rejects activation from any non-pending status" do
      {:ok, market} = Market.new(valid_opts())
      {:ok, active} = Market.activate(market)
      assert Market.activate(active) == {:error, :invalid_transition}
    end
  end

  describe "reject/1" do
    test "transitions :pending → :rejected" do
      {:ok, market} = Market.new(valid_opts())
      {:ok, rejected} = Market.reject(market)
      assert rejected.status == :rejected
    end

    test "rejects from non-pending status" do
      {:ok, market} = Market.new(valid_opts())
      {:ok, active} = Market.activate(market)
      assert Market.reject(active) == {:error, :invalid_transition}
    end
  end

  describe "expire/1" do
    test "transitions :active → :expired" do
      {:ok, market} = Market.new(valid_opts())
      {:ok, active} = Market.activate(market)
      {:ok, expired} = Market.expire(active)
      assert expired.status == :expired
    end

    test "rejects from non-active status" do
      {:ok, market} = Market.new(valid_opts())
      assert Market.expire(market) == {:error, :invalid_transition}
    end
  end

  describe "submit_resolution/2" do
    test "transitions :expired → :resolving with outcome" do
      {:ok, market} = Market.new(valid_opts())
      {:ok, active} = Market.activate(market)
      {:ok, expired} = Market.expire(active)
      {:ok, resolving} = Market.submit_resolution(expired, :yes)

      assert resolving.status == :resolving
      assert resolving.outcome == :yes
    end

    test "accepts :yes, :no, and :void outcomes" do
      for outcome <- [:yes, :no, :void] do
        {:ok, market} = Market.new(valid_opts())
        {:ok, active} = Market.activate(market)
        {:ok, expired} = Market.expire(active)
        {:ok, resolving} = Market.submit_resolution(expired, outcome)
        assert resolving.outcome == outcome
      end
    end

    test "rejects from non-expired status" do
      {:ok, market} = Market.new(valid_opts())
      assert Market.submit_resolution(market, :yes) == {:error, :invalid_transition}
    end
  end

  describe "reverse_resolution/2" do
    test "updates the outcome while in :resolving" do
      {:ok, market} = Market.new(valid_opts())
      {:ok, active} = Market.activate(market)
      {:ok, expired} = Market.expire(active)
      {:ok, resolving} = Market.submit_resolution(expired, :yes)
      {:ok, reversed} = Market.reverse_resolution(resolving, :no)

      assert reversed.status == :resolving
      assert reversed.outcome == :no
    end

    test "rejects from non-resolving status" do
      {:ok, market} = Market.new(valid_opts())
      assert Market.reverse_resolution(market, :yes) == {:error, :invalid_transition}
    end
  end

  describe "settle/1" do
    test "transitions :resolving → :settled and stamps resolved_at" do
      {:ok, market} = Market.new(valid_opts())
      {:ok, active} = Market.activate(market)
      {:ok, expired} = Market.expire(active)
      {:ok, resolving} = Market.submit_resolution(expired, :yes)
      {:ok, settled} = Market.settle(resolving)

      assert settled.status == :settled
      assert %DateTime{} = settled.resolved_at
    end

    test "rejects from non-resolving status" do
      {:ok, market} = Market.new(valid_opts())
      assert Market.settle(market) == {:error, :invalid_transition}
    end

    test "rejects a :void outcome — voids go through void/1 with refunds" do
      {:ok, market} = Market.new(valid_opts())
      {:ok, active} = Market.activate(market)
      {:ok, expired} = Market.expire(active)
      {:ok, resolving_void} = Market.submit_resolution(expired, :void)

      assert Market.settle(resolving_void) == {:error, :invalid_outcome}
    end
  end

  describe "void/1" do
    test "voids from :expired" do
      {:ok, market} = Market.new(valid_opts())
      {:ok, active} = Market.activate(market)
      {:ok, expired} = Market.expire(active)
      {:ok, voided} = Market.void(expired)

      assert voided.status == :voided
      assert voided.outcome == :void
      assert %DateTime{} = voided.resolved_at
    end

    test "voids from :resolving" do
      {:ok, market} = Market.new(valid_opts())
      {:ok, active} = Market.activate(market)
      {:ok, expired} = Market.expire(active)
      {:ok, resolving} = Market.submit_resolution(expired, :yes)
      {:ok, voided} = Market.void(resolving)

      assert voided.status == :voided
      assert voided.outcome == :void
    end

    test "rejects voiding from :pending or :active or :settled" do
      {:ok, market} = Market.new(valid_opts())
      assert Market.void(market) == {:error, :invalid_transition}

      {:ok, active} = Market.activate(market)
      assert Market.void(active) == {:error, :invalid_transition}
    end
  end

  describe "update_pool/2" do
    test "updates the pool while :active" do
      {:ok, market} = Market.new(valid_opts())
      {:ok, active} = Market.activate(market)
      new_pool = AMM.new(99, 102)
      {:ok, updated} = Market.update_pool(active, new_pool)
      assert updated.pool == new_pool
    end

    test "rejects pool updates outside :active" do
      {:ok, market} = Market.new(valid_opts())
      assert Market.update_pool(market, AMM.new(1, 1)) == {:error, :invalid_transition}
    end
  end

  describe "put_reputation/2" do
    test "sets the reputation score" do
      {:ok, market} = Market.new(valid_opts())
      assert Market.put_reputation(market, 5).reputation == 5
      assert Market.put_reputation(market, -3).reputation == -3
    end
  end

  describe "expired?/1 and resolution_overdue?/1" do
    test "expired? is false for a future expiry" do
      {:ok, market} = Market.new(valid_opts())
      refute Market.expired?(market)
    end

    test "expired? is true for a past expiry" do
      now = DateTime.utc_now()
      past = DateTime.add(now, -3600, :second)
      future_deadline = DateTime.add(past, 86_400, :second)

      {:ok, market} =
        Market.new(valid_opts(expiry: past, resolution_deadline: future_deadline))

      assert Market.expired?(market)
    end

    test "resolution_overdue? is false before the deadline" do
      {:ok, market} = Market.new(valid_opts())
      refute Market.resolution_overdue?(market)
    end

    test "resolution_overdue? is true after the deadline" do
      now = DateTime.utc_now()
      past_expiry = DateTime.add(now, -7200, :second)
      past_deadline = DateTime.add(now, -3600, :second)

      {:ok, market} =
        Market.new(valid_opts(expiry: past_expiry, resolution_deadline: past_deadline))

      assert Market.resolution_overdue?(market)
    end
  end
end
