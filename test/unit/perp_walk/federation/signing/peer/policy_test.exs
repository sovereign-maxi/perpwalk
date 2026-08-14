defmodule PerpWalk.Federation.Signing.Peer.PolicyTest do
  @moduledoc "Unit tests for the per-peer signing policy gate."

  use ExUnit.Case, async: true

  alias PerpWalk.Federation.Signing.Peer.Policy

  @valid_address "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge"

  defp description(recipients) when is_list(recipients) do
    %{recipients: recipients, fee: 0, amount_in: 0, amount_out: 0, change_amount: 0, change_address: nil}
  end

  defp recipient(addr \\ @valid_address, amount), do: %{address: addr, amount: amount}

  describe "evaluate/1 destination_sanity" do
    test "accepts a well-formed Monero address" do
      assert :ok = Policy.evaluate(description([recipient(1_000_000)]))
    end

    test "rejects a non-string address" do
      assert {:reject, "destination_sanity:" <> _} =
               Policy.evaluate(description([%{address: 1234, amount: 1}]))
    end

    test "rejects an empty address" do
      assert {:reject, "destination_sanity:" <> _} =
               Policy.evaluate(description([recipient("", 1)]))
    end

    test "rejects an address that doesn't match the Monero regex" do
      assert {:reject, "destination_sanity:" <> _} =
               Policy.evaluate(description([recipient("bc1qxxxx", 1)]))
    end

    test "rejects an absurdly long address" do
      long = String.duplicate("4", 200)

      assert {:reject, "destination_sanity:" <> _} =
               Policy.evaluate(description([recipient(long, 1)]))
    end
  end

  describe "evaluate/1 per_recipient_cap" do
    test "accepts a recipient at exactly the cap (50 XMR default)" do
      assert :ok = Policy.evaluate(description([recipient(50 * 1_000_000_000_000)]))
    end

    test "rejects a recipient just over the cap" do
      assert {:reject, "per_recipient_cap:" <> _} =
               Policy.evaluate(description([recipient(50 * 1_000_000_000_000 + 1)]))
    end

    test "rejects on the first oversized recipient when there are multiple" do
      assert {:reject, "per_recipient_cap:" <> _} =
               Policy.evaluate(
                 description([
                   recipient(1_000_000),
                   recipient(60 * 1_000_000_000_000)
                 ])
               )
    end

    test "rejects a zero-amount recipient" do
      assert {:reject, "per_recipient_cap:" <> _} =
               Policy.evaluate(description([recipient(0)]))
    end

    test "rejects a non-integer amount" do
      assert {:reject, "per_recipient_cap:" <> _} =
               Policy.evaluate(description([%{address: @valid_address, amount: 1.5}]))
    end
  end

  describe "evaluate/1 total_outflow_cap" do
    test "rejects a multi-recipient batch totalling over the cap (100 XMR default)" do
      # Each recipient is under per-recipient cap (50 XMR) but sum exceeds total cap (100 XMR).
      assert {:reject, "total_outflow_cap:" <> _} =
               Policy.evaluate(
                 description([
                   recipient(40 * 1_000_000_000_000),
                   recipient(40 * 1_000_000_000_000),
                   recipient(40 * 1_000_000_000_000)
                 ])
               )
    end

    test "accepts a batch totalling exactly the cap" do
      assert :ok =
               Policy.evaluate(
                 description([
                   recipient(50 * 1_000_000_000_000),
                   recipient(50 * 1_000_000_000_000)
                 ])
               )
    end
  end

  describe "evaluate/1 malformed input" do
    test "rejects when recipients is missing" do
      assert {:reject, _} = Policy.evaluate(%{fee: 0})
    end

    test "rejects when recipients is not a list" do
      assert {:reject, _} = Policy.evaluate(%{recipients: "not-a-list", fee: 0})
    end

    test "rejects an empty recipients list" do
      assert {:reject, "no_recipients:" <> _} = Policy.evaluate(description([]))
    end
  end

  describe "evaluate/1 honours config overrides" do
    setup do
      original = Application.get_env(:perpwalk, :peer_signing_policy)

      on_exit(fn ->
        if original do
          Application.put_env(:perpwalk, :peer_signing_policy, original)
        else
          Application.delete_env(:perpwalk, :peer_signing_policy)
        end
      end)
    end

    test "accepts a high amount when caps are raised" do
      Application.put_env(:perpwalk, :peer_signing_policy,
        max_recipient_piconeros: 1_000 * 1_000_000_000_000,
        max_total_piconeros: 1_000 * 1_000_000_000_000
      )

      assert :ok = Policy.evaluate(description([recipient(500 * 1_000_000_000_000)]))
    end

    test "rejects an amount within default cap when configured cap is lower" do
      Application.put_env(:perpwalk, :peer_signing_policy,
        max_recipient_piconeros: 1_000_000,
        max_total_piconeros: 1_000_000
      )

      assert {:reject, "per_recipient_cap:" <> _} =
               Policy.evaluate(description([recipient(2_000_000)]))
    end
  end

  describe "evaluate/1 multi-tx txset refusal" do
    test "accepts a singleton list" do
      assert :ok = Policy.evaluate([description([recipient(1_000_000)])])
    end

    test "refuses a list with more than one transaction" do
      # This venue builds one-payment-per-round; a `transfer_split`
      # producing two transactions is a compromised-builder signal.
      # The previous code only saw desc[0] and would have signed the
      # entire set.
      assert {:reject, "multi_tx_txset:" <> _} =
               Policy.evaluate([
                 description([recipient(1_000_000)]),
                 description([recipient(10 * 1_000_000_000_000)])
               ])
    end

    test "refuses an empty list" do
      assert {:reject, "empty_txset:" <> _} = Policy.evaluate([])
    end
  end

  describe "evaluate/1 change_sanity" do
    test "accepts nil change address" do
      desc = description([recipient(1_000)]) |> Map.put(:change_address, nil)
      assert :ok = Policy.evaluate(desc)
    end

    test "refuses a malformed change address" do
      desc = description([recipient(1_000)]) |> Map.put(:change_address, "bc1qxxxx")
      assert {:reject, "change_sanity:" <> _} = Policy.evaluate(desc)
    end

    test "accepts a well-formed change address pre-bootstrap (no multisig_address configured)" do
      # Pre-bootstrap: :multisig_address is unset. Well-formedness
      # is enforced but the equality gate is deferred (the sign
      # path is refused elsewhere in that phase).
      previous = Application.get_env(:perpwalk, :multisig_address)
      Application.delete_env(:perpwalk, :multisig_address)
      on_exit(fn -> if previous, do: Application.put_env(:perpwalk, :multisig_address, previous) end)

      desc = description([recipient(1_000)]) |> Map.put(:change_address, @valid_address)
      assert :ok = Policy.evaluate(desc)
    end

    test "accepts change_address that equals the venue multisig_address" do
      previous = Application.get_env(:perpwalk, :multisig_address)
      Application.put_env(:perpwalk, :multisig_address, @valid_address)
      on_exit(fn -> restore_multisig_address(previous) end)

      desc = description([recipient(1_000)]) |> Map.put(:change_address, @valid_address)
      assert :ok = Policy.evaluate(desc)
    end

    test "refuses change_address that does not equal the venue multisig_address" do
      # A hand-crafted txset could smuggle change to
      # an attacker's own well-formed address while paying a
      # legitimate destination that matches a :rules_passed payout
      # (bypassing C2). Change must return to the venue.
      previous = Application.get_env(:perpwalk, :multisig_address)
      other_address = "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"
      Application.put_env(:perpwalk, :multisig_address, other_address)
      on_exit(fn -> restore_multisig_address(previous) end)

      # @valid_address is well-formed but NOT the configured venue address.
      desc = description([recipient(1_000)]) |> Map.put(:change_address, @valid_address)
      assert {:reject, "change_sanity:" <> reason} = Policy.evaluate(desc)
      assert reason =~ "not the venue multisig address"
    end
  end

  defp restore_multisig_address(nil), do: Application.delete_env(:perpwalk, :multisig_address)
  defp restore_multisig_address(v), do: Application.put_env(:perpwalk, :multisig_address, v)

  describe "evaluate/1 unlock_time_zero" do
    test "accepts unlock_time = 0 (default spendable)" do
      desc = description([recipient(1_000)]) |> Map.put(:unlock_time, 0)
      assert :ok = Policy.evaluate(desc)
    end

    test "refuses a locked payout (unlock_time > 0)" do
      desc = description([recipient(1_000)]) |> Map.put(:unlock_time, 1_000_000)

      assert {:reject, "unlock_time_nonzero:" <> _} = Policy.evaluate(desc)
    end
  end
end
