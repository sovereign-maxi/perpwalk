defmodule PerpWalk.Federation.PayoutRequestTest do
  @moduledoc "Unit tests for PerpWalk.Federation.Payout state transitions."

  use ExUnit.Case, async: true

  alias PerpWalk.Federation.Payout
  alias PerpWalk.Markets.Position

  defp build_position(status) do
    %Position{
      id: "p1",
      market_id: "m1",
      account_id: "acct",
      side: :yes,
      contracts: 5,
      amount_paid: 50_000_000_000,
      spread_piconeros: 0,
      status: status,
      created_at: DateTime.utc_now(),
      settled_at: DateTime.utc_now()
    }
  end

  describe "new/3" do
    test "builds a winner_payout request from a :settled_winner position" do
      pos = build_position(:settled_winner)

      req = Payout.new(pos, 50_000_000_000, "destination-addr")

      assert is_binary(req.id)
      assert byte_size(req.id) == 32
      assert req.position_id == pos.id
      assert req.market_id == pos.market_id
      assert req.account_id == pos.account_id
      assert req.kind == :winner_payout
      assert req.amount_piconeros == 50_000_000_000
      assert req.destination == "destination-addr"
      assert req.status == :pending
      assert %DateTime{} = req.created_at
      assert %DateTime{} = req.updated_at
    end

    test "builds a refund request from a :refunded position" do
      pos = build_position(:refunded)

      req = Payout.new(pos, 50_000_000_000, "dest")

      assert req.kind == :refund
    end

    test "raises on an :open position" do
      pos = build_position(:open)

      assert_raise ArgumentError, fn ->
        Payout.new(pos, 50_000_000_000, "dest")
      end
    end

    test "raises on a :settled_loser position" do
      pos = build_position(:settled_loser)

      assert_raise ArgumentError, fn ->
        Payout.new(pos, 50_000_000_000, "dest")
      end
    end

    test "ids are unique across calls" do
      pos = build_position(:settled_winner)

      a = Payout.new(pos, 1_000, "dest-a")
      b = Payout.new(pos, 1_000, "dest-b")

      refute a.id == b.id
    end
  end

  describe "state machine" do
    setup do
      pos = build_position(:settled_winner)
      req = Payout.new(pos, 50_000_000_000, "dest")
      {:ok, req: req}
    end

    test "pending → rules_passed", %{req: req} do
      {:ok, updated} = Payout.mark_rules_passed(req)
      assert updated.status == :rules_passed
    end

    test "pending → awaiting_operator with reason", %{req: req} do
      {:ok, updated} = Payout.mark_awaiting_operator(req, "rate cap")
      assert updated.status == :awaiting_operator
      assert updated.rule_failure_reason == "rate cap"
    end

    test "rules_passed → signing", %{req: req} do
      {:ok, cleared} = Payout.mark_rules_passed(req)
      {:ok, signing} = Payout.mark_signing(cleared)
      assert signing.status == :signing
    end

    test "awaiting_operator → signing is rejected — must go via mark_force_approved first", %{req: req} do
      {:ok, awaiting} = Payout.mark_awaiting_operator(req, "rule")
      assert {:error, :invalid_transition} = Payout.mark_signing(awaiting)

      # The proper path: force-approve resets to :rules_passed so the
      # Signer's rule-revalidation runs, then mark_signing.
      {:ok, cleared} = Payout.mark_force_approved(awaiting)
      {:ok, signing} = Payout.mark_signing(cleared)
      assert signing.status == :signing
    end

    test "signing → submitted with txid", %{req: req} do
      {:ok, cleared} = Payout.mark_rules_passed(req)
      {:ok, signing} = Payout.mark_signing(cleared)
      {:ok, submitted} = Payout.mark_submitted(signing, "tx-abc")

      assert submitted.status == :submitted
      assert submitted.payout_txid == "tx-abc"
    end

    test "submitted → paid_out (terminal)", %{req: req} do
      {:ok, cleared} = Payout.mark_rules_passed(req)
      {:ok, signing} = Payout.mark_signing(cleared)
      {:ok, submitted} = Payout.mark_submitted(signing, "tx")
      {:ok, paid} = Payout.mark_paid_out(submitted)

      assert paid.status == :paid_out
    end

    test "pre-broadcast in-flight state → failed (terminal)", %{req: req} do
      {:ok, failed} = Payout.mark_failed(req, "operator halt")
      assert failed.status == :failed
      assert failed.rule_failure_reason == "operator halt"

      # :rules_passed → :failed allowed (Signer's rules-revalidation path).
      {:ok, cleared} = Payout.mark_rules_passed(req)
      assert {:ok, %{status: :failed}} = Payout.mark_failed(cleared, "revalidation")

      # :awaiting_operator → :failed allowed (operator abandons the request).
      {:ok, awaiting} = Payout.mark_awaiting_operator(req, "rule")
      assert {:ok, %{status: :failed}} = Payout.mark_failed(awaiting, "op-abort")

      # :signing → :failed allowed (crash mid-round pre-broadcast).
      {:ok, signing} = Payout.mark_signing(cleared)
      assert {:ok, %{status: :failed}} = Payout.mark_failed(signing, "op-abort")
    end

    test "post-broadcast states refuse mark_failed", %{req: req} do
      # :submitted → :failed would clear the broadcast marker AND
      # leave the source claimable — the next claim would build a
      # fresh tx and pay the same recipient twice. Operator must NOT
      # naively abort a broadcast payout; use a distinct source-side
      # reversal flow instead.
      {:ok, cleared} = Payout.mark_rules_passed(req)
      {:ok, signing} = Payout.mark_signing(cleared)
      {:ok, submitted} = Payout.mark_submitted(signing, "tx-broadcast")

      assert {:error, :invalid_transition} =
               Payout.mark_failed(submitted, "operator abort — must refuse")

      # :paid_out → :failed is refused (unchanged from the earlier
      # invariant: tx is confirmed AND bookkeeping done).
      {:ok, paid} = Payout.mark_paid_out(submitted)

      assert {:error, :invalid_transition} = Payout.mark_failed(paid, "should refuse")

      # :settlement_unknown → :failed is refused too — operator must
      # go through mark_reconciled_failed/2 (explicit wallet-side
      # verification) rather than blind abort.
      {:ok, unknown} = Payout.mark_settlement_unknown(cleared, "submit_ambiguous: :timeout")
      assert {:error, :invalid_transition} = Payout.mark_failed(unknown, "op-abort")
    end

    test "rejects invalid transitions", %{req: req} do
      # pending → signing skips rules_passed
      assert {:error, :invalid_transition} = Payout.mark_signing(req)
      # pending → submitted skips signing
      assert {:error, :invalid_transition} = Payout.mark_submitted(req, "tx")
      # pending → paid_out skips everything
      assert {:error, :invalid_transition} = Payout.mark_paid_out(req)
    end
  end

  describe "in_flight?/1" do
    test "true for non-terminal statuses" do
      pos = build_position(:settled_winner)
      base = Payout.new(pos, 1_000, "dest")

      assert Payout.in_flight?(base)
      assert Payout.in_flight?(%{base | status: :rules_passed})
      assert Payout.in_flight?(%{base | status: :signing})
      assert Payout.in_flight?(%{base | status: :awaiting_operator})
      # `:submitted` is in-flight too — the on-chain tx has been
      # broadcast but the position hasn't transitioned to
      # :paid_out yet, so a second claim must still be blocked.
      assert Payout.in_flight?(%{base | status: :submitted})
      # `:settlement_unknown` is in-flight — the tx may or may not
      # be on-chain, but funds are potentially committed either way
      # so a second claim against the same source must still block.
      assert Payout.in_flight?(%{base | status: :settlement_unknown})
    end

    test "false for terminal statuses" do
      pos = build_position(:settled_winner)
      base = Payout.new(pos, 1_000, "dest")

      refute Payout.in_flight?(%{base | status: :paid_out})
      refute Payout.in_flight?(%{base | status: :failed})
    end
  end

  describe "mark_settlement_unknown/2" do
    setup do
      pos = build_position(:settled_winner)
      {:ok, req: Payout.new(pos, 50_000_000_000, "dest")}
    end

    test "rules_passed → settlement_unknown pins operator-review reason", %{req: req} do
      {:ok, cleared} = Payout.mark_rules_passed(req)
      {:ok, unknown} = Payout.mark_settlement_unknown(cleared, "submit_ambiguous: :timeout")

      assert unknown.status == :settlement_unknown
      assert unknown.rule_failure_reason == "submit_ambiguous: :timeout"
      # No txid pinned — we deliberately don't know it here.
      assert unknown.payout_txid == nil
    end

    test "signing → settlement_unknown is allowed", %{req: req} do
      {:ok, cleared} = Payout.mark_rules_passed(req)
      {:ok, signing} = Payout.mark_signing(cleared)
      {:ok, unknown} = Payout.mark_settlement_unknown(signing, "submit_ambiguous: {:http_error, 502}")

      assert unknown.status == :settlement_unknown
    end

    test "refuses transition from pending / awaiting_operator / submitted / paid_out / failed", %{req: req} do
      assert {:error, :invalid_transition} = Payout.mark_settlement_unknown(req, "any")

      {:ok, awaiting} = Payout.mark_awaiting_operator(req, "rule")
      assert {:error, :invalid_transition} = Payout.mark_settlement_unknown(awaiting, "any")

      {:ok, cleared} = Payout.mark_rules_passed(req)
      {:ok, signing} = Payout.mark_signing(cleared)
      {:ok, submitted} = Payout.mark_submitted(signing, "tx")
      assert {:error, :invalid_transition} = Payout.mark_settlement_unknown(submitted, "any")

      {:ok, paid} = Payout.mark_paid_out(submitted)
      assert {:error, :invalid_transition} = Payout.mark_settlement_unknown(paid, "any")

      {:ok, failed} = Payout.mark_failed(req, "op-abort")
      assert {:error, :invalid_transition} = Payout.mark_settlement_unknown(failed, "any")
    end
  end

  describe "mark_reconciled_paid_out/2 and mark_reconciled_failed/2" do
    setup do
      pos = build_position(:settled_winner)
      base = Payout.new(pos, 50_000_000_000, "dest")
      {:ok, cleared} = Payout.mark_rules_passed(base)
      {:ok, unknown} = Payout.mark_settlement_unknown(cleared, "submit_ambiguous: :timeout")
      {:ok, unknown: unknown, base: base}
    end

    test "settlement_unknown → paid_out with recovered txid", %{unknown: unknown} do
      {:ok, paid} = Payout.mark_reconciled_paid_out(unknown, "recovered-txid-abc")

      assert paid.status == :paid_out
      assert paid.payout_txid == "recovered-txid-abc"
    end

    test "settlement_unknown → failed with operator reason", %{unknown: unknown} do
      {:ok, failed} = Payout.mark_reconciled_failed(unknown, "no_matching_transfer")

      assert failed.status == :failed
      assert failed.rule_failure_reason == "no_matching_transfer"
    end

    test "reconciled_paid_out refuses non-:settlement_unknown statuses", %{base: base} do
      assert {:error, :invalid_transition} = Payout.mark_reconciled_paid_out(base, "txid")

      {:ok, cleared} = Payout.mark_rules_passed(base)
      assert {:error, :invalid_transition} = Payout.mark_reconciled_paid_out(cleared, "txid")

      {:ok, signing} = Payout.mark_signing(cleared)
      {:ok, submitted} = Payout.mark_submitted(signing, "tx")
      assert {:error, :invalid_transition} = Payout.mark_reconciled_paid_out(submitted, "txid")
    end

    test "reconciled_failed refuses non-:settlement_unknown statuses", %{base: base} do
      assert {:error, :invalid_transition} = Payout.mark_reconciled_failed(base, "reason")

      {:ok, cleared} = Payout.mark_rules_passed(base)
      assert {:error, :invalid_transition} = Payout.mark_reconciled_failed(cleared, "reason")
    end

    test "reconciled_paid_out refuses empty txid", %{unknown: unknown} do
      assert {:error, :invalid_transition} = Payout.mark_reconciled_paid_out(unknown, "")
    end
  end

  describe "new_quote_underpayment_refund/5" do
    test "builds a :quote_underpayment_refund payout with the source quote id" do
      req =
        Payout.new_quote_underpayment_refund(
          "q-abc",
          "acct-1",
          "m-1",
          40_000_000_000,
          "refund-addr"
        )

      assert is_binary(req.id)
      assert req.kind == :quote_underpayment_refund
      assert req.source_quote_id == "q-abc"
      assert req.account_id == "acct-1"
      assert req.market_id == "m-1"
      assert req.amount_piconeros == 40_000_000_000
      assert req.destination == "refund-addr"
      assert req.position_id == nil
      assert req.status == :pending
      assert Payout.quote_underpayment_refund?(req)
      refute Payout.dispute_refund?(req)
      refute Payout.creator_lp_return?(req)
    end

    test "raises when the source quote id is empty" do
      assert_raise FunctionClauseError, fn ->
        Payout.new_quote_underpayment_refund("", "acct", "m", 1_000, "dest")
      end
    end

    test "raises when the amount is not positive" do
      assert_raise FunctionClauseError, fn ->
        Payout.new_quote_underpayment_refund("q", "acct", "m", 0, "dest")
      end
    end

    test "raises when the destination is empty" do
      assert_raise FunctionClauseError, fn ->
        Payout.new_quote_underpayment_refund("q", "acct", "m", 1_000, "")
      end
    end
  end
end
