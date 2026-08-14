defmodule PerpWalk.Sim.SubaddressesTest do
  @moduledoc "Unit tests for the sim subaddress provider."

  use ExUnit.Case, async: false

  alias PerpWalk.Sim.Subaddresses

  @xmr_re ~r/^[48][1-9A-HJ-NP-Za-km-z]{94,105}$/

  setup do
    Subaddresses.reset()
    :ok
  end

  test "next/0 returns address matching the Monero subaddress regex" do
    {:ok, %{address: addr, address_index: idx}} = Subaddresses.next()
    assert is_integer(idx) and idx > 0
    assert Regex.match?(@xmr_re, addr)
  end

  test "indices are monotonic across calls" do
    {:ok, %{address_index: i1}} = Subaddresses.next()
    {:ok, %{address_index: i2}} = Subaddresses.next()
    {:ok, %{address_index: i3}} = Subaddresses.next()

    assert i2 == i1 + 1
    assert i3 == i2 + 1
  end

  test "addresses are unique across many calls" do
    addresses =
      for _ <- 1..200 do
        {:ok, %{address: a}} = Subaddresses.next()
        a
      end

    assert length(Enum.uniq(addresses)) == 200
  end

  test "reset/0 puts the counter back to zero" do
    Enum.each(1..50, fn _ -> Subaddresses.next() end)
    Subaddresses.reset()
    {:ok, %{address_index: idx}} = Subaddresses.next()
    assert idx == 1
  end

  test "address generation is deterministic given the same index" do
    {:ok, %{address: a}} = Subaddresses.next()
    Subaddresses.reset()
    {:ok, %{address: b}} = Subaddresses.next()

    assert a == b
  end

  test "addresses pass Federation.Rules.destination_sanity" do
    payout = fn dest ->
      %PerpWalk.Federation.Payout{
        id: "test",
        market_id: "test",
        account_id: "test",
        kind: :winner_payout,
        amount_piconeros: 1,
        destination: dest,
        status: :pending,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    end

    Enum.each(1..20, fn _ ->
      {:ok, %{address: addr}} = Subaddresses.next()
      assert PerpWalk.Federation.Rules.destination_sanity(%{request: payout.(addr)}) == :ok
    end)
  end
end
