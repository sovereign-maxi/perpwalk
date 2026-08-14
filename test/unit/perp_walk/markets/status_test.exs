defmodule PerpWalk.Markets.StatusTest do
  @moduledoc """
  Predicate truth tables for `PerpWalk.Markets.Status`. Run each
  predicate against the full set of status atoms so adding a new
  state to the state machine surfaces here with a clear failure.
  """

  use ExUnit.Case, async: true

  alias PerpWalk.Markets.Status

  @all_statuses [
    :awaiting_deposit,
    :pending,
    :active,
    :expired,
    :resolving,
    :settled,
    :voided,
    :rejected
  ]

  describe "trading?/1" do
    test "is true only for :active" do
      assert Status.trading?(:active)

      for status <- @all_statuses -- [:active] do
        refute Status.trading?(status), "expected #{status} not trading"
      end
    end
  end

  describe "listing_window?/1" do
    test "is true for :awaiting_deposit and :pending" do
      assert Status.listing_window?(:awaiting_deposit)
      assert Status.listing_window?(:pending)

      for status <- @all_statuses -- [:awaiting_deposit, :pending] do
        refute Status.listing_window?(status), "expected #{status} not in listing window"
      end
    end
  end

  describe "awaiting_creator_resolution?/1" do
    test "is true only for :expired" do
      assert Status.awaiting_creator_resolution?(:expired)

      for status <- @all_statuses -- [:expired] do
        refute Status.awaiting_creator_resolution?(status),
               "expected #{status} not awaiting creator resolution"
      end
    end
  end

  describe "in_dispute_window?/1" do
    test "is true only for :resolving" do
      assert Status.in_dispute_window?(:resolving)

      for status <- @all_statuses -- [:resolving] do
        refute Status.in_dispute_window?(status),
               "expected #{status} not in dispute window"
      end
    end
  end

  describe "awaiting_operator_action?/1" do
    test "is the union of :expired and :resolving" do
      assert Status.awaiting_operator_action?(:expired)
      assert Status.awaiting_operator_action?(:resolving)

      for status <- @all_statuses -- [:expired, :resolving] do
        refute Status.awaiting_operator_action?(status),
               "expected #{status} not awaiting operator action"
      end
    end
  end

  describe "terminal?/1" do
    test "is true for :settled, :voided, :rejected" do
      for status <- [:settled, :voided, :rejected] do
        assert Status.terminal?(status), "expected #{status} terminal"
      end

      for status <- [:awaiting_deposit, :pending, :active, :expired, :resolving] do
        refute Status.terminal?(status), "expected #{status} not terminal"
      end
    end
  end

  describe "in_flight?/1" do
    test "is true for every non-terminal status" do
      for status <- [:awaiting_deposit, :pending, :active, :expired, :resolving] do
        assert Status.in_flight?(status), "expected #{status} in flight"
      end

      for status <- [:settled, :voided, :rejected] do
        refute Status.in_flight?(status), "expected #{status} not in flight"
      end
    end
  end
end
