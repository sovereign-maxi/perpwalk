defmodule PerpWalk.Federation.FacadeIntegrationTest do
  @moduledoc """
  Integration tests for `Federation.Facade` runtime-status wrappers.

  Same convention as `Telemetry.FacadeTest` — these run against
  the application-supervised runtime (`async: false`) but test
  the Facade's crash-safe wrappers in isolation, not multi-
  component flows. The point is: callers don't need their own
  try/rescue when calling these.
  """

  use PerpWalk.IntegrationCase

  alias PerpWalk.Federation.{Facade, Payout, Signer, Store}

  describe "runtime status helpers" do
    test "quorum?/0 is true in single-node config" do
      assert Facade.quorum?()
    end

    test "member_count/0 reflects Cartel's :n configured value" do
      assert Facade.member_count() == 1
    end

    test "threshold/0 reflects Cartel's :t configured value" do
      assert Facade.threshold() == 1
    end

    test "online_peer_count/0 returns 0 in single-node mode" do
      assert Facade.online_peer_count() == 0
    end
  end

  describe "halted?/0" do
    setup do
      if Signer.halted?(), do: Signer.resume()
      on_exit(fn -> if Signer.halted?(), do: Signer.resume() end)
      :ok
    end

    test "reflects Signer halt state" do
      refute Facade.halted?()

      :ok = Signer.halt()
      assert Facade.halted?()

      :ok = Signer.resume()
      refute Facade.halted?()
    end
  end

  describe "enqueue_quote_underpayment_refund/5" do
    setup do
      :ok = Store.clear()
      :ok
    end

    test "persists a :quote_underpayment_refund payout keyed on source_quote_id" do
      valid_destination =
        "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge"

      assert {:ok, payout} =
               Facade.enqueue_quote_underpayment_refund(
                 "q-1",
                 "acct-1",
                 "market-1",
                 40_000_000_000,
                 valid_destination
               )

      assert payout.kind == :quote_underpayment_refund
      assert payout.source_quote_id == "q-1"
      assert payout.status == :pending
      assert {:ok, ^payout} = Store.get_payout(payout.id)
    end

    test "second enqueue for the same source_quote_id is refused while first is in flight" do
      valid_destination =
        "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge"

      {:ok, _first} =
        Facade.enqueue_quote_underpayment_refund(
          "q-dup",
          "acct-1",
          "market-1",
          10_000_000_000,
          valid_destination
        )

      assert {:error, :quote_underpayment_refund_already_pending} =
               Facade.enqueue_quote_underpayment_refund(
                 "q-dup",
                 "acct-1",
                 "market-1",
                 10_000_000_000,
                 valid_destination
               )
    end

    test "second enqueue is refused even after the first refund has :paid_out" do
      # Pre-fix: uniqueness index dropped the scope row on any
      # terminal status. Once refund #1 hit :paid_out, a Poller
      # re-fire on the same underpaid txid (Darks eviction ~25 min
      # vs 30-min quote window, plus startup rescans) enqueued
      # refund #2, which signed and paid, doubling the outflow.
      # Fix: :quote_underpayment scope is permanent on :paid_out.
      valid_destination =
        "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge"

      {:ok, first} =
        Facade.enqueue_quote_underpayment_refund(
          "q-permanent-scope",
          "acct-1",
          "market-1",
          10_000_000_000,
          valid_destination
        )

      # Force first refund all the way to :paid_out via the state
      # machine (real signing path is stubbed out — we only need the
      # terminal status here to prove the index preservation).
      {:ok, cleared} = Payout.mark_rules_passed(first)
      {:ok, signing} = Payout.mark_signing(cleared)
      {:ok, submitted} = Payout.mark_submitted(signing, "tx-h3-first")
      {:ok, paid} = Payout.mark_paid_out(submitted)
      :ok = Store.put_payout(paid)

      # Sanity: the row is durably :paid_out.
      {:ok, %{status: :paid_out}} = Store.get_payout(first.id)

      # Regression: a re-fire on the same quote_id MUST be refused
      # even though the scope's only payout is terminal.
      assert {:error, :quote_underpayment_refund_already_pending} =
               Facade.enqueue_quote_underpayment_refund(
                 "q-permanent-scope",
                 "acct-1",
                 "market-1",
                 10_000_000_000,
                 valid_destination
               )
    end

    test ":failed refund releases the scope so a re-issue can proceed" do
      # Symmetric to the :paid_out preservation above — :failed means
      # the refund never broadcast (mark_failed refuses :submitted
      # and :settlement_unknown, so :failed can only come from a
      # pre-broadcast state). Re-issue is safe and required.
      valid_destination =
        "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge"

      {:ok, first} =
        Facade.enqueue_quote_underpayment_refund(
          "q-failed-release",
          "acct-1",
          "market-1",
          10_000_000_000,
          valid_destination
        )

      {:ok, failed} = Payout.mark_failed(first, "pre-broadcast reason")
      :ok = Store.put_payout(failed)

      assert {:ok, second} =
               Facade.enqueue_quote_underpayment_refund(
                 "q-failed-release",
                 "acct-1",
                 "market-1",
                 10_000_000_000,
                 valid_destination
               )

      assert second.source_quote_id == "q-failed-release"
      assert second.status == :pending
    end
  end
end
