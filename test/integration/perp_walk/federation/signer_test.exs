defmodule PerpWalk.Federation.SignerIntegrationTest do
  @moduledoc """
  Drives `Federation.Signer.run_now/0` against an injected stub
  signing backend. Verifies the state machine end-to-end:
  pending → rules check → rules_passed → signing → submitted →
  paid_out, with the Position transitioning to :paid_out alongside.
  """

  use PerpWalk.IntegrationCase

  import PerpWalk.TestHelpers.MarketsHelpers,
    only: [activate!: 1, dispute!: 2, pending_market!: 1]

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents
  alias PerpWalk.Federation
  alias PerpWalk.Federation.Signer
  alias PerpWalk.Markets.{AMM, Store}
  alias PerpWalk.Markets.Services.{Cashier, Resolver, Trader}
  alias PerpWalk.Reserves.Drift

  setup do
    :ok = Federation.Store.clear()
    # Other tests in the suite call Signer.halt/0; the Signer is a
    # singleton GenServer that survives between tests, so leftover
    # halt state would leave every request stuck at :pending here.
    if Signer.halted?(), do: :ok = Signer.resume()
    :ok
  end

  defp active_market(opts) do
    market = pending_market!(opts)
    activate!(market)
  end

  defp settled_winner do
    market = active_market(pool: AMM.new(100, 100))
    {:ok, position} = Trader.place_position("acct-a", market.id, :yes, 5)
    {:ok, _} = Resolver.expire(market.id)
    {:ok, _} = Resolver.submit_resolution(market.id, :yes)
    {:ok, _} = Resolver.settle(market.id)

    {:ok, refreshed} = Store.get_position(position.id)
    {market, refreshed}
  end

  defp use_backend(backend), do: :ok = Signer.set_backend(backend)

  describe "happy path — pending → rules_passed → submitted → paid_out" do
    test "successful signing transitions request and position to terminal states" do
      {_market, position} = settled_winner()
      destination = "4" <> String.duplicate("A", 94)

      txid_stub = fn _request -> {:ok, "txid-stub-success"} end
      :ok = use_backend(txid_stub)

      :ok = EventBus.subscribe(FederationEvents.RuleCheckPassed)
      :ok = EventBus.subscribe(FederationEvents.PayoutSubmitted)

      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, destination)
      assert request.status == :pending

      :ok = Signer.run_now()

      # Request reached terminal :paid_out
      {:ok, final} = Federation.Facade.get_request(request.id)
      assert final.status == :paid_out
      assert final.payout_txid == "txid-stub-success"

      # Position transitioned alongside
      {:ok, position_after} = Store.get_position(position.id)
      assert position_after.status == :paid_out
      assert position_after.payout_txid == "txid-stub-success"

      assert_receive %FederationEvents.RuleCheckPassed{request_id: rid}, 500
      assert rid == request.id

      assert_receive %FederationEvents.PayoutSubmitted{
                       request_id: ^rid,
                       payout_txid: "txid-stub-success"
                     },
                     500
    end

    test "no auto-progression once a request has reached :paid_out" do
      {_market, position} = settled_winner()
      backend = fn _ -> {:ok, "txid"} end
      :ok = use_backend(backend)

      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, "4" <> String.duplicate("A", 94))
      :ok = Signer.run_now()

      {:ok, final} = Federation.Facade.get_request(request.id)
      assert final.status == :paid_out

      # Re-tick — no further movement; request stays terminal.
      :ok = Signer.run_now()
      {:ok, after_re_tick} = Federation.Facade.get_request(request.id)
      assert after_re_tick.status == :paid_out
    end
  end

  describe "rule rejection → :awaiting_operator" do
    test "rejected requests do NOT call the signing backend" do
      {_market, position} = settled_winner()

      backend_pid = self()

      backend = fn _request ->
        send(backend_pid, :backend_called)
        {:ok, "should-not-happen"}
      end

      :ok = use_backend(backend)
      :ok = EventBus.subscribe(FederationEvents.RuleCheckFailed)

      # Cashier rejects malformed destinations now, so we trigger rule
      # rejection downstream instead. Enqueue normally, then mutate the
      # stored Payout's destination to something the rule engine will
      # refuse (sanity regex). This isolates the test's intent
      # ("Signer must NOT call backend on rule rejection") from the
      # request-validation layer.
      destination = "4" <> String.duplicate("A", 94)
      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, destination)
      :ok = Federation.Store.put_payout(%{request | destination: "abc"})

      :ok = Signer.run_now()

      {:ok, after_tick} = Federation.Facade.get_request(request.id)
      assert after_tick.status == :awaiting_operator
      assert after_tick.rule_failure_reason =~ "destination"

      assert_receive %FederationEvents.RuleCheckFailed{request_id: rid}, 500
      assert rid == request.id

      refute_receive :backend_called, 100
    end
  end

  describe "rate cap — request under evaluation is not double-counted" do
    test "dominant winner within the per-market cap pays out" do
      # Regression: load_context passed ALL stored requests as
      # recent_requests, including the request under evaluation. The
      # Rules engine adds the request's own amount on top as
      # `projected`, so every payout counted twice — halving the
      # effective per-market cap to 25% and bouncing legitimate
      # dominant-winner payouts (~41% of pool here) to
      # :awaiting_operator.
      market = active_market([])
      {:ok, position} = Trader.place_position("acct-dominant", market.id, :yes, 90)
      {:ok, _} = Resolver.expire(market.id)
      {:ok, _} = Resolver.submit_resolution(market.id, :yes)
      {:ok, _} = Resolver.settle(market.id)
      {:ok, position} = Store.get_position(position.id)

      :ok = use_backend(fn _ -> {:ok, "txid-dominant"} end)

      destination = "4" <> String.duplicate("A", 94)
      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, destination)

      :ok = Signer.run_now()

      {:ok, final} = Federation.Facade.get_request(request.id)

      assert final.status == :paid_out,
             "payout within the per-market cap must pass rules, got #{inspect(final.status)} (#{inspect(final.rule_failure_reason)})"
    end
  end

  describe "force_sign — rules revalidation rejects" do
    test "transitions request to :failed (terminal), not stuck at :rules_passed" do
      # Regression: stuck `:rules_passed` requests phantom-reserve
      # balance in the federation income ledger because
      # `federation_income_drawn/0` sums every non-`:failed` request.
      # Force_sign must terminate cleanly when rules permanently
      # reject, so the operator can enqueue a fresh request without
      # the old one locking funds in `drawn`.
      {_market, position} = settled_winner()

      backend_pid = self()

      backend = fn _request ->
        send(backend_pid, :backend_called)
        {:ok, "should-not-happen"}
      end

      :ok = use_backend(backend)
      :ok = EventBus.subscribe(FederationEvents.PayoutFailed)

      # Manufacture a request that rules will reject. Same pattern as
      # the :awaiting_operator test above — Cashier sanitises
      # destinations on enqueue, so we enqueue cleanly then corrupt
      # the stored Payout's destination to something the rule engine
      # will refuse.
      destination = "4" <> String.duplicate("A", 94)
      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, destination)
      :ok = Federation.Store.put_payout(%{request | destination: "abc"})

      # First tick: rules reject, request → :awaiting_operator.
      :ok = Signer.run_now()
      {:ok, after_first} = Federation.Facade.get_request(request.id)
      assert after_first.status == :awaiting_operator

      # Operator force-signs. Rules will re-evaluate at next tick.
      {:ok, _} = Federation.Facade.force_approve(request.id)

      # Second tick: rules re-evaluate, reject again, transition to :failed.
      :ok = Signer.run_now()

      {:ok, after_force} = Federation.Facade.get_request(request.id)

      assert after_force.status == :failed,
             "force_sign with permanently-failing rules must terminate at :failed, got #{inspect(after_force.status)}"

      assert after_force.rule_failure_reason =~ "rules_revalidation"

      assert_receive %FederationEvents.PayoutFailed{
                       request_id: rid,
                       reason: "rules_revalidation:" <> _
                     },
                     500

      assert rid == request.id

      # Backend must NOT have been called — rules rejected before
      # signing.
      refute_receive :backend_called, 100
    end
  end

  describe "signing backend errors" do
    test "leaves the request in :rules_passed for retry and does NOT emit PayoutFailed" do
      # Transient signing-backend failures do not durably change payout
      # state — the request stays in `:rules_passed` and Signer retries
      # on backoff. PayoutFailed fires ONLY on a terminal `:failed`
      # transition (see `Federation.Store.maybe_emit_event/1`), so a
      # transient rejection must not surface a "needs attention" pill
      # to the user's portfolio LiveView.
      {_market, position} = settled_winner()

      backend = fn _ -> {:error, :wallet_unreachable} end
      :ok = use_backend(backend)
      :ok = EventBus.subscribe(FederationEvents.PayoutFailed)

      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, "4" <> String.duplicate("A", 94))

      :ok = Signer.run_now()

      # First tick: pending → rules_passed (rules pass)
      # Second tick: rules_passed → backend errors
      :ok = Signer.run_now()

      {:ok, after_two_ticks} = Federation.Facade.get_request(request.id)
      assert after_two_ticks.status == :rules_passed

      refute_receive %FederationEvents.PayoutFailed{}, 200

      # Position stays in :settled_winner until backend succeeds.
      {:ok, position_after} = Store.get_position(position.id)
      assert position_after.status == :settled_winner
    end

    test "after a backend recovers, retry succeeds" do
      {_market, position} = settled_winner()

      # Use Process dictionary keyed by self() so each test gets isolation.
      attempt_pid = self()

      backend = fn _ ->
        send(attempt_pid, :attempt)

        case Process.get(:signer_attempt, 0) do
          0 ->
            Process.put(:signer_attempt, 1)
            {:error, :transient}

          _ ->
            {:ok, "txid-retry-success"}
        end
      end

      :ok = use_backend(backend)

      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, "4" <> String.duplicate("A", 94))

      :ok = Signer.run_now()
      # First retry would normally be blocked by the backoff window.
      # Clear retry state to keep the test fast.
      :ok = Signer.clear_retry(request.id)
      :ok = Signer.run_now()

      # Reset Process state for next tick
      Process.put(:signer_attempt, 1)
      :ok = Signer.clear_retry(request.id)
      :ok = Signer.run_now()

      {:ok, final} = Federation.Facade.get_request(request.id)
      assert final.status == :paid_out
      assert final.payout_txid == "txid-retry-success"
    end
  end

  describe "broadcast marker — anti double-broadcast" do
    test "does NOT re-broadcast on tick re-entry after backend succeeded once" do
      {_market, position} = settled_winner()
      destination = "4" <> String.duplicate("A", 94)

      attempt_pid = self()

      backend = fn _ ->
        send(attempt_pid, :backend_called)
        {:ok, "txid-marker-test"}
      end

      :ok = use_backend(backend)

      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, destination)

      :ok = Signer.run_now()
      :ok = Signer.run_now()
      :ok = Signer.run_now()

      assert_receive :backend_called, 100
      refute_receive :backend_called, 200

      {:ok, final} = Federation.Facade.get_request(request.id)
      assert final.status == :paid_out
      assert final.payout_txid == "txid-marker-test"
    end

    test "resume path: marker present + ETS still :rules_passed skips backend" do
      {_market, position} = settled_winner()
      destination = "4" <> String.duplicate("A", 94)

      attempt_pid = self()

      backend = fn _ ->
        send(attempt_pid, :backend_called)
        {:ok, "txid-should-not-be-issued-again"}
      end

      :ok = use_backend(backend)

      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, destination)

      # Simulate the post-broadcast crash: a prior tick called the
      # backend and returned a txid, but the put_payout(:signing) WAL
      # write never landed. The marker holds the txid; the row is
      # still :rules_passed in ETS.
      :ok =
        PerpWalk.Federation.Store.persist_broadcast_marker(
          request.id,
          "txid-from-prior-tick"
        )

      :ok = Signer.run_now()

      # Backend MUST NOT be called again — the marker should drive the
      # resume path with the stored txid.
      refute_receive :backend_called, 100

      {:ok, final} = Federation.Facade.get_request(request.id)
      assert final.status == :paid_out
      assert final.payout_txid == "txid-from-prior-tick"

      # Marker cleared on terminal-state success.
      assert PerpWalk.Federation.Store.lookup_broadcast_marker(request.id) == :none
    end

    test "marker survives a Store process restart via WAL replay" do
      # Models a BEAM restart: a marker is durably WAL'd, then
      # persistent_term gets wiped (the failure mode a real node
      # restart causes). When the Store boots its WAL replay must
      # rehydrate the marker so the next Signer tick sees it and
      # resumes from the durable txid rather than re-broadcasting.
      {_market, position} = settled_winner()
      destination = "4" <> String.duplicate("A", 94)

      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, destination)

      :ok = PerpWalk.Federation.Store.persist_broadcast_marker(request.id, "txid-pre-restart")

      # Wipe persistent_term mimicking BEAM restart.
      :persistent_term.erase({PerpWalk.Federation.Store.BroadcastMarker, request.id})
      assert PerpWalk.Federation.Store.lookup_broadcast_marker(request.id) == :none

      # Restart the Store GenServer — its init replays the WAL.
      pid = Process.whereis(PerpWalk.Federation.Store)
      ref = Process.monitor(pid)
      :ok = Supervisor.terminate_child(PerpWalk.Federation.Supervisor, PerpWalk.Federation.Store)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000

      {:ok, _new_pid} =
        Supervisor.restart_child(
          PerpWalk.Federation.Supervisor,
          PerpWalk.Federation.Store
        )

      assert PerpWalk.Federation.Store.lookup_broadcast_marker(request.id) == "txid-pre-restart"
    end
  end

  describe "halt persistence across Signer restart" do
    test "halt survives a Signer GenServer restart via persistent_term" do
      # Operator halts.
      :ok = Signer.halt()
      assert Signer.halted?()
      assert :persistent_term.get({Signer, :halted}, false) == true

      # Simulate a Signer process crash + supervisor restart by killing
      # the process; Federation.Supervisor's :one_for_one strategy will
      # restart it.
      pid_before = Process.whereis(Signer)
      ref = Process.monitor(pid_before)
      Process.exit(pid_before, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid_before, :killed}, 500

      # Sync on the supervisor: a call blocks until the supervisor has
      # processed the exit signal (FIFO) and completed the replacement
      # child's init/1. No timing sleep — no race.
      _ = Supervisor.which_children(PerpWalk.Federation.Supervisor)

      pid_after = Process.whereis(Signer)
      assert is_pid(pid_after)
      refute pid_after == pid_before

      # The replacement init must NOT have wiped the persistent_term
      # flag — the operator's halt is sticky across the restart.
      assert :persistent_term.get({Signer, :halted}, false) == true
      assert Signer.halted?()
    end
  end

  describe "transient-error backoff" do
    test "backend rejection does NOT trigger another backend call until backoff elapses" do
      {_market, position} = settled_winner()
      destination = "4" <> String.duplicate("A", 94)

      attempt_pid = self()

      backend = fn _ ->
        send(attempt_pid, :backend_called)
        {:error, :wallet_unreachable}
      end

      :ok = use_backend(backend)

      {:ok, _request} = Cashier.claim_payout(position.id, position.account_id, destination)

      # First tick: backend called, fails, retry recorded.
      :ok = Signer.run_now()
      assert_receive :backend_called, 100

      # Subsequent ticks within the backoff window MUST NOT call the
      # backend again — that was the bug producing an alert flood on
      # transient errors (every 5s tick re-invoking the backend and,
      # historically, republishing PayoutFailed; the event emission has
      # since been removed but the backoff still guards backend load).
      :ok = Signer.run_now()
      :ok = Signer.run_now()
      :ok = Signer.run_now()
      refute_receive :backend_called, 100
    end

    test "successful backend response clears the retry state" do
      # If a retry succeeds (e.g. wallet outputs unlocked, peer back
      # online), the retry counter must reset so a future fresh
      # failure starts at the bottom of the backoff schedule rather
      # than at the prior climb's tail.
      {_market, position} = settled_winner()
      destination = "4" <> String.duplicate("A", 94)

      attempt = :counters.new(1, [])

      backend = fn _ ->
        case :counters.get(attempt, 1) do
          0 ->
            :counters.add(attempt, 1, 1)
            {:error, :wallet_unreachable}

          _ ->
            {:ok, "txid-success-after-retry"}
        end
      end

      :ok = use_backend(backend)

      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, destination)

      # First tick fails, retry state records the failure.
      :ok = Signer.run_now()

      # Clear retry state so we don't have to sleep through the full
      # backoff window in tests.
      :ok = Signer.clear_retry(request.id)

      # Second tick succeeds and drives the payout to :paid_out.
      :ok = Signer.run_now()

      {:ok, final} = Federation.Facade.get_request(request.id)
      assert final.status == :paid_out
      assert final.payout_txid == "txid-success-after-retry"

      # Retry state must be cleared on success.
      assert :ets.lookup(PerpWalk.Federation.Signer.RetryState, request.id) == []
    end
  end

  describe "set_backend production seal" do
    test "refuses the swap in :prod and surfaces :production_seal" do
      saved_env = Application.get_env(:perpwalk, :env)
      Application.put_env(:perpwalk, :env, :prod)

      try do
        sentinel = fn _ -> {:ok, "tx-should-not-be-installed"} end

        assert {:error, :production_seal} = Signer.set_backend(sentinel)
      after
        case saved_env do
          nil -> Application.delete_env(:perpwalk, :env)
          env -> Application.put_env(:perpwalk, :env, env)
        end
      end
    end
  end

  describe "reserves-drift gates the signing tick" do
    setup do
      on_exit(fn -> Drift.reset() end)
      :ok
    end

    test "divergent peers halt drive_writes?; NO backend call" do
      # Pre-fix: drift was advisory-only — telemetry alerted but the
      # signing loop kept advancing payouts. A guardian's wallet
      # disagreeing on unspent outputs meant signing a tx that peers
      # would see as double-spending outputs they don't recognise.
      # Fix: drive_writes? consults Reserves.Drift.status/0 and
      # short-circuits when divergent_peers is non-empty.
      {_market, position} = settled_winner()
      destination = "4" <> String.duplicate("A", 94)

      attempt_pid = self()

      backend = fn _ ->
        send(attempt_pid, :backend_called)
        {:ok, "should-not-be-issued"}
      end

      :ok = use_backend(backend)

      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, destination)

      # Simulate a divergent-peer round observed by the Collector.
      Drift.record_round([:p2], [], DateTime.utc_now())

      :ok = Signer.run_now()
      :ok = Signer.run_now()

      refute_receive :backend_called, 200

      {:ok, still_pending} = Federation.Facade.get_request(request.id)
      assert still_pending.status == :pending

      # Drift is sticky — only a clean attestation from :p2 clears it.
      Drift.record_round([], [:p2], DateTime.utc_now())
      :ok = Signer.run_now()

      assert_receive :backend_called, 500

      {:ok, after_resume} = Federation.Facade.get_request(request.id)
      assert after_resume.status == :paid_out
    end
  end

  describe "health halt gates the signing tick" do
    setup do
      on_exit(fn ->
        PerpWalk.Telemetry.Health.System.clear_halt()
        if Signer.halted?(), do: Signer.resume()
      end)

      :ok
    end

    test "system halt short-circuits drive_writes?; NO backend call, no finalise crash" do
      # Pre-fix: drive_writes? consulted only the Signer's own
      # in-process halt flag, NOT the health system's halt. Queued
      # payouts continued to sign while the operator model said
      # "halt blocks all writes". Worse, finalize called Markets
      # writes which raise `SystemHaltedError` under health halt,
      # taking the Signer down in a supervisor-restart loop.
      {_market, position} = settled_winner()
      destination = "4" <> String.duplicate("A", 94)

      attempt_pid = self()

      backend = fn _ ->
        send(attempt_pid, :backend_called)
        {:ok, "should-not-be-issued"}
      end

      :ok = use_backend(backend)

      # Enqueue the payout while the system is healthy (Cashier
      # itself is gated by Guards), then halt so drive_writes?
      # blocks the tick.
      {:ok, request} =
        Cashier.claim_payout(position.id, position.account_id, destination)

      PerpWalk.Telemetry.Health.System.set_halted("test — halt blocks signing")

      :ok = Signer.run_now()
      :ok = Signer.run_now()

      refute_receive :backend_called, 200

      {:ok, still_pending} = Federation.Facade.get_request(request.id)
      assert still_pending.status == :pending

      # Clear the halt and the tick resumes normally on the next call.
      PerpWalk.Telemetry.Health.System.clear_halt()
      :ok = Signer.run_now()

      assert_receive :backend_called, 500

      {:ok, after_resume} = Federation.Facade.get_request(request.id)
      assert after_resume.status == :paid_out
    end

    test "finalize rescue: an unexpected raise doesn't crash the Signer" do
      # Defensive: even with the drive_writes? gate now in place,
      # any code path that reaches finalize AND encounters a raise
      # (e.g. a hard-coded ensure_operational! deep in a Markets
      # write not yet gated) must NOT propagate up. Simulate by
      # halting mid-flight: the backend returns {:ok, txid} inside
      # the same tick that we halt from a peer process just before
      # finish_after_signing invokes mark_position_paid_out.
      {_market, position} = settled_winner()
      destination = "4" <> String.duplicate("A", 94)

      # First tick: pending → rules_passed, backend not called yet.
      backend = fn _ ->
        # Halt IN the backend call so drive_writes? passes on entry
        # but the health system halts before finalize.
        PerpWalk.Telemetry.Health.System.set_halted("test — mid-tick halt")
        {:ok, "txid-mid-halt"}
      end

      :ok = use_backend(backend)

      {:ok, _request} =
        Cashier.claim_payout(position.id, position.account_id, destination)

      pid_before = Process.whereis(Signer)

      # Tick — the backend {:ok, txid} arrives, marker persists,
      # transition_through_signing runs finalize which raises
      # SystemHaltedError. Rescue converts to {:error, {:finalize_raised, _}}
      # and the Signer keeps running.
      :ok = Signer.run_now()

      pid_after = Process.whereis(Signer)

      assert pid_after == pid_before,
             "Signer must NOT crash-loop when finalize raises under halt"
    end
  end

  describe "broadcast marker cleanup on operator abort" do
    test "Facade.abort_request clears the broadcast marker" do
      {_market, position} = settled_winner()

      {:ok, request} =
        Cashier.claim_payout(
          position.id,
          position.account_id,
          "4" <> String.duplicate("A", 94)
        )

      # Move the row to :rules_passed (the abort path's prerequisite).
      backend = fn _ -> {:error, :wallet_unreachable} end
      :ok = use_backend(backend)
      :ok = Signer.run_now()
      :ok = Signer.run_now()

      # Plant a marker as if a prior tick had broadcast.
      :ok = PerpWalk.Federation.Store.persist_broadcast_marker(request.id, "txid-prior")

      # Operator aborts the stuck request.
      assert {:ok, aborted} =
               Federation.Facade.abort_request(request.id, "operator triage")

      assert aborted.status == :failed

      # Marker MUST be cleaned up — otherwise the key leaks forever.
      assert PerpWalk.Federation.Store.lookup_broadcast_marker(request.id) == :none
    end

    test "abort_request REFUSED on :submitted, marker preserved" do
      # Pre-fix, abort_request happily flipped :submitted → :failed
      # AND cleared the broadcast marker. The source Position stayed
      # in :settled_winner, so a subsequent claim built a fresh tx and
      # paid the same recipient twice. Fix: mark_failed refuses
      # :submitted; abort_request surfaces :invalid_transition.
      {_market, position} = settled_winner()
      destination = "4" <> String.duplicate("A", 94)

      backend = fn _ -> {:ok, "txid-broadcast-h6"} end
      :ok = use_backend(backend)

      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, destination)
      :ok = Signer.run_now()

      # Payout should have completed all the way to :paid_out here,
      # so re-fetch and manually move back to :submitted for the
      # invariant test (the vulnerable window is between broadcast
      # and finalisation, which is normally microseconds but is the
      # scenario the abort refusal must cover).
      {:ok, %{status: :paid_out}} = Federation.Facade.get_request(request.id)

      # Force the row back to :submitted to simulate a payout that
      # was broadcast but hasn't yet been finalised (Position still
      # in a claimable state).
      {:ok, current} = Federation.Facade.get_request(request.id)
      submitted = %{current | status: :submitted, payout_txid: "txid-broadcast-h6"}
      :ok = Federation.Store.put_payout(submitted)
      :ok = PerpWalk.Federation.Store.persist_broadcast_marker(request.id, "txid-broadcast-h6")

      # Abort MUST refuse.
      assert {:error, :invalid_transition} =
               Federation.Facade.abort_request(request.id, "operator abort")

      # Row unchanged, marker preserved.
      {:ok, still_submitted} = Federation.Facade.get_request(request.id)
      assert still_submitted.status == :submitted
      assert still_submitted.payout_txid == "txid-broadcast-h6"

      assert PerpWalk.Federation.Store.lookup_broadcast_marker(request.id) ==
               "txid-broadcast-h6"
    end
  end

  describe "submit-ambiguous — settlement_unknown holds the payout" do
    test "backend returning {:submit_ambiguous, reason} pins the payout and does NOT re-sign" do
      # The precise double-payout regression: submit RPC
      # returned an outcome we cannot classify (timeout / 5xx / null
      # result). The tx MAY have been broadcast. Blindly re-signing
      # with fresh coin selection here would double-pay if the earlier
      # submit did land.
      #
      # Contract: backend returns {:error, {:submit_ambiguous, reason}};
      # Signer transitions payout to :settlement_unknown, records NO
      # retry, and refuses to re-invoke the backend on subsequent ticks.
      {_market, position} = settled_winner()
      destination = "4" <> String.duplicate("A", 94)

      attempt_pid = self()

      backend = fn _request ->
        send(attempt_pid, :backend_called)
        {:error, {:submit_ambiguous, {:connection_error, :timeout}}}
      end

      :ok = use_backend(backend)
      :ok = EventBus.subscribe(FederationEvents.PayoutSettlementUnknown)

      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, destination)

      # First tick drives pending → rules_passed → backend, so the
      # backend is called exactly once on that same tick (advance/3
      # returns `{:advanced, updated}` from :pending and immediately
      # re-enters at :rules_passed). Subsequent ticks MUST NOT call
      # it again — that's the invariant.
      :ok = Signer.run_now()

      assert_receive :backend_called, 200

      {:ok, after_ambiguous} = Federation.Facade.get_request(request.id)
      assert after_ambiguous.status == :settlement_unknown
      assert after_ambiguous.rule_failure_reason =~ "submit_ambiguous"

      assert_receive %FederationEvents.PayoutSettlementUnknown{request_id: rid}, 500
      assert rid == request.id

      # Third + fourth ticks: MUST NOT re-invoke the backend. The
      # payout is now out of the auto-signer's reach — operator drives
      # it via Console.reconcile_paid_out/reconcile_failed.
      :ok = Signer.run_now()
      :ok = Signer.run_now()
      refute_receive :backend_called, 200

      {:ok, after_reticks} = Federation.Facade.get_request(request.id)
      assert after_reticks.status == :settlement_unknown

      # Position must NOT be marked paid — funds status is unknown.
      {:ok, position_after} = Store.get_position(position.id)
      assert position_after.status == :settled_winner
    end

    test "reconcile_paid_out drives settlement_unknown to :paid_out with recovered txid" do
      {_market, position} = settled_winner()
      destination = "4" <> String.duplicate("A", 94)

      backend = fn _ -> {:error, {:submit_ambiguous, :no_txid_returned}} end
      :ok = use_backend(backend)

      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, destination)
      :ok = Signer.run_now()

      {:ok, unknown} = Federation.Facade.get_request(request.id)
      assert unknown.status == :settlement_unknown

      # Operator queries wallet-rpc, finds a matching outgoing transfer,
      # supplies the txid. Payout goes to :paid_out with the recovered
      # txid pinned; PayoutSubmitted fires so downstream consumers
      # observe the completion.
      :ok = EventBus.subscribe(FederationEvents.PayoutSubmitted)

      {:ok, reconciled} =
        Federation.Facade.reconcile_settlement(request.id, {:paid_out, "recovered-txid-xyz"})

      assert reconciled.status == :paid_out
      assert reconciled.payout_txid == "recovered-txid-xyz"

      assert_receive %FederationEvents.PayoutSubmitted{
                       request_id: rid,
                       payout_txid: "recovered-txid-xyz"
                     },
                     500

      assert rid == request.id

      # The Markets-side position must be finalized by the reconcile —
      # otherwise the claim path stays open (:settled_winner + freed
      # uniqueness scope) and a second claim signs a second tx.
      {:ok, finalized} = Store.get_position(position.id)
      assert finalized.status == :paid_out

      assert {:error, :not_payable} =
               Cashier.claim_payout(position.id, position.account_id, destination)
    end

    test "reconcile_failed drives settlement_unknown to :failed and emits PayoutFailed" do
      {_market, position} = settled_winner()
      destination = "4" <> String.duplicate("A", 94)

      backend = fn _ -> {:error, {:submit_ambiguous, {:http_error, 502}}} end
      :ok = use_backend(backend)

      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, destination)
      :ok = Signer.run_now()
      :ok = Signer.run_now()

      :ok = EventBus.subscribe(FederationEvents.PayoutFailed)

      {:ok, reconciled} =
        Federation.Facade.reconcile_settlement(
          request.id,
          {:failed, "no_matching_transfer"}
        )

      assert reconciled.status == :failed
      assert reconciled.rule_failure_reason == "no_matching_transfer"

      assert_receive %FederationEvents.PayoutFailed{
                       request_id: rid,
                       reason: "reconciled_no_broadcast:" <> _
                     },
                     500

      assert rid == request.id
    end

    test "reconcile refuses non-:settlement_unknown payouts" do
      {_market, position} = settled_winner()

      {:ok, request} =
        Cashier.claim_payout(
          position.id,
          position.account_id,
          "4" <> String.duplicate("A", 94)
        )

      # Payout is :pending — reconcile must refuse regardless of tuple shape.
      assert {:error, :invalid_transition} =
               Federation.Facade.reconcile_settlement(request.id, {:paid_out, "txid"})

      assert {:error, :invalid_transition} =
               Federation.Facade.reconcile_settlement(request.id, {:failed, "reason"})
    end
  end

  describe "broadcast marker persist failure — settlement_unknown, no re-broadcast" do
    setup do
      on_exit(fn -> Signer.reset_marker_persister() end)
      :ok
    end

    test "marker persist error pins the payout in :settlement_unknown with txid in reason" do
      # Pre-fix, Signer used to discard the return of
      # `store_broadcast_marker`. On a WAL persist failure the row
      # stayed at :rules_passed with NO marker; the next tick then
      # re-invoked the backend and issued a second on-chain broadcast.
      #
      # Contract: marker persist failure surfaces as {:error, _}; the
      # Signer transitions to :settlement_unknown with the txid
      # embedded in the reason so operator can reconcile trivially.
      {_market, position} = settled_winner()
      destination = "4" <> String.duplicate("A", 94)

      attempt_pid = self()

      backend = fn _request ->
        send(attempt_pid, :backend_called)
        {:ok, "txid-marker-persist-failed"}
      end

      :ok = use_backend(backend)

      failing_persister = fn _request_id, _txid ->
        {:error, :wal_overloaded}
      end

      :ok = Signer.set_marker_persister(failing_persister)

      :ok = EventBus.subscribe(FederationEvents.PayoutSettlementUnknown)

      {:ok, request} = Cashier.claim_payout(position.id, position.account_id, destination)

      :ok = Signer.run_now()

      assert_receive :backend_called, 500

      {:ok, after_failure} = Federation.Facade.get_request(request.id)
      assert after_failure.status == :settlement_unknown

      # Reason MUST carry the txid so operator can drive
      # `reconcile_paid_out(request.id, "<txid>")` without spelunking
      # through logs for a lost hex string.
      assert after_failure.rule_failure_reason =~ "broadcast_marker_persist_failed"
      assert after_failure.rule_failure_reason =~ "txid=txid-marker-persist-failed"

      assert_receive %FederationEvents.PayoutSettlementUnknown{
                       request_id: rid,
                       reason: "broadcast_marker_persist_failed:" <> _
                     },
                     500

      assert rid == request.id

      # Restore for the second-tick assertion — the double-broadcast
      # regression: subsequent ticks MUST NOT re-invoke the backend.
      :ok = Signer.run_now()
      :ok = Signer.run_now()
      refute_receive :backend_called, 200
    end

    test "catastrophic case: marker + status transition both fail → Signer halts" do
      # Rare but must fail-closed. If the WAL is so far gone that
      # even the settlement_unknown transition can't persist, prefer
      # halting the entire Signer over the alternative of the next
      # tick re-invoking the backend on a :rules_passed row.
      {_market, position} = settled_winner()
      destination = "4" <> String.duplicate("A", 94)

      backend = fn _request -> {:ok, "txid-catastrophic"} end
      :ok = use_backend(backend)

      # This persister fails; the transition_to_settlement_unknown
      # helper's put_payout call ALSO goes through the WAL. We fake
      # that by killing the Federation.Store just after the marker
      # persist fails — cleanest way to make the follow-up put_payout
      # error out too. Restart on exit so subsequent tests get a
      # working store back.
      on_exit(fn ->
        case Process.whereis(PerpWalk.Federation.Store) do
          nil ->
            {:ok, _} =
              Supervisor.restart_child(
                PerpWalk.Federation.Supervisor,
                PerpWalk.Federation.Store
              )

          _pid ->
            :ok
        end
      end)

      failing_persister = fn _request_id, _txid ->
        # Take the store down mid-flight so the subsequent
        # transition_to_settlement_unknown's put_payout call fails.
        :ok = Supervisor.terminate_child(PerpWalk.Federation.Supervisor, PerpWalk.Federation.Store)
        {:error, :wal_overloaded}
      end

      :ok = Signer.set_marker_persister(failing_persister)

      :ok = EventBus.subscribe(FederationEvents.SigningHalted)

      {:ok, _request} = Cashier.claim_payout(position.id, position.account_id, destination)

      :ok = Signer.run_now()

      # Halt event fires and the persistent_term flag is set so
      # subsequent ticks are no-ops.
      assert_receive %FederationEvents.SigningHalted{}, 500
      assert Signer.halted_snapshot() == true

      # Cleanup: resume signer state for the next test.
      :ok = Signer.resume()
    end
  end

  describe "dispute refund — happy path" do
    test "drives a :resolved_against dispute to :refunded_full and request to :paid_out" do
      market = active_market(pool: AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))
      {:ok, _} = Trader.place_position("acct-a", market.id, :yes, 5)
      {:ok, _} = Trader.place_position("voter-1", market.id, :yes, 1)
      {:ok, _} = Resolver.expire(market.id)
      {:ok, _} = Resolver.submit_resolution(market.id, :yes)

      live = dispute!("voter-1", market.id)
      {:ok, _} = Resolver.reverse_resolution(market.id, :no)

      {:ok, dispute_after_reverse} = Store.get_dispute("voter-1", market.id)
      assert dispute_after_reverse.status == :resolved_against

      :ok = use_backend(fn _ -> {:ok, "txid-dispute-success"} end)
      :ok = EventBus.subscribe(FederationEvents.PayoutSubmitted)

      destination = "4" <> String.duplicate("A", 94)

      {:ok, request} =
        Cashier.claim_dispute_refund("voter-1", market.id, destination)

      assert request.kind == :dispute_refund_full
      assert request.position_id == nil
      assert request.amount_piconeros == live.stake_amount_piconeros

      :ok = Signer.run_now()

      {:ok, final} = Federation.Facade.get_request(request.id)
      assert final.status == :paid_out
      assert final.payout_txid == "txid-dispute-success"

      {:ok, dispute_final} = Store.get_dispute("voter-1", market.id)
      assert dispute_final.status == :refunded_full

      assert_receive %FederationEvents.PayoutSubmitted{
                       request_id: rid,
                       position_id: nil,
                       payout_txid: "txid-dispute-success"
                     },
                     500

      assert rid == request.id
    end
  end
end
