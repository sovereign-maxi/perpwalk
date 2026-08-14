defmodule PerpWalk.Events.DisplayTest do
  @moduledoc "Unit tests for the PerpWalk.Events.Display protocol on Markets events."

  use ExUnit.Case, async: true

  alias PerpWalk.Events.Display
  alias PerpWalk.Events.Markets

  @now ~U[2026-04-29 12:00:00Z]

  describe "MarketCreated" do
    setup do
      event = %Markets.MarketCreated{
        market_id: "mkt-1",
        description: "Will it rain on July 4?",
        category: :politics,
        creator_account_id: "acct-a",
        timestamp: @now
      }

      {:ok, event: event}
    end

    test("domain is Markets", %{event: event}, do: assert(Display.domain(event) == "Markets"))
    test("label", %{event: event}, do: assert(Display.label(event) == "Market Created"))
    test("severity is :info", %{event: event}, do: assert(Display.severity(event) == :info))

    test "detail includes id and category", %{event: event} do
      assert Display.detail(event) == "market_id=mkt-1 category=politics"
    end
  end

  describe "MarketActivated" do
    test "renders" do
      event = %Markets.MarketActivated{market_id: "mkt-2", timestamp: @now}
      assert Display.domain(event) == "Markets"
      assert Display.label(event) == "Market Activated"
      assert Display.severity(event) == :info
      assert Display.detail(event) == "market_id=mkt-2"
    end
  end

  describe "MarketRejected" do
    test "is :warning severity and includes reputation" do
      event = %Markets.MarketRejected{market_id: "mkt-3", reputation: -5, timestamp: @now}
      assert Display.severity(event) == :warning
      assert Display.label(event) == "Market Rejected"
      assert Display.detail(event) == "market_id=mkt-3 reputation=-5"
    end
  end

  describe "MarketExpired" do
    test "renders" do
      event = %Markets.MarketExpired{market_id: "mkt-4", timestamp: @now}
      assert Display.label(event) == "Market Expired"
      assert Display.severity(event) == :info
    end
  end

  describe "PositionOpened" do
    test "detail includes side, contracts, and amount" do
      event = %Markets.PositionOpened{
        position_id: "pos-1",
        market_id: "mkt-5",
        account_id: "acct-a",
        side: :yes,
        contracts: 10,
        amount_paid: 5_000,
        timestamp: @now
      }

      assert Display.label(event) == "Position Opened"
      assert Display.severity(event) == :info
      assert Display.detail(event) == "market_id=mkt-5 side=yes contracts=10 paid=5000"
    end
  end

  describe "PositionCancelled" do
    test "detail includes refund amount" do
      event = %Markets.PositionCancelled{
        position_id: "pos-2",
        market_id: "mkt-6",
        amount_refunded: 5_000,
        timestamp: @now
      }

      assert Display.label(event) == "Position Cancelled"
      assert Display.detail(event) == "position_id=pos-2 refunded=5000"
    end
  end

  describe "ResolutionSubmitted" do
    test "detail includes outcome" do
      event = %Markets.ResolutionSubmitted{
        market_id: "mkt-7",
        outcome: :yes,
        timestamp: @now
      }

      assert Display.severity(event) == :info
      assert Display.detail(event) == "market_id=mkt-7 outcome=yes"
    end
  end

  describe "ResolutionReversed" do
    test "is :warning and includes both outcomes" do
      event = %Markets.ResolutionReversed{
        market_id: "mkt-8",
        previous_outcome: :yes,
        new_outcome: :no,
        timestamp: @now
      }

      assert Display.severity(event) == :warning
      assert Display.detail(event) == "market_id=mkt-8 prev=yes new=no"
    end
  end

  describe "MarketSettled" do
    test "detail includes outcome" do
      event = %Markets.MarketSettled{
        market_id: "mkt-9",
        outcome: :no,
        resolved_at: @now,
        timestamp: @now
      }

      assert Display.label(event) == "Market Settled"
      assert Display.detail(event) == "market_id=mkt-9 outcome=no"
    end
  end

  describe "MarketVoided" do
    test "is :warning severity" do
      event = %Markets.MarketVoided{
        market_id: "mkt-10",
        resolved_at: @now,
        reason: :operator,
        timestamp: @now
      }

      assert Display.severity(event) == :warning
      assert Display.label(event) == "Market Voided"
      assert Display.detail(event) =~ "reason=operator"
    end

    test "carries the auto-void reason in the detail string" do
      event = %Markets.MarketVoided{
        market_id: "mkt-11",
        resolved_at: @now,
        reason: :creator_no_show,
        timestamp: @now
      }

      assert Display.detail(event) =~ "reason=creator_no_show"
    end
  end

  describe "DepositBurned" do
    test "is :warning and includes amount" do
      event = %Markets.DepositBurned{
        market_id: "mkt-11",
        amount: 500_000_000_000,
        timestamp: @now
      }

      assert Display.severity(event) == :warning
      assert Display.detail(event) == "market_id=mkt-11 amount=500000000000"
    end
  end

  describe "every Markets event implements Display" do
    test "covers the full catalog" do
      now = @now

      events = [
        %Markets.MarketCreated{
          market_id: "x",
          description: "x",
          category: :politics,
          creator_account_id: "x",
          timestamp: now
        },
        %Markets.MarketActivated{market_id: "x", timestamp: now},
        %Markets.MarketRejected{market_id: "x", reputation: 0, timestamp: now},
        %Markets.MarketExpired{market_id: "x", timestamp: now},
        %Markets.PositionOpened{
          position_id: "x",
          market_id: "x",
          account_id: "x",
          side: :yes,
          contracts: 1,
          amount_paid: 1,
          timestamp: now
        },
        %Markets.PositionCancelled{
          position_id: "x",
          market_id: "x",
          amount_refunded: 1,
          timestamp: now
        },
        %Markets.ResolutionSubmitted{market_id: "x", outcome: :yes, timestamp: now},
        %Markets.ResolutionReversed{
          market_id: "x",
          previous_outcome: :yes,
          new_outcome: :no,
          timestamp: now
        },
        %Markets.MarketSettled{
          market_id: "x",
          outcome: :yes,
          resolved_at: now,
          timestamp: now
        },
        %Markets.MarketVoided{market_id: "x", resolved_at: now, reason: :operator, timestamp: now},
        %Markets.DepositBurned{market_id: "x", amount: 1, timestamp: now}
      ]

      for event <- events do
        assert Display.domain(event) == "Markets"
        assert is_binary(Display.label(event))
        assert Display.severity(event) in [:info, :warning, :critical, :emergency]
        assert is_binary(Display.detail(event))
      end
    end
  end
end
