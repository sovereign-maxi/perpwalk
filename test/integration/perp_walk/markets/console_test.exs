defmodule PerpWalk.Markets.ConsoleIntegrationTest do
  @moduledoc """
  Behavioural tests for `PerpWalk.Markets.Console`. Exercises the
  state-machine paths (submit_resolution, acknowledge_disputes,
  reverse_resolution, settle, void) without scraping the printed
  chrome — printed strings are operator-facing, not load-bearing.

  Settlement and void prompt for confirmation via `IO.gets`; we
  feed responses through `capture_io/2`'s `:input` option.
  """

  use PerpWalk.IntegrationCase

  import ExUnit.CaptureIO

  import PerpWalk.TestHelpers.MarketsHelpers,
    only: [dispute!: 2, pending_market!: 1]

  alias PerpWalk.Markets.{Console, Facade, Moderation}
  alias PerpWalk.Markets.Services.{Resolver, Trader}

  # Disputer requires the disputer to have traded; seed 1-contract
  # YES positions for each voter account this file uses so dispute
  # flows pass the precondition.
  @default_traders ~w(v-1 v-2 v-3 v-4 v-5 v-6 v-7 v-8 v-9 v-10)

  defp resolving_market!(opts \\ []) do
    market = pending_market!(opts)
    {:ok, _} = Resolver.activate(market.id)
    traders = Keyword.get(opts, :traders, @default_traders)
    Enum.each(traders, &({:ok, _} = Trader.place_position(&1, market.id, :yes, 1)))
    {:ok, _} = Resolver.expire(market.id)
    {:ok, m} = Resolver.submit_resolution(market.id, :yes)
    m
  end

  describe "queue/0" do
    test "prints empty notice when nothing needs attention" do
      output = capture_io(fn -> assert :ok = Console.queue() end)
      assert output =~ "No markets pending"
    end

    test "groups markets by relevant lifecycle status" do
      _pending = pending_market!([])
      m = resolving_market!()

      output = capture_io(fn -> assert :ok = Console.queue() end)

      assert output =~ "RESOLVING"
      assert output =~ "PENDING"
      assert output =~ String.slice(m.id, 0, 8)
    end
  end

  describe "review/1" do
    test "prints market detail and returns the struct" do
      m = resolving_market!()

      output =
        capture_io(fn ->
          assert returned = Console.review(m.id)
          assert returned.id == m.id
        end)

      assert output =~ "Market #{String.slice(m.id, 0, 8)}"
      assert output =~ "status:"
      assert output =~ "disputes:"
      assert output =~ "settle_blocked:"
    end

    test "returns {:error, :not_found} for unknown id" do
      capture_io(fn ->
        assert {:error, :not_found} = Console.review("nonexistent")
      end)
    end
  end

  describe "submit_resolution/2" do
    test "transitions :expired → :resolving" do
      market = pending_market!([])
      {:ok, _} = Resolver.activate(market.id)
      {:ok, _} = Resolver.expire(market.id)

      capture_io(fn ->
        assert {:ok, updated} = Console.submit_resolution(market.id, :yes)
        assert updated.status == :resolving
        assert updated.outcome == :yes
      end)
    end

    test "refuses outside :expired" do
      market = pending_market!([])

      capture_io(fn ->
        assert {:error, :invalid_transition} = Console.submit_resolution(market.id, :yes)
      end)
    end
  end

  describe "acknowledge_disputes/1" do
    test "clears the settle gate after threshold disputes" do
      m = resolving_market!()
      threshold = Moderation.default_dispute_threshold()
      Enum.each(1..threshold, fn i -> _ = dispute!("v-#{i}", m.id) end)

      capture_io(fn ->
        assert {:ok, ack} = Console.acknowledge_disputes(m.id)
        assert ack.disputes_acknowledged_count == threshold
      end)
    end

    test "refuses on non-resolving market" do
      market = pending_market!([])

      capture_io(fn ->
        assert {:error, :market_not_resolving} = Console.acknowledge_disputes(market.id)
      end)
    end
  end

  describe "reverse_resolution/2" do
    test "flips outcome and implicitly acknowledges disputes" do
      m = resolving_market!()
      threshold = Moderation.default_dispute_threshold()
      Enum.each(1..threshold, fn i -> _ = dispute!("v-#{i}", m.id) end)

      capture_io(fn ->
        assert {:ok, reversed} = Console.reverse_resolution(m.id, :no)
        assert reversed.outcome == :no
        assert reversed.disputes_acknowledged_count == threshold
      end)
    end

    test "{:error, :not_found} for unknown id" do
      capture_io(fn ->
        assert {:error, :not_found} = Console.reverse_resolution("nonexistent", :no)
      end)
    end
  end

  describe "settle/1" do
    test "applies on confirmation" do
      m = resolving_market!()

      capture_io([input: "yes\n"], fn ->
        assert {:ok, settled} = Console.settle(m.id)
        assert settled.status == :settled
      end)
    end

    test "cancels on negative confirmation" do
      m = resolving_market!()

      capture_io([input: "no\n"], fn ->
        assert {:error, :cancelled} = Console.settle(m.id)
      end)

      {:ok, after_attempt} = Facade.get_market(m.id)
      assert after_attempt.status == :resolving
    end

    test "blocks on unacknowledged disputes past threshold" do
      m = resolving_market!()
      threshold = Moderation.default_dispute_threshold()
      Enum.each(1..threshold, fn i -> _ = dispute!("v-#{i}", m.id) end)

      output =
        capture_io([input: "yes\n"], fn ->
          assert {:error, :unacknowledged_disputes} = Console.settle(m.id)
        end)

      assert output =~ "Settle is blocked"
    end
  end

  describe "void/1" do
    test "applies on confirmation" do
      m = resolving_market!()

      capture_io([input: "yes\n"], fn ->
        assert {:ok, voided} = Console.void(m.id)
        assert voided.status == :voided
      end)
    end

    test "cancels on negative confirmation" do
      m = resolving_market!()

      capture_io([input: "n\n"], fn ->
        assert {:error, :cancelled} = Console.void(m.id)
      end)

      {:ok, after_attempt} = Facade.get_market(m.id)
      assert after_attempt.status == :resolving
    end
  end
end
