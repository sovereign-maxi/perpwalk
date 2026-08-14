defmodule PerpWalkWeb.Live.HelpersTest do
  @moduledoc """
  Unit tests for `PerpWalkWeb.Live.Helpers`.

  Covers two contract groups:

    1. **XMR formatters** — `format_xmr/1` (money-display, exact precision)
       and `format_xmr_compact/1` (summary, truncated floor). The exact
       one must byte-for-byte match on-chain amounts; the compact one
       is opt-in for aggregate tiles and never overstates.
    2. **Pool helpers** — `pool_wagered_piconeros/1`,
       `pool_total_piconeros/2`, and `format_pool_total/2`. The total
       variant adds the creator's LP seed deposit on top of trader
       collateral so a user's max-payout sanity check (payout vs
       displayed pool) doesn't fail spuriously.
  """

  use ExUnit.Case, async: true

  alias PerpWalk.Markets.Position
  alias PerpWalkWeb.Live.Helpers

  # --- XMR formatters (formerly helpers_format_xmr_test.exs) ---

  describe "format_xmr/1 — exact precision" do
    test "renders an exact piconero amount without rounding" do
      # The bug this test exists to prevent: 619_980_000_000 piconeros
      # = 0.61998 XMR was being float-rounded to "0.620 XMR" while the
      # actual subaddress amount on the QR was 0.61998. The display
      # MUST match the on-chain amount byte-for-byte.
      assert Helpers.format_xmr(619_980_000_000) == "0.61998 XMR"
    end

    test "renders sub-piconero precision when present" do
      # 12_345_678_901 piconeros = 0.012345678901 XMR — no trailing
      # zeros to strip; full 12-digit precision survives.
      assert Helpers.format_xmr(12_345_678_901) == "0.012345678901 XMR"
    end

    test "renders 1 XMR exactly as 1.0 XMR" do
      assert Helpers.format_xmr(1_000_000_000_000) == "1.0 XMR"
    end

    test "renders 0 as 0.0 XMR" do
      assert Helpers.format_xmr(0) == "0.0 XMR"
    end

    test "renders 1 piconero (atomic) as 0.000000000001 XMR" do
      assert Helpers.format_xmr(1) == "0.000000000001 XMR"
    end

    test "strips trailing zeros from the fractional part" do
      # 500_000_000_000 piconeros = 0.5 XMR exactly. After stripping
      # the eleven trailing zeros from the 12-digit padded fractional,
      # the displayed precision is 1 decimal — not "0.500000000000".
      assert Helpers.format_xmr(500_000_000_000) == "0.5 XMR"
    end

    test "preserves precision for amounts >= 1 XMR" do
      # 1_500_000_000_000 = 1.5 XMR exact, not "1.5" with hidden float drift.
      assert Helpers.format_xmr(1_500_000_000_000) == "1.5 XMR"
      assert Helpers.format_xmr(1_234_567_890_123) == "1.234567890123 XMR"
    end

    test "preserves precision for large amounts that the compact formatter would 'k'-suffix" do
      # 1_000_000_000_000_000 = 1000 XMR — the exact formatter doesn't
      # k-suffix, so the display is the literal number.
      assert Helpers.format_xmr(1_000_000_000_000_000) == "1000.0 XMR"
    end

    test "raises on negative input" do
      assert_raise FunctionClauseError, fn -> Helpers.format_xmr(-1) end
    end

    test "raises on non-integer input" do
      assert_raise FunctionClauseError, fn -> Helpers.format_xmr(0.5) end
    end
  end

  describe "format_xmr_compact/1 — summary contexts" do
    test "delegates to format_xmr for sub-1000-XMR values" do
      # The whole point of the compact formatter now: same output as
      # format_xmr for any realistic aggregate, so a pool tile and a
      # cost cell displaying the same underlying value render
      # identically.
      assert Helpers.format_xmr_compact(520_200_000) == Helpers.format_xmr(520_200_000)
      assert Helpers.format_xmr_compact(10_520_200_000) == Helpers.format_xmr(10_520_200_000)
      assert Helpers.format_xmr_compact(619_980_000_000) == Helpers.format_xmr(619_980_000_000)
      assert Helpers.format_xmr_compact(1_590_000_000_000) == Helpers.format_xmr(1_590_000_000_000)
    end

    test "strips trailing .0 XMR for whole-XMR aggregates" do
      # format_xmr emits `1.0 XMR` / `500.0 XMR` to preserve the
      # currency decimal marker on exact surfaces; the compact
      # formatter strips it so tile widths stay lean.
      assert Helpers.format_xmr_compact(1_000_000_000_000) == "1 XMR"
      assert Helpers.format_xmr_compact(500_000_000_000_000) == "500 XMR"
    end

    test "half XMR shows as 0.5 XMR (no trailing zeros)" do
      assert Helpers.format_xmr_compact(500_000_000_000) == "0.5 XMR"
    end

    test "uses a k suffix at >= 1000 XMR" do
      assert Helpers.format_xmr_compact(1_000_000_000_000_000) == "1k XMR"
      assert Helpers.format_xmr_compact(1_500_000_000_000_000) == "1.5k XMR"
      assert Helpers.format_xmr_compact(12_500_000_000_000_000) == "12.5k XMR"
    end

    test "handles 0 cleanly" do
      assert Helpers.format_xmr_compact(0) == "0 XMR"
    end

    test "single-trade pool + volume reconcile digit-for-digit" do
      # Regression from the operator's live market: a pool at
      # 0.0105202 XMR (creator's 0.01 XMR seed + one trade at
      # 0.0005202 XMR) should read at the same precision as the
      # cost of that same trade in the positions table.
      assert Helpers.format_xmr_compact(10_520_200_000) == "0.0105202 XMR"
      assert Helpers.format_xmr_compact(520_200_000) == "0.0005202 XMR"
    end
  end

  # --- Pool helpers (formerly helpers_pool_total_test.exs) ---

  defp position(amount_paid) do
    %Position{
      id: "p-#{System.unique_integer([:positive])}",
      market_id: "m1",
      account_id: "alice",
      side: :yes,
      contracts: 1,
      amount_paid: amount_paid,
      spread_piconeros: 0,
      status: :open,
      created_at: DateTime.utc_now()
    }
  end

  describe "pool_wagered_piconeros/1" do
    test "sums position amount_paid across the list" do
      positions = [position(500_000_000_000), position(300_000_000_000)]
      assert Helpers.pool_wagered_piconeros(positions) == 800_000_000_000
    end

    test "empty list is 0" do
      assert Helpers.pool_wagered_piconeros([]) == 0
    end
  end

  describe "pool_total_piconeros/2" do
    test "adds the creator deposit on top of trader wagered" do
      # Operator's example: 99 YES @ 0.61998 + 150 NO @ 0.6762 = 1.296 XMR
      # wagered. Creator deposit 1.0 XMR. Total = 2.296 XMR.
      positions = [position(619_980_000_000), position(676_200_000_000)]
      deposit = 1_000_000_000_000

      assert Helpers.pool_total_piconeros(positions, deposit) ==
               619_980_000_000 + 676_200_000_000 + 1_000_000_000_000
    end

    test "with no trades, returns the deposit alone" do
      assert Helpers.pool_total_piconeros([], 1_000_000_000_000) == 1_000_000_000_000
    end

    test "format_pool_total/2 renders the combined figure" do
      # 1.296180 XMR wagered + 1.0 XMR deposit = 2.296180 XMR.
      # Compact delegates to format_xmr, so the full precision comes
      # through — same digits as a trade cell rendering the same
      # value elsewhere on the page.
      positions = [position(619_980_000_000), position(676_200_000_000)]
      deposit = 1_000_000_000_000

      assert Helpers.format_pool_total(positions, deposit) == "2.29618 XMR"
    end

    test "covers the operator's specific sanity-check failure mode" do
      # The case from the original bug report: pool shown as 1.3 XMR
      # while user's max NO payout is 1.5 XMR. With the fix, pool
      # reads 2.3 XMR which comfortably covers the 1.5 max payout.
      positions = [position(619_980_000_000), position(676_200_000_000)]
      deposit = 1_000_000_000_000

      pool_total = Helpers.pool_total_piconeros(positions, deposit)
      max_no_payout = 150 * 10_000_000_000

      assert pool_total > max_no_payout
    end
  end
end
