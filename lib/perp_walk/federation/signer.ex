defmodule PerpWalk.Federation.Signer do
  @moduledoc """
  Per-node federation signer. Watches the Payout queue
  and drives requests through the state machine:

      :pending → run Rules.evaluate/1 →
        :ok → :rules_passed → run signing_backend → :submitted →
              transition Position to :paid_out → :paid_out
        {:reject, reason} → :awaiting_operator (queued for review)

  ## Polling

  The Signer ticks every `tick_interval_ms` (default 5s in
  production; the interval can be lengthened via config so callers
  can drive ticks explicitly via `run_now/0`). Each tick scans
  `:pending` and `:rules_passed` requests and advances them as far
  as possible.

  ## Signing backend

  The actual cryptographic signing is delegated to a 1-arity
  function: `(Payout.t()) -> {:ok, txid} | {:error, reason}`.

  - **Production** — `PerpWalk.Federation.Signing.Monero.sign/1`
    drives the multi-round Monero multisig protocol via
    `:rpc.call` to peers and `Darks.Multisig.{sign,submit}`.
    Wired in via `config/prod.exs`.
  - **Tests** — the default `stub_signing_backend/1` refuses to
    sign so the state machine can be verified end-to-end without
    touching a real wallet. Override per-test via
    `Signer.set_backend/1`.

  ## Idempotency

  Each tick processes requests in their current status; the
  state machine guards prevent double-processing. A request that
  reaches `:submitted` and then has its Position transitioned to
  `:paid_out` is moved to its terminal `:paid_out` request status
  and won't be re-scanned (terminal requests are filtered out).

  ## Failures

  Signing failures leave the request in `:rules_passed` so the
  next tick retries. Persistent failures should bubble up via
  `Federation.PayoutFailed` events to operator alerts. Non-
  recoverable failures (e.g. invariant violation) move the
  request to `:failed` (terminal).
  """

  use GenServer

  require Logger

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents
  alias PerpWalk.Federation.{Facade, Payout, Rules}
  alias PerpWalk.Federation.Multisig.Guard
  alias PerpWalk.Federation.Store, as: FederationStore
  alias PerpWalk.Markets.Facade, as: MarketsFacade
  alias PerpWalk.Role
  alias PerpWalk.Telemetry.Facade, as: TelemetryFacade

  @default_tick_interval_ms 5_000

  # Per-request backoff for transient backend errors (wallet
  # unreachable, output-not-yet-unlocked, multisig peer offline, etc.).
  # Without this the Signer hammers the backend every tick on a payout
  # that won't succeed until external state changes — typical case
  # being Monero's ~10-block output lock, ≈20 minutes.
  #
  # Algorithm: capped binary exponential with full jitter.
  #
  #     delay = rand(0, min(BASE × 2^(attempt - 1), CAP))
  #
  # Full jitter (AWS-recommended over plain exponential or equal-jitter)
  # decorrelates retries when multiple stuck payouts are queueing
  # against the same wallet — without it they tend to fire in
  # lockstep against the same output-availability window and the
  # contention pattern just repeats at every doubling.
  @retry_table __MODULE__.RetryState
  @backoff_base_ms 30_000
  @backoff_max_ms 600_000
  @backoff_max_exp 16

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Run a tick synchronously. Useful from iex during ops and from
  tests that drive transitions explicitly.
  """
  @spec run_now() :: :ok
  def run_now do
    GenServer.call(__MODULE__, :run_now, 30_000)
  end

  @doc """
  Swap the signing backend on a running Signer. Test-only seam —
  production configures the backend at supervisor start.

  Refuses in `:prod` because an iex caller able to substitute the
  backend can synthesize `{:ok, "fake_txid"}` responses that the
  Signer's post-submit bookkeeping treats as real broadcasts: Position
  ETS goes to `:paid_out`, disputes to `:refunded_full`, federation
  income drawn-counter advances — all without any on-chain transfer.
  The downstream corruption has no clean recovery path.
  """
  @spec set_backend((Payout.t() -> {:ok, String.t()} | {:error, term()})) ::
          :ok | {:error, :production_seal}
  def set_backend(backend) when is_function(backend, 1) do
    if Application.get_env(:perpwalk, :env) == :prod do
      {:error, :production_seal}
    else
      GenServer.call(__MODULE__, {:set_backend, backend})
    end
  end

  @doc """
  Swap the broadcast-marker persister on a running Signer. Test-only
  seam — production uses `Federation.Store.persist_broadcast_marker/2`
  and never overrides.

  Sealed in `:prod` because a marker-persister returning `{:error, _}`
  when the WAL actually IS healthy would push every real payout into
  `:settlement_unknown` and require operator reconciliation — a
  denial-of-service on the auto-signer. Tests need the injection to
  drive the WAL-failure branch; prod has zero legitimate reason to
  swap it.
  """
  @spec set_marker_persister((binary(), String.t() -> :ok | {:error, term()})) ::
          :ok | {:error, :production_seal}
  def set_marker_persister(persister) when is_function(persister, 2) do
    if Application.get_env(:perpwalk, :env) == :prod do
      {:error, :production_seal}
    else
      GenServer.call(__MODULE__, {:set_marker_persister, persister})
    end
  end

  @doc "Test-only: restore the marker persister to the production default."
  @spec reset_marker_persister() :: :ok
  def reset_marker_persister do
    set_marker_persister(&FederationStore.persist_broadcast_marker/2)
  end

  @doc """
  Halt all auto-signing. Ticks become no-ops until `resume/0`.
  Operator emergency control — use when something looks wrong
  and you want every subsequent payout queued for manual review.

  ## What halt does and does not stop

  - **Stops**: every signing round that has NOT yet entered
    `Federation.Signing.Monero.sign/1`. The halt flag is observed
    by the entry check and by the mid-flight gates inside `sign/1`
    so a request reaching the backend after halt is published
    will abort before the wallet RPC submits the on-chain tx.
  - **Does not stop**: a tx that has already passed the final
    pre-submit halt check inside `sign/1`. The Monero `submit_multisig`
    RPC is atomic on the wallet side and runs to completion
    once invoked. Worst-case post-halt drift is one in-flight
    signature landing on-chain.
  """
  @spec halt() :: :ok
  def halt do
    # Publish the halt flag synchronously in the caller's process so
    # mid-flight gates inside `Signing.Monero.sign/1` see it before the
    # next wallet-RPC round. Doing this only inside `handle_call(:halt,
    # ...)` would queue the persistent_term write behind whatever tick
    # is in progress — a 75s signing round would defer the halt's
    # observable effect by the full duration.
    publish_halt_snapshot(true)
    GenServer.cast(__MODULE__, :halt)
    :ok
  end

  @doc "Resume auto-signing after a `halt/0`."
  @spec resume() :: :ok
  def resume do
    publish_halt_snapshot(false)
    GenServer.cast(__MODULE__, :resume)
    :ok
  end

  @doc "True if auto-signing is currently halted."
  @spec halted?() :: boolean()
  def halted? do
    GenServer.call(__MODULE__, :halted?)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc """
  Lock-free read of the halt flag via persistent_term. Safe to call
  from inside the Signer's own process — `halted?/0` would deadlock
  there because it issues a `GenServer.call` to itself.
  """
  @spec halted_snapshot() :: boolean()
  def halted_snapshot do
    :persistent_term.get({__MODULE__, :halted}, false)
  end

  # --- Broadcast Marker ---
  #
  # When the signing backend returns `{:ok, txid}` the tx is already
  # on chain. The post-submit bookkeeping (`mark_signing →
  # put_payout → mark_submitted → put_payout → finalize → mark_paid_out
  # → put_payout`) writes through the WAL with retry budget. If the
  # first WAL persist fails after the broadcast happened, the ETS row
  # is still `:rules_passed`. Without this marker the next tick would
  # call the backend a second time and broadcast a duplicate tx.
  #
  # The marker is durably persisted via the Federation.Store WAL —
  # `:broadcast_marker_set` is appended BEFORE the persistent_term
  # mirror is written, so a BEAM restart between backend success and
  # the bookkeeping replays the marker on boot and the Signer resumes
  # from the durable txid rather than re-calling the backend.
  # `advance(:rules_passed)` and `advance(:signing)` consult the
  # marker first; the marker is cleared once the Payout reaches
  # `:paid_out` (terminal — the txid is then durable on the Payout
  # struct itself).

  defp store_broadcast_marker(request_id, txid, persister)
       when is_binary(request_id) and is_binary(txid) and is_function(persister, 2) do
    persister.(request_id, txid)
  end

  defp fetch_broadcast_marker(request_id) when is_binary(request_id) do
    FederationStore.lookup_broadcast_marker(request_id)
  end

  @doc """
  Drops the broadcast marker for a request. Public so terminal-
  transition paths outside the Signer's auto-loop (operator abort,
  manual void) can clean up markers that would otherwise leak forever.
  """
  @spec clear_broadcast_marker(binary()) :: :ok
  def clear_broadcast_marker(request_id) when is_binary(request_id) do
    FederationStore.drop_broadcast_marker(request_id)
    :ok
  end

  # --- Backoff State ---

  # Reads when the next retry is allowed for a given request. `:none`
  # means "no failures recorded — try immediately."
  defp retry_due_at(request_id) when is_binary(request_id) do
    case :ets.lookup(@retry_table, request_id) do
      [{^request_id, %{next_at: %DateTime{} = at}}] -> at
      _ -> :none
    end
  end

  # Lock-free read used by the advance() guard. Safe because the
  # backoff is best-effort scheduling, not a correctness gate — a
  # racy read just means we retry one tick early.
  defp retry_due?(request_id, %DateTime{} = now) do
    case retry_due_at(request_id) do
      :none -> true
      %DateTime{} = at -> DateTime.compare(now, at) != :lt
    end
  end

  # Records a fresh failure for this request, advancing the backoff
  # schedule. Runs inside the Signer process; ETS table is :protected
  # so only this process writes.
  defp record_retry(request_id) when is_binary(request_id) do
    count =
      case :ets.lookup(@retry_table, request_id) do
        [{^request_id, %{count: n}}] -> n + 1
        _ -> 1
      end

    seconds = backoff_seconds(count)
    next_at = DateTime.add(DateTime.utc_now(), seconds, :second)
    :ets.insert(@retry_table, {request_id, %{count: count, next_at: next_at}})
    :ok
  end

  @doc """
  Drops the retry-backoff row for a request. Public so the operator
  console can force an immediate retry after diagnosing the underlying
  transient issue (e.g. wallet outputs unlocked, peer back online).
  Also called internally on backend success and terminal transitions.
  """
  @spec clear_retry(binary()) :: :ok
  def clear_retry(request_id) when is_binary(request_id) do
    ensure_retry_table()
    :ets.delete(@retry_table, request_id)
    :ok
  end

  defp backoff_seconds(count) when count > 0 do
    exp = min(count - 1, @backoff_max_exp)
    cap_ms = min(Bitwise.bsl(@backoff_base_ms, exp), @backoff_max_ms)

    # Full jitter: uniform in [1, cap_ms]. `:rand.uniform/1` requires
    # a positive integer and returns 1..N inclusive.
    jittered_ms = :rand.uniform(cap_ms)

    div(jittered_ms, 1000)
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    tick = Keyword.get(opts, :tick_interval_ms, get_config(:tick_interval_ms, @default_tick_interval_ms))
    backend = Keyword.get(opts, :signing_backend, configured_backend())
    rules_config = Keyword.get(opts, :rules_config, [])

    # Read the halt flag from persistent_term so a Signer crash +
    # supervisor restart does NOT silently wipe an operator-issued
    # halt. The flag is the sole carrier of halt state across the
    # process boundary; writing `false` here would mean every crash
    # of this GenServer resumes auto-signing without operator action.
    halted = :persistent_term.get({__MODULE__, :halted}, false)

    # Per-request backoff state. In-memory only — after a Signer
    # restart all retries reset to the immediate-attempt schedule,
    # which is the safe default (we lose no money, just retry sooner
    # than the prior backoff would have).
    ensure_retry_table()

    marker_persister =
      Keyword.get(opts, :marker_persister, &FederationStore.persist_broadcast_marker/2)

    state = %{
      tick_interval_ms: tick,
      signing_backend: backend,
      marker_persister: marker_persister,
      rules_config: rules_config,
      halted: halted
    }

    schedule_tick(state.tick_interval_ms)
    {:ok, state}
  end

  # `:public` so the operator console and integration tests can clear
  # backoff rows without routing through the Signer mailbox. The state
  # is advisory — a racy read just retries one tick early, never
  # double-spends, never strands a payout.
  defp ensure_retry_table do
    case :ets.whereis(@retry_table) do
      :undefined -> :ets.new(@retry_table, [:named_table, :set, :public])
      _ -> @retry_table
    end
  end

  defp publish_halt_snapshot(halted) when is_boolean(halted) do
    :persistent_term.put({__MODULE__, :halted}, halted)
  end

  @impl true
  def handle_call(:run_now, _from, state) do
    if drive_writes?(state), do: do_tick(state)
    {:reply, :ok, state}
  end

  def handle_call({:set_backend, backend}, _from, state) do
    {:reply, :ok, %{state | signing_backend: backend}}
  end

  def handle_call({:set_marker_persister, persister}, _from, state) do
    {:reply, :ok, %{state | marker_persister: persister}}
  end

  def handle_call(:halted?, _from, state) do
    {:reply, state.halted, state}
  end

  @impl true
  def handle_cast(:halt, state) do
    Logger.warning("Signer: auto-signing halted by operator")
    {:noreply, %{state | halted: true}}
  end

  def handle_cast(:resume, state) do
    Logger.info("Signer: auto-signing resumed by operator")
    {:noreply, %{state | halted: false}}
  end

  @impl true
  def handle_info(:tick, state) do
    if drive_writes?(state), do: do_tick(state)
    schedule_tick(state.tick_interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Auto-signing only runs on the service-tier node (N1 in the
  # default deployment — see `PerpWalk.Role`). N2 + N3 hold their
  # FROST shares and counter-sign when their share is requested,
  # but they do not drive the state machine. Driving from multiple
  # nodes would race the same payout's transitions through the
  # WAL and produce duplicate signing rounds.
  #
  # `Guard.verified?/0` gates the first tick on the wallet-address
  # check passing at least once. Without that gate, a WAL-recovered
  # :rules_passed payout could sign against a mis-opened wallet in
  # the boot window before the Guard's periodic check surfaces the
  # mismatch. Returns true immediately when no multisig is configured
  # (pre-ceremony boots), so early tick loops stay green.
  #
  # `Facade.quorum?/0` short-circuits the tick under peer-loss so we
  # don't spend each cycle RPC-timing-out against dead peers. No fund
  # risk from skipping (peers being down means no signature collected
  # anyway), but the log-storm without this gate is noisy enough to
  # mask real signals during a degraded window.
  #
  # Health-system halt (disk-critical, operator manual, or any
  # `@halt_alerts` member from `Telemetry.Health.System`) also gates
  # the tick. Pre-fix the health halt only fired at
  # `Guards.ensure_operational!` inside Markets writes — the Signer
  # kept ticking, its finalize path invoked `Cashier.mark_paid_out`
  # (which raised `SystemHaltedError`), and the raise propagated
  # up to `handle_info(:tick)`, crashing the Signer and eventually
  # exhausting the supervisor's restart budget. Halt semantics
  # for signing are now consistent with the operator model:
  # "halt blocks all writes" — including in-flight finalisation.
  # Queued `:submitted` payouts resume finalising on the next tick
  # after the halt clears; funds are on-chain either way, only
  # the Position/Dispute bookkeeping was delayed.
  defp drive_writes?(state) do
    not state.halted and not TelemetryFacade.halted?() and
      Role.designated_processor?() and Guard.verified?() and Facade.quorum?() and
      not reserves_drift_detected?()
  end

  # Refuse to sign while at least one guardian's most-recent
  # attestation round diverged from the leader's snapshot. Drift
  # signals stale multisig-info exchange or a peer's wallet view
  # disagreeing on unspent outputs — signing against a divergent
  # view risks broadcasting a tx that other guardians see as
  # spending outputs they don't recognise. Pre-fix this was
  # advisory-only: the telemetry alert fired but the signing loop
  # kept going. Halting is the fail-closed response until the drift
  # clears (next clean proof cycle) or an operator investigates.
  defp reserves_drift_detected? do
    case PerpWalk.Reserves.Drift.status() do
      %{divergent_peers: []} -> false
      %{divergent_peers: [_ | _]} -> true
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # --- Tick ---

  defp do_tick(state) do
    now = DateTime.utc_now()

    Facade.list_in_flight_requests()
    |> Enum.each(&drive_through(&1, now, state))
  end

  # Drive a single request as far through the pipeline as it can
  # go in one tick — :pending → :rules_passed → :submitted →
  # :paid_out (the Position transition). Stops on a transition
  # that doesn't auto-progress (:awaiting_operator), an error,
  # or a terminal state.
  defp drive_through(req, now, state) do
    case advance(req, now, state) do
      {:advanced, updated} -> drive_through(updated, now, state)
      :stop -> :ok
    end
  end

  defp advance(%Payout{status: :pending} = req, now, state) do
    case load_context(req, now, state.rules_config) do
      {:ok, ctx} ->
        case Rules.evaluate(ctx) do
          :ok ->
            case transition_to_rules_passed(req) do
              {:ok, updated} -> {:advanced, updated}
              :error -> :stop
            end

          {:reject, reason} ->
            transition_to_awaiting_operator(req, reason)
            :stop
        end

      {:error, reason} ->
        Logger.warning("Signer: cannot evaluate, request_id=#{req.id}, reason=#{inspect(reason)}")

        :stop
    end
  end

  defp advance(%Payout{status: :rules_passed} = req, now, state) do
    case fetch_broadcast_marker(req.id) do
      txid when is_binary(txid) ->
        # Prior tick: backend broadcast this txid, but the post-submit
        # WAL persist failed before we could transition to `:signing`.
        # Resume the bookkeeping without calling the backend again.
        Logger.warning("Signer: resuming bookkeeping for prior broadcast, request_id=#{req.id}, payout_txid=#{txid}")

        transition_through_signing(req, txid)
        :stop

      :none ->
        if retry_due?(req.id, now) do
          run_signing_round(req, now, state)
        else
          :stop
        end
    end
  end

  # ETS row last-persisted at `:signing` means `put_payout(:signing)`
  # succeeded but `put_payout(:submitted)` failed in a prior tick. The
  # broadcast marker carries the txid; resume from `mark_submitted`.
  defp advance(%Payout{status: :signing} = req, _now, _state) do
    case fetch_broadcast_marker(req.id) do
      txid when is_binary(txid) ->
        Logger.warning("Signer: resuming :signing bookkeeping, request_id=#{req.id}, payout_txid=#{txid}")

        resume_from_signing(req, txid)
        :stop

      :none ->
        # No marker means the request entered `:signing` via a path
        # that pre-dates the marker (operator console, legacy state).
        # The operator drives the next step.
        :stop
    end
  end

  # `:submitted` means the on-chain tx is broadcast and the txid is
  # persisted, but the Markets-side finalisation (mark_position_paid_out
  # / mark_dispute_refunded) failed previously. Funds aren't at risk;
  # the user-visible Position/Dispute state just lags. Retry the
  # finalisation step on subsequent ticks until it lands. Idempotent
  # because `Markets.Facade.mark_position_paid_out/2` is keyed on
  # position_id and Dispute.mark_refunded checks status.
  defp advance(%Payout{status: :submitted, payout_txid: txid} = req, _now, _state)
       when is_binary(txid) do
    case finalize(req) do
      :ok ->
        with {:ok, paid} <- Payout.mark_paid_out(req),
             :ok <- FederationStore.put_payout(paid) do
          EventBus.publish(%FederationEvents.PayoutSubmitted{
            request_id: paid.id,
            position_id: paid.position_id,
            payout_txid: txid,
            amount_piconeros: paid.amount_piconeros,
            timestamp: DateTime.utc_now()
          })

          clear_broadcast_marker(paid.id)
          :stop
        else
          {:error, reason} ->
            Logger.error("Signer: post-finalise transition failed, request_id=#{req.id}, reason=#{inspect(reason)}")

            :stop
        end

      {:error, reason} ->
        Logger.warning(
          "Signer: stuck-submitted finalisation retry failed, request_id=#{req.id}, reason=#{inspect(reason)}"
        )

        :stop
    end
  end

  # Ambiguous submit — auto-signer refuses to touch this. Operator
  # reconciles against wallet transfer history and drives the payout
  # to `:paid_out` (recovered txid) or `:failed` (confirmed
  # never-broadcast) via `Federation.Console.reconcile_settlement/3`.
  defp advance(%Payout{status: :settlement_unknown} = _req, _now, _state), do: :stop

  # Other in-flight statuses (:awaiting_operator, terminal) are not
  # auto-progressed by the Signer — the operator console drives them.
  defp advance(_req, _now, _state), do: :stop

  # Re-evaluate Rules immediately before signing — operator override
  # (force_sign) puts a request into :rules_passed without running the
  # rules engine, and underlying Markets/Federation state may have
  # changed since the original evaluation. Fail-closed: if rules
  # reject now, transition to :failed (terminal) so the request stops
  # counting as in-flight in ledger accounting. Operator can enqueue
  # a fresh request if they want to retry once state changes.
  defp run_signing_round(req, now, state) do
    with {:ok, ctx} <- load_context(req, now, state.rules_config),
         :ok <- Rules.evaluate(ctx) do
      case state.signing_backend.(req) do
        {:ok, txid} when is_binary(txid) ->
          # The broadcast has happened. Pin the txid in the WAL BEFORE
          # any further state change so a failure in the bookkeeping
          # below can be resumed by the next tick instead of issuing
          # a duplicate tx.
          #
          # If the marker persist itself fails (WAL back-pressure,
          # Sealer down), we cannot silently continue — the row is
          # still `:rules_passed` with no marker, and the next tick
          # would treat the payout as un-broadcast and re-invoke the
          # backend, double-paying. Pin the payout in
          # `:settlement_unknown` with the txid embedded in the reason
          # so the operator can reconcile trivially via
          # `Console.reconcile_paid_out(request_id, "<txid>")` after
          # verifying on-chain.
          case store_broadcast_marker(req.id, txid, state.marker_persister) do
            :ok ->
              clear_retry(req.id)
              transition_through_signing(req, txid)
              trigger_post_spend_multisig_sync(req.id)
              :stop

            {:error, reason} ->
              handle_marker_persist_failure(req, txid, reason)
              :stop
          end

        {:error, {:submit_ambiguous, why}} ->
          # The multisig submit RPC returned an outcome we cannot
          # classify — timeout, transport error, 5xx, null-result.
          # The tx MAY have been broadcast. Retrying with fresh coin
          # selection risks a double payment; leaving in `:rules_passed`
          # means the next tick auto-retries. Pin the payout in
          # `:settlement_unknown` (out of the auto-signer's reach)
          # and alert. Operator reconciles against wallet transfers
          # and drives resolution via console.
          Logger.error("Signer: submit ambiguous, request_id=#{req.id}, reason=#{inspect(why)}")

          transition_to_settlement_unknown(req, "submit_ambiguous: #{inspect(why)}")

          EventBus.publish(%FederationEvents.PayoutSettlementUnknown{
            request_id: req.id,
            reason: inspect(why),
            timestamp: DateTime.utc_now()
          })

          :stop

        {:error, {:permanent_failure, why}} ->
          # Wallet-side rejection that will never succeed under retry
          # — typo'd destination that passed the regex but fails the
          # wallet's base58 + Keccak checksum, malformed amount, etc.
          # Pre-fix these produced unbounded retry loops (uniqueness
          # slot held forever; operator had to manually abort). Route
          # to terminal `:failed` so the source can re-enqueue with
          # a corrected request.
          Logger.error("Signer: signing backend permanent failure, request_id=#{req.id}, reason=#{inspect(why)}")

          reason_str = "permanent_failure: #{inspect(why)}"
          transition_to_failed(req, reason_str)

          EventBus.publish(%FederationEvents.PayoutFailed{
            request_id: req.id,
            reason: reason_str,
            timestamp: DateTime.utc_now()
          })

          :stop

        {:error, reason} ->
          # Transient signing-backend failure — the payout stays in
          # `:rules_passed` and the next tick retries under the backoff
          # recorded by `record_retry/1`. Invariant: `PayoutFailed`
          # fires iff a Payout durably transitions to `:failed`, so
          # this transient path emits only a log line (and telemetry
          # via `record_retry`). Followers reconstruct terminal
          # failures via `Federation.Store.maybe_emit_event/1` on the
          # `:payout_requested` WAL entry that carries `status:
          # :failed`; a retry-and-succeed path yields a single
          # `PayoutSubmitted` event on both nodes with no transient
          # `PayoutFailed` flicker in between.
          Logger.warning("Signer: signing backend rejected, request_id=#{req.id}, reason=#{inspect(reason)}")

          record_retry(req.id)

          :stop
      end
    else
      {:reject, why} ->
        Logger.warning("Signer: rules re-validation failed at sign time, request_id=#{req.id}, reason=#{why}")

        reason = "rules_revalidation: #{why}"
        transition_to_failed(req, reason)

        EventBus.publish(%FederationEvents.PayoutFailed{
          request_id: req.id,
          reason: reason,
          timestamp: DateTime.utc_now()
        })

        :stop

      {:error, reason} ->
        Logger.warning("Signer: context load failed at sign time, request_id=#{req.id}, reason=#{inspect(reason)}")

        :stop
    end
  end

  # --- State Transitions ---

  defp transition_to_rules_passed(req) do
    with {:ok, updated} <- Payout.mark_rules_passed(req),
         :ok <- FederationStore.put_payout(updated) do
      EventBus.publish(%FederationEvents.RuleCheckPassed{
        request_id: updated.id,
        timestamp: DateTime.utc_now()
      })

      {:ok, updated}
    else
      {:error, reason} ->
        # Includes :wal_overloaded back-pressure — Signer leaves the
        # payout in its current state; the next tick re-attempts.
        Logger.warning("Signer: rules_passed transition failed, request_id=#{req.id}, reason=#{inspect(reason)}")

        :error
    end
  end

  defp transition_to_awaiting_operator(req, reason) do
    with {:ok, updated} <- Payout.mark_awaiting_operator(req, reason),
         :ok <- FederationStore.put_payout(updated) do
      clear_retry(updated.id)

      EventBus.publish(%FederationEvents.RuleCheckFailed{
        request_id: updated.id,
        reason: reason,
        timestamp: DateTime.utc_now()
      })
    else
      {:error, store_reason} ->
        # Includes :wal_overloaded back-pressure — Signer leaves the
        # payout in its current state; the next tick re-attempts.
        Logger.warning(
          "Signer: awaiting_operator transition failed, " <>
            "request_id=#{req.id}, reason=#{inspect(store_reason)}"
        )

        :ok
    end
  end

  # Broadcast marker failed to persist. The txid is
  # in-memory only — we have to move the payout out of the auto-signer's
  # reach RIGHT NOW to prevent the next tick from re-invoking the
  # backend. Two attempts, then fail closed by halting the whole Signer.
  defp handle_marker_persist_failure(req, txid, marker_reason) do
    Logger.error(
      "Signer: broadcast marker persist failed, request_id=#{req.id}, payout_txid=#{txid}, reason=#{inspect(marker_reason)}"
    )

    reason_str =
      "broadcast_marker_persist_failed: txid=#{txid}, reason=#{inspect(marker_reason)}"

    case transition_to_settlement_unknown(req, reason_str) do
      :ok ->
        EventBus.publish(%FederationEvents.PayoutSettlementUnknown{
          request_id: req.id,
          reason: reason_str,
          timestamp: DateTime.utc_now()
        })

      :error ->
        # Both the marker persist AND the settlement_unknown transition
        # failed — the WAL is fundamentally unavailable. Halting the
        # Signer is a big hammer, but the alternative is that the
        # next tick re-invokes the backend on a `:rules_passed` payout
        # whose broadcast we can't remember, doubling the payment.
        # Prefer a global stop over a silent double-pay; operator
        # investigates via logs (txid is written above) and resumes
        # once the WAL is healthy again.
        Logger.error(
          "Signer: catastrophic marker + settlement_unknown persist failure — halting, request_id=#{req.id}, payout_txid=#{txid}"
        )

        publish_halt_snapshot(true)

        EventBus.publish(%FederationEvents.SigningHalted{
          timestamp: DateTime.utc_now()
        })
    end
  end

  defp transition_to_settlement_unknown(req, reason) do
    with {:ok, updated} <- Payout.mark_settlement_unknown(req, reason),
         :ok <- safe_put_payout(updated) do
      clear_retry(updated.id)
      :ok
    else
      {:error, store_reason} ->
        # WAL back-pressure or invalid-transition — leave the payout
        # in its current state; the next tick re-attempts (which will
        # again hit the ambiguous submit and re-attempt this transition).
        # NEVER fall through to `record_retry` here: retrying signing
        # is precisely the double-payout path this transition closes.
        Logger.error(
          "Signer: settlement_unknown transition failed, request_id=#{req.id}, reason=#{inspect(store_reason)}"
        )

        :error
    end
  end

  # `FederationStore.put_payout` is a `GenServer.call`;
  # if the store is dead (BEAM restart mid-write, catastrophic
  # supervisor failure) the call raises an EXIT rather than returning
  # `{:error, _}`. Catch and translate so the settlement_unknown
  # transition path can distinguish a store-down catastrophe from a
  # normal WAL back-pressure `{:error, :wal_overloaded}` and still
  # reach `handle_marker_persist_failure`'s emergency-halt branch.
  defp safe_put_payout(updated) do
    FederationStore.put_payout(updated)
  rescue
    error ->
      Logger.error("Signer: put_payout raised, reason=#{inspect(error)}")
      {:error, {:store_raised, error}}
  catch
    :exit, reason ->
      Logger.error("Signer: put_payout exited, reason=#{inspect(reason)}")
      {:error, {:store_down, reason}}
  end

  defp transition_to_failed(req, reason) do
    with {:ok, updated} <- Payout.mark_failed(req, reason),
         :ok <- FederationStore.put_payout(updated) do
      clear_retry(updated.id)
      :ok
    else
      {:error, store_reason} ->
        Logger.warning(
          "Signer: failed-state transition failed, " <>
            "request_id=#{req.id}, reason=#{inspect(store_reason)}"
        )

        :ok
    end
  end

  # Called only after `state.signing_backend.(req)` returned `{:ok,
  # txid}` — i.e. the tx is already broadcast on-chain. Any failure
  # in this pipeline is post-submit bookkeeping, never a missing
  # payout. The retry path at `advance(:submitted, ...)` recovers
  # on subsequent ticks; the event below is the operator alert.
  defp transition_through_signing(req, txid) do
    with {:ok, signing} <- Payout.mark_signing(req),
         :ok <- FederationStore.put_payout(signing),
         :ok <- finish_after_signing(signing, txid) do
      :ok
    else
      {:error, reason} ->
        Logger.error(
          "Signer: post-submit finalisation failed, request_id=#{req.id}, payout_txid=#{txid}, reason=#{inspect(reason)}"
        )

        EventBus.publish(%FederationEvents.PayoutFinalizeFailed{
          request_id: req.id,
          payout_txid: txid,
          reason: format_reason(reason),
          timestamp: DateTime.utc_now()
        })
    end
  end

  defp resume_from_signing(req, txid) do
    case finish_after_signing(req, txid) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Signer: resume from :signing failed, request_id=#{req.id}, payout_txid=#{txid}, reason=#{inspect(reason)}"
        )

        EventBus.publish(%FederationEvents.PayoutFinalizeFailed{
          request_id: req.id,
          payout_txid: txid,
          reason: format_reason(reason),
          timestamp: DateTime.utc_now()
        })
    end
  end

  # Shared tail used by both the first-attempt and resume paths. Once
  # `put_payout(:paid_out)` succeeds the txid is durably reachable from
  # the row itself + WAL, so the marker is cleared.
  defp finish_after_signing(signing, txid) do
    with {:ok, submitted} <- Payout.mark_submitted(signing, txid),
         :ok <- FederationStore.put_payout(submitted),
         :ok <- finalize(submitted),
         {:ok, paid} <- Payout.mark_paid_out(submitted),
         :ok <- FederationStore.put_payout(paid) do
      EventBus.publish(%FederationEvents.PayoutSubmitted{
        request_id: paid.id,
        position_id: paid.position_id,
        payout_txid: txid,
        amount_piconeros: paid.amount_piconeros,
        timestamp: DateTime.utc_now()
      })

      maybe_publish_creator_lp_event(paid, txid)
      clear_broadcast_marker(paid.id)
      :ok
    end
  end

  # Dispatches the Markets-side finalisation by Payout kind: position
  # payouts (winner/refund) transition the Position to :paid_out;
  # dispute refunds transition the Dispute to :refunded_full /
  # :refunded_partial; federation income has no Markets-side state
  # to update — the Payout row itself is the durable audit trail.
  #
  # All Markets-side finalisers call `Guards.ensure_operational!`
  # which raises `SystemHaltedError` on halt. Historically the raise
  # propagated up through `finish_after_signing` →
  # `transition_through_signing` → `run_signing_round` →
  # `handle_info(:tick)` and crashed the Signer — repeated crashes
  # exhausted the supervisor's restart budget and took the node
  # down with in-flight bookkeeping wedged. `drive_writes?/1` now
  # gates the tick on the health halt so this path shouldn't fire
  # under a healthy operator model, but wrap defensively: any
  # unexpected raise from finalize is converted to a transient
  # `{:error, {:finalize_raised, ...}}` and the `:submitted`
  # retry loop picks it up on the next post-halt tick.
  defp finalize(%Payout{} = req) do
    do_finalize(req)
  rescue
    e ->
      Logger.warning("Signer: finalize raised, request_id=#{req.id}, reason=#{inspect(e)}")

      {:error, {:finalize_raised, e}}
  end

  @doc """
  Runs the Markets-side finalisation for a payout. Public for
  `Federation.Facade.reconcile_settlement/2` — the operator reconcile
  path must close out the Position/Dispute/Market state exactly like
  the Signer's own success path, or the claim stays open after the
  payout is durably paid on-chain.
  """
  @spec finalize_payout(Payout.t()) :: :ok | {:error, term()}
  def finalize_payout(%Payout{} = req), do: finalize(req)

  defp do_finalize(%Payout{kind: kind} = req)
       when kind in [:dispute_refund_full, :dispute_refund_partial] do
    case MarketsFacade.mark_dispute_refunded(req.account_id, req.market_id) do
      {:ok, _refunded} -> :ok
      {:error, reason} -> {:error, {:dispute_finalize_failed, reason}}
    end
  end

  defp do_finalize(%Payout{kind: :federation_income}), do: :ok

  # Quote-underpayment refunds have no Markets-side state to update.
  # The Quote row remains as-is (never filled — that's why the refund
  # exists); the durable audit trail is the Payout row plus the
  # Orphans.record(:underpayment, ...) written by the Poller.
  defp do_finalize(%Payout{kind: :quote_underpayment_refund}), do: :ok

  defp do_finalize(%Payout{kind: :creator_lp_return, market_id: market_id, payout_txid: txid}) do
    case MarketsFacade.mark_creator_lp_returned(market_id, txid) do
      {:ok, _market} -> :ok
      {:error, reason} -> {:error, {:creator_lp_finalize_failed, reason}}
    end
  end

  defp do_finalize(%Payout{position_id: position_id, payout_txid: txid}) do
    case MarketsFacade.mark_position_paid_out(position_id, txid) do
      {:ok, _paid} -> :ok
      {:error, reason} -> {:error, {:position_finalize_failed, reason}}
    end
  end

  # Side-channel emission of the LP-specific event, distinct from the
  # generic PayoutSubmitted. Consumers (Nostr publisher, portfolio
  # LiveView) subscribe to this rather than filter PayoutSubmitted by
  # kind. Kept here in the Signer so it always co-fires with the
  # generic event — no risk of a downstream observer missing one.
  defp maybe_publish_creator_lp_event(
         %Payout{
           kind: :creator_lp_return,
           market_id: market_id,
           account_id: creator_account_id,
           amount_piconeros: amount
         },
         txid
       ) do
    EventBus.publish(%PerpWalk.Events.Markets.CreatorLpReturned{
      market_id: market_id,
      creator_account_id: creator_account_id,
      amount_piconeros: amount,
      txid: txid,
      timestamp: DateTime.utc_now()
    })
  end

  defp maybe_publish_creator_lp_event(_payout, _txid), do: :ok

  # Fire-and-forget multisig info exchange across federation peers.
  # Monero N-of-M multisig hides spend-state from non-signing
  # participants by design; without this sync, follower wallets
  # accumulate phantom unspent outputs from spends they didn't sign,
  # which eventually breaks proof-of-reserves attestation. Async so
  # the signing path doesn't block on RPC round-trips; failures are
  # logged but not fatal because the periodic `Monero.Multisig.Scheduler`
  # catches any drift the post-spend hook misses.
  defp trigger_post_spend_multisig_sync(request_id) do
    Task.start(fn ->
      case PerpWalk.Monero.Facade.sync_multisig_with_peers(triggered_by: {:post_spend, request_id}) do
        {:ok, %{outputs_imported: n}} ->
          Logger.info("Signer: post-spend multisig sync complete, request_id=#{request_id}, outputs_imported=#{n}")

        {:error, reason} ->
          Logger.warning("Signer: post-spend multisig sync failed, request_id=#{request_id}, reason=#{inspect(reason)}")
      end
    end)

    :ok
  end

  # --- Rule Evaluation Context ---

  # Dispute refunds skip the position lookup — they're keyed by
  # (account_id, market_id) and have no associated Position.
  # Federation income withdrawals skip BOTH position and market —
  # they sweep across all markets, not bound to any single one.
  # The withdrawable balance is loaded HERE and passed through ctx
  # so the Rules engine stays pure (no live state reads inside).
  defp load_context(%Payout{kind: :federation_income} = req, now, rules_config) do
    {:ok,
     %{
       request: req,
       position: nil,
       market: nil,
       now: now,
       recent_requests: recent_requests_excluding(req),
       config: rules_config,
       withdrawable_piconeros: PerpWalk.Markets.Federation.Ledger.withdrawable_piconeros()
     }}
  end

  # Quote-underpayment refunds carry no Position (the quote never
  # filled). The Rules engine looks up the source Quote directly
  # via MarketsFacade for its amount-bound sanity check, so we don't
  # need to preload it here. Market is skipped too — the refund is
  # independent of market state.
  defp load_context(%Payout{kind: :quote_underpayment_refund} = req, now, rules_config) do
    {:ok,
     %{
       request: req,
       position: nil,
       market: nil,
       now: now,
       recent_requests: recent_requests_excluding(req),
       config: rules_config
     }}
  end

  defp load_context(%Payout{} = req, now, rules_config) do
    with {:ok, position} <- maybe_load_position(req),
         {:ok, market} <- MarketsFacade.get_market(req.market_id) do
      {:ok,
       %{
         request: req,
         position: position,
         market: market,
         now: now,
         recent_requests: recent_requests_excluding(req),
         config: rules_config
       }}
    end
  end

  defp maybe_load_position(%Payout{position_id: nil}), do: {:ok, nil}
  defp maybe_load_position(%Payout{position_id: id}), do: MarketsFacade.get_position(id)

  # The request under evaluation is already persisted (updated_at
  # inside the rate window), and the rate-cap rules add its amount
  # on top as `projected` — leaving it in recent_requests counts it
  # twice and halves the effective caps.
  defp recent_requests_excluding(%Payout{id: id}) do
    Enum.reject(Facade.list_requests(), &(&1.id == id))
  end

  # --- Helpers ---

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp get_config(key, default) do
    Application.get_env(:perpwalk, :federation_signer, [])
    |> Keyword.get(key, default)
  end

  # Resolves the signing backend from config when not provided as an
  # opt. The config can carry a 1-arity capture (`{Mod, :fun}` or a
  # function) and we coerce to a callable. Defaults to the stub so a
  # misconfigured node refuses to sign rather than silently falling
  # back to something dangerous.
  defp configured_backend do
    case get_config(:signing_backend, :stub) do
      :stub ->
        &__MODULE__.stub_signing_backend/1

      {module, function} when is_atom(module) and is_atom(function) ->
        Function.capture(module, function, 1)

      fun when is_function(fun, 1) ->
        fun
    end
  end

  # --- Stub Backend (default) ---

  @doc """
  Default signing backend — refuses to sign so the Signer never
  auto-completes a payout in the absence of an explicit production
  backend. Production replaces this via config (`:perpwalk,
  :federation_signer, :signing_backend`) with the real multi-round
  Monero multisig coordinator at
  `PerpWalk.Federation.Signing.Monero.sign/1`.
  """
  @spec stub_signing_backend(Payout.t()) :: {:error, :no_signing_backend_configured}
  def stub_signing_backend(_request), do: {:error, :no_signing_backend_configured}
end
