defmodule PerpWalk.Federation.ConsoleIntegrationTest do
  @moduledoc """
  Behavioural tests for the operator iex console helpers.

  We exercise the state machine paths (force_sign, halt, resume,
  force_approve transitions) without scraping the printed output —
  printed strings are operator-facing chrome, not load-bearing.
  """

  use PerpWalk.IntegrationCase

  import PerpWalk.TestHelpers.MarketsHelpers, only: [activate!: 1, pending_market!: 0]

  alias PerpWalk.Federation
  alias PerpWalk.Federation.{Console, Payout, Signer}
  alias PerpWalk.Federation.Store, as: FederationStore

  alias PerpWalk.Markets.Services.{Cashier, Resolver, Trader}

  setup do
    :ok = FederationStore.clear()
    Signer.set_backend(fn _ -> {:error, :no_backend} end)
    if Signer.halted?(), do: Signer.resume()

    # The halt/0-and-resume/0 tests deliberately halt the Signer
    # but won't always reach a `resume`. Without an on_exit guard
    # the next test file (`signing/monero_test.exs`, etc.) inherits
    # a halted Signer and every sign call short-circuits to
    # `{:error, :signing_halted}`.
    on_exit(fn -> if Signer.halted?(), do: Signer.resume() end)

    :ok
  end

  # Cashier validates destinations against the same regex
  # `Federation.Rules.destination_sanity` checks, so we can't use a
  # short string anymore to trigger a rule rejection. Instead enqueue
  # a Payout with a valid-looking destination, then directly stamp
  # it into :awaiting_operator to set up the test scenario for
  # force_sign / status transitions.
  defp valid_destination, do: "4" <> String.duplicate("A", 94)

  defp settled_winner_request(_unused \\ nil) do
    market = pending_market!()
    market = activate!(market)
    {:ok, position} = Trader.place_position("acct-a", market.id, :yes, 5)
    {:ok, _} = Resolver.expire(market.id)
    {:ok, _} = Resolver.submit_resolution(market.id, :yes)
    {:ok, _} = Resolver.settle(market.id)

    {:ok, request} = Cashier.claim_payout(position.id, position.account_id, valid_destination())
    {:ok, awaiting} = PerpWalk.Federation.Payout.mark_awaiting_operator(request, "test rejection")
    :ok = Federation.Store.put_payout(awaiting)

    {:ok, after_tick} = Federation.Facade.get_request(request.id)
    {market, position, after_tick}
  end

  describe "force_sign/1" do
    test "transitions :awaiting_operator → :rules_passed" do
      {_market, _position, request} = settled_winner_request()
      assert request.status == :awaiting_operator

      capture_io(fn ->
        assert {:ok, updated} = Console.force_sign(request.id)
        assert updated.status == :rules_passed
      end)

      {:ok, after_force} = Federation.Facade.get_request(request.id)
      assert after_force.status == :rules_passed
    end

    test "refuses for a request not in :awaiting_operator" do
      market = pending_market!()
      market = activate!(market)
      {:ok, position} = Trader.place_position("acct-a", market.id, :yes, 5)
      {:ok, _} = Resolver.expire(market.id)
      {:ok, _} = Resolver.submit_resolution(market.id, :yes)
      {:ok, _} = Resolver.settle(market.id)

      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, "4" <> String.duplicate("A", 94))

      capture_io(fn ->
        assert {:error, :invalid_transition} = Console.force_sign(request.id)
      end)
    end

    test "{:error, :not_found} for unknown id" do
      capture_io(fn ->
        assert {:error, :not_found} = Console.force_sign("missing-id")
      end)
    end
  end

  describe "halt/0 and resume/0" do
    test "halt stops the Signer from advancing requests on tick" do
      capture_io(fn -> Console.halt() end)
      assert Federation.Facade.halted?()

      # Build a request that would normally pass rules
      market = pending_market!()
      market = activate!(market)
      {:ok, position} = Trader.place_position("acct-a", market.id, :yes, 5)
      {:ok, _} = Resolver.expire(market.id)
      {:ok, _} = Resolver.submit_resolution(market.id, :yes)
      {:ok, _} = Resolver.settle(market.id)

      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, "4" <> String.duplicate("A", 94))
      assert request.status == :pending

      # Tick — but Signer is halted, so request stays :pending.
      Signer.run_now()
      {:ok, refreshed} = Federation.Facade.get_request(request.id)
      assert refreshed.status == :pending
    end

    test "resume re-enables auto-signing" do
      capture_io(fn ->
        Console.halt()
        assert Federation.Facade.halted?()
        Console.resume()
        refute Federation.Facade.halted?()
      end)
    end
  end

  describe "Payout.mark_force_approved" do
    test "transitions :awaiting_operator → :rules_passed preserving rule_failure_reason" do
      pos = %PerpWalk.Markets.Position{
        id: "p1",
        market_id: "m1",
        account_id: "a1",
        side: :yes,
        contracts: 5,
        amount_paid: 5_000_000_000_000,
        spread_piconeros: 0,
        status: :settled_winner,
        created_at: DateTime.utc_now(),
        settled_at: DateTime.utc_now()
      }

      base = Payout.new(pos, 5_000_000_000_000, "dest")
      {:ok, awaiting} = Payout.mark_awaiting_operator(base, "rate_cap_global tripped")

      {:ok, forced} = Payout.mark_force_approved(awaiting)
      assert forced.status == :rules_passed
      assert forced.rule_failure_reason == "rate_cap_global tripped"
    end

    test "refuses for non-:awaiting_operator status" do
      pos = %PerpWalk.Markets.Position{
        id: "p1",
        market_id: "m1",
        account_id: "a1",
        side: :yes,
        contracts: 5,
        amount_paid: 5_000_000_000_000,
        spread_piconeros: 0,
        status: :settled_winner,
        created_at: DateTime.utc_now(),
        settled_at: DateTime.utc_now()
      }

      pending = Payout.new(pos, 5_000_000_000_000, "dest")
      assert {:error, :invalid_transition} = Payout.mark_force_approved(pending)
    end
  end

  describe "promote_processor/1 — WAL-recorded, fenced" do
    setup do
      :persistent_term.erase({PerpWalk.Federation.Store, :promotion})
      on_exit(fn -> :persistent_term.erase({PerpWalk.Federation.Store, :promotion}) end)
      :ok
    end

    test "commits a promotion to the WAL and updates persistent_term" do
      capture_io(fn ->
        assert :ok = Console.promote_processor(:p2)
      end)

      assert {[:p2], epoch} = FederationStore.lookup_processor_promotion()
      assert epoch >= 1
    end

    test "monotonic epoch prevents accidental re-promotion of a stale target" do
      capture_io(fn ->
        assert :ok = Console.promote_processor(:p2)
        assert :ok = Console.promote_processor(:p3)
      end)

      # A second call to :p2 gets a NEW higher epoch because
      # next_promotion_epoch/0 reads the current epoch fresh —
      # so operator racing themselves is safe, they just supersede
      # their own prior promotion.
      capture_io(fn ->
        assert :ok = Console.promote_processor(:p2)
      end)

      assert {[:p2], epoch} = FederationStore.lookup_processor_promotion()
      assert epoch >= 3
    end

    test "refuses invalid participant ids without touching WAL" do
      before = FederationStore.lookup_processor_promotion()

      capture_io(fn ->
        assert {:error, :invalid_target} = Console.promote_processor(:potato)
      end)

      assert FederationStore.lookup_processor_promotion() == before
    end
  end

  defp capture_io(fun), do: ExUnit.CaptureIO.capture_io(fun)
end
