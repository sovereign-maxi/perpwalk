defmodule PerpWalk.Markets.QuoteTest do
  @moduledoc "Unit tests for PerpWalk.Markets.Quote."

  use ExUnit.Case, async: true

  alias PerpWalk.Markets.Quote

  @refund_address "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge"

  describe "new/1" do
    test "builds a quote with a generated id and created_at" do
      now = DateTime.utc_now()

      q =
        Quote.new(
          market_id: "m1",
          account_id: "a1",
          side: :yes,
          contracts: 5,
          amount_paid_piconeros: 50_000_000_000,
          spread_piconeros: 0,
          subaddress: "subaddr",
          subaddress_index: 7,
          refund_address: @refund_address,
          expires_at: DateTime.add(now, 1800, :second)
        )

      assert is_binary(q.id)
      assert byte_size(q.id) == 32
      assert q.market_id == "m1"
      assert q.account_id == "a1"
      assert q.side == :yes
      assert q.contracts == 5
      assert q.amount_paid_piconeros == 50_000_000_000
      assert q.subaddress == "subaddr"
      assert q.subaddress_index == 7
      assert %DateTime{} = q.created_at
      assert %DateTime{} = q.expires_at
    end

    test "raises on invalid side" do
      assert_raise ArgumentError, fn ->
        Quote.new(
          market_id: "m1",
          account_id: "a1",
          side: :maybe,
          contracts: 5,
          amount_paid_piconeros: 50_000_000_000,
          spread_piconeros: 0,
          subaddress: "subaddr",
          subaddress_index: 1,
          refund_address: @refund_address,
          expires_at: DateTime.utc_now()
        )
      end
    end

    test "raises on non-positive contracts" do
      assert_raise ArgumentError, fn ->
        Quote.new(
          market_id: "m1",
          account_id: "a1",
          side: :yes,
          contracts: 0,
          amount_paid_piconeros: 50_000_000_000,
          spread_piconeros: 0,
          subaddress: "subaddr",
          subaddress_index: 1,
          refund_address: @refund_address,
          expires_at: DateTime.utc_now()
        )
      end
    end

    test "raises on non-positive amount_paid_piconeros" do
      assert_raise ArgumentError, fn ->
        Quote.new(
          market_id: "m1",
          account_id: "a1",
          side: :yes,
          contracts: 5,
          amount_paid_piconeros: 0,
          spread_piconeros: 0,
          subaddress: "subaddr",
          subaddress_index: 1,
          refund_address: @refund_address,
          expires_at: DateTime.utc_now()
        )
      end
    end

    test "ids are unique across builds" do
      attrs = [
        market_id: "m1",
        account_id: "a1",
        side: :yes,
        contracts: 5,
        amount_paid_piconeros: 50_000_000_000,
        spread_piconeros: 0,
        subaddress: "subaddr",
        subaddress_index: 1,
        refund_address: @refund_address,
        expires_at: DateTime.utc_now()
      ]

      a = Quote.new(attrs)
      b = Quote.new(attrs)

      refute a.id == b.id
    end
  end

  describe "expired?/2" do
    test "false before expiry" do
      now = DateTime.utc_now()

      q =
        Quote.new(
          market_id: "m1",
          account_id: "a1",
          side: :yes,
          contracts: 5,
          amount_paid_piconeros: 50_000_000_000,
          spread_piconeros: 0,
          subaddress: "subaddr",
          subaddress_index: 1,
          refund_address: @refund_address,
          expires_at: DateTime.add(now, 60, :second)
        )

      refute Quote.expired?(q, now)
    end

    test "true at or past expiry" do
      now = DateTime.utc_now()
      expires_at = DateTime.add(now, -1, :second)

      q =
        Quote.new(
          market_id: "m1",
          account_id: "a1",
          side: :yes,
          contracts: 5,
          amount_paid_piconeros: 50_000_000_000,
          spread_piconeros: 0,
          subaddress: "subaddr",
          subaddress_index: 1,
          refund_address: @refund_address,
          expires_at: expires_at
        )

      assert Quote.expired?(q, now)
    end
  end
end
