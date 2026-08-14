defmodule PerpWalk.Federation.Facade do
  @moduledoc """
  Published Language facade for the Federation bounded context.

  Markets's Cashier calls `enqueue_payout/3` to queue an outflow
  for federation signing. The Federation owns everything from
  Payout creation through 2-of-3 multisig signing through
  on-chain submission and final state transition.

  All functions are crash-safe — failures in the Store or signing
  layer are returned as `{:error, _}` rather than letting exits
  propagate.
  """

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents
  alias PerpWalk.Federation.{Audit, Payout, Signer, Store}
  alias PerpWalk.Markets.{Dispute, Position}

  @doc """
  Creates a `:pending` Payout for `position` and persists it
  atomically — refuses with `:payout_already_pending` if another
  in-flight payout already exists for the same `position_id`.
  Picked up by `Federation.Signer` which runs the Rules engine
  and coordinates the 2-of-3 multisig signing.

  Atomicity is enforced inside `Federation.Store` (the existence
  check and the WAL+ETS write share one handle_call), so two
  concurrent callers can't both succeed for the same position.
  """
  @spec enqueue_payout(Position.t(), pos_integer(), String.t()) ::
          {:ok, Payout.t()} | {:error, :payout_already_pending | term()}
  def enqueue_payout(%Position{} = position, amount_piconeros, destination)
      when is_integer(amount_piconeros) and amount_piconeros > 0 and
             is_binary(destination) and byte_size(destination) > 0 do
    position
    |> Payout.new(amount_piconeros, destination)
    |> Store.put_payout_unique_for_position()
  end

  @doc """
  Creates a `:pending` Payout for a resolved `dispute` and
  persists it atomically — refuses with `:refund_already_pending`
  if another in-flight refund already exists for the same
  `(account_id, market_id)`. Same downstream pipeline as
  `enqueue_payout/3` — the Signer runs Rules, signs, submits, and
  finalises (transitioning the Dispute to `:refunded_full` or
  `:refunded_partial`).
  """
  @spec enqueue_dispute_refund(Dispute.t(), pos_integer(), String.t()) ::
          {:ok, Payout.t()} | {:error, :refund_already_pending | term()}
  def enqueue_dispute_refund(%Dispute{} = dispute, amount_piconeros, destination)
      when is_integer(amount_piconeros) and amount_piconeros > 0 and
             is_binary(destination) and byte_size(destination) > 0 do
    dispute
    |> Payout.new_dispute_refund(amount_piconeros, destination)
    |> Store.put_payout_unique_for_dispute()
  end

  @doc """
  Enqueues a federation-income withdrawal — sweeps a portion of the
  accumulated federation revenue (slash + burn + 5/6 of trade
  spread) to a guardian-specified destination address. Subject to
  the same Rules + 2-of-3 multisig signing pipeline as user payouts.

  `requesting_account_id` is the operator's account id, recorded for
  audit. The Signer's rules engine enforces that `amount_piconeros`
  ≤ `Markets.Federation.Ledger.withdrawable_piconeros/0` at sign
  time so a stale console snapshot can't over-draw.
  """
  @spec enqueue_federation_income_withdrawal(pos_integer(), String.t(), String.t()) ::
          {:ok, Payout.t()} | {:error, term()}
  def enqueue_federation_income_withdrawal(amount_piconeros, destination, requesting_account_id)
      when is_integer(amount_piconeros) and amount_piconeros > 0 and
             is_binary(destination) and byte_size(destination) > 0 and
             is_binary(requesting_account_id) do
    payout = Payout.new_federation_income(amount_piconeros, destination, requesting_account_id)

    Store.put_payout_unique_for_federation_income(payout)
  end

  @doc """
  Enqueues a creator liquidity return. Idempotent per market —
  refuses with `:lp_return_already_pending` if another non-terminal
  payout of this kind already references the same market. Same
  downstream pipeline as other payouts (Rules → multisig signing →
  on-chain submission).

  Amount must equal the deterministic residual for the market's
  current state — `Federation.Rules.amount_match/1` re-derives it
  from `market.pool` (settled) or `market.deposit_amount` (voided)
  and rejects any drift.
  """
  @spec enqueue_creator_lp_return(binary(), binary(), pos_integer(), String.t()) ::
          {:ok, Payout.t()} | {:error, :lp_return_already_pending | term()}
  def enqueue_creator_lp_return(market_id, creator_account_id, amount_piconeros, destination)
      when is_binary(market_id) and is_binary(creator_account_id) and
             is_integer(amount_piconeros) and amount_piconeros > 0 and
             is_binary(destination) and byte_size(destination) > 0 do
    market_id
    |> Payout.new_creator_lp_return(creator_account_id, amount_piconeros, destination)
    |> Store.put_payout_unique_for_creator_lp()
  end

  @doc """
  Enqueues an auto-refund for a Quote whose on-chain deposit fell
  short of the locked amount. Idempotent per source Quote — a Poller
  re-fire on the same txid returns
  `:quote_underpayment_refund_already_pending` instead of producing a
  second Payout row. Downstream pipeline is the same as every other
  payout: Rules → 2-of-3 multisig signing → on-chain submission.
  """
  @spec enqueue_quote_underpayment_refund(
          binary(),
          binary(),
          binary(),
          pos_integer(),
          String.t()
        ) ::
          {:ok, Payout.t()}
          | {:error, :quote_underpayment_refund_already_pending | term()}
  def enqueue_quote_underpayment_refund(
        quote_id,
        account_id,
        market_id,
        amount_piconeros,
        destination
      )
      when is_binary(quote_id) and byte_size(quote_id) > 0 and
             is_binary(account_id) and is_binary(market_id) and
             is_integer(amount_piconeros) and amount_piconeros > 0 and
             is_binary(destination) and byte_size(destination) > 0 do
    quote_id
    |> Payout.new_quote_underpayment_refund(account_id, market_id, amount_piconeros, destination)
    |> Store.put_payout_unique_for_quote_underpayment()
  end

  @doc """
  Total federation income that has already been withdrawn (sum of
  `:federation_income` payouts in any non-failed state). The
  Markets-domain Ledger subtracts this from the earned total to
  derive the still-withdrawable balance.
  """
  @spec federation_income_drawn() :: non_neg_integer()
  def federation_income_drawn do
    :federation_income
    |> Store.list_payouts_by_kind()
    |> Enum.filter(&(&1.status != :failed))
    |> Enum.reduce(0, fn p, acc -> acc + p.amount_piconeros end)
  rescue
    _ -> 0
  end

  @doc "Fetches a Payout by id."
  @spec get_request(binary()) :: {:ok, Payout.t()} | {:error, :not_found}
  defdelegate get_request(id), to: Store, as: :get_payout

  @doc """
  Operator override: clear an `:awaiting_operator` request to
  `:rules_passed` so the Signer picks it up on the next tick.
  Used by `Federation.Console.force_sign/1`.
  """
  @spec force_approve(binary()) ::
          {:ok, Payout.t()} | {:error, :not_found | :invalid_transition}
  def force_approve(request_id) when is_binary(request_id) do
    with {:ok, req} <- Store.get_payout(request_id),
         {:ok, updated} <- Payout.mark_force_approved(req),
         :ok <- Store.put_payout(updated) do
      now = DateTime.utc_now()

      EventBus.publish(%FederationEvents.OperatorOverride{
        request_id: req.id,
        previous_reason: req.rule_failure_reason,
        timestamp: now
      })

      # Persist the override beyond the in-memory PubSub broadcast.
      # Without this row, post-incident reconstruction can only see
      # "Payout had a rule_failure_reason and ended up :rules_passed"
      # — it loses who/when/from-which-node, which matters when
      # multiple operators have console access.
      Audit.record(:operator_override, %{
        request_id: req.id,
        previous_status: req.status,
        previous_reason: req.rule_failure_reason,
        amount_piconeros: req.amount_piconeros,
        kind: req.kind,
        destination: req.destination,
        at: now
      })

      {:ok, updated}
    end
  end

  @doc """
  Marks a request `:failed` with `reason`. Used by
  `Federation.Console.abort/2` for stuck `:signing` / `:submitted`
  requests after a crash mid-round; not part of the auto-loop.
  """
  @spec abort_request(binary(), String.t()) ::
          {:ok, Payout.t()} | {:error, :not_found | :invalid_transition}
  def abort_request(request_id, reason)
      when is_binary(request_id) and is_binary(reason) do
    with {:ok, req} <- Store.get_payout(request_id),
         {:ok, updated} <- Payout.mark_failed(req, reason),
         :ok <- Store.put_payout(updated) do
      now = DateTime.utc_now()

      # Drop any persistent_term broadcast marker the Signer may have
      # set for this request. The auto-loop normally clears markers
      # on the success path through `transition_through_signing`; the
      # abort path is the explicit terminal-failure cousin and needs
      # the same hygiene to avoid persistent_term leaks across the
      # lifetime of the BEAM.
      Signer.clear_broadcast_marker(req.id)

      EventBus.publish(%FederationEvents.PayoutFailed{
        request_id: req.id,
        reason: "operator_abort: #{reason}",
        timestamp: now
      })

      Audit.record(:operator_abort, %{
        request_id: req.id,
        previous_status: req.status,
        reason: reason,
        amount_piconeros: req.amount_piconeros,
        kind: req.kind,
        destination: req.destination,
        at: now
      })

      {:ok, updated}
    end
  end

  @doc """
  Reconciles a `:settlement_unknown` payout after the operator has
  checked wallet transfer history against the request destination
  and amount.

    * `{:paid_out, txid}` — operator confirmed the tx IS on-chain;
      supplies the txid recovered from `wallet-rpc get_transfers`.
      Transitions `:settlement_unknown` → `:paid_out` and pins the
      txid. Emits `PayoutSubmitted` so downstream consumers
      (portfolio LiveView, Nostr publisher) observe the completion.
    * `{:failed, reason}` — operator confirmed no broadcast ever
      happened. Transitions `:settlement_unknown` → `:failed` so
      the source (Position, Dispute, etc.) can re-enqueue a fresh
      Payout.

  Refuses on any status other than `:settlement_unknown`.
  """
  @spec reconcile_settlement(
          binary(),
          {:paid_out, String.t()} | {:failed, String.t()}
        ) :: {:ok, Payout.t()} | {:error, :not_found | :invalid_transition}
  def reconcile_settlement(request_id, {:paid_out, txid})
      when is_binary(request_id) and is_binary(txid) and byte_size(txid) > 0 do
    with {:ok, req} <- Store.get_payout(request_id),
         {:ok, updated} <- Payout.mark_reconciled_paid_out(req, txid),
         # The operator confirmed the tx is on-chain — close out the
         # Markets-side entity (Position → :paid_out, Dispute →
         # :refunded_*, creator-LP stamp) BEFORE the payout goes
         # terminal. Without this step the claim surface stays open:
         # the uniqueness scope drops on the terminal transition while
         # the source entity still reads payable, and a second claim
         # passes Rules unchanged — a double payment.
         :ok <- Signer.finalize_payout(updated),
         :ok <- Store.put_payout(updated) do
      now = DateTime.utc_now()

      Signer.clear_broadcast_marker(req.id)

      EventBus.publish(%FederationEvents.PayoutSubmitted{
        request_id: updated.id,
        position_id: updated.position_id,
        payout_txid: txid,
        amount_piconeros: updated.amount_piconeros,
        timestamp: now
      })

      Audit.record(:reconcile_paid_out, %{
        request_id: req.id,
        payout_txid: txid,
        amount_piconeros: req.amount_piconeros,
        kind: req.kind,
        destination: req.destination,
        at: now
      })

      {:ok, updated}
    end
  end

  def reconcile_settlement(request_id, {:failed, reason})
      when is_binary(request_id) and is_binary(reason) do
    with {:ok, req} <- Store.get_payout(request_id),
         {:ok, updated} <- Payout.mark_reconciled_failed(req, reason),
         :ok <- Store.put_payout(updated) do
      now = DateTime.utc_now()

      Signer.clear_broadcast_marker(req.id)

      EventBus.publish(%FederationEvents.PayoutFailed{
        request_id: req.id,
        reason: "reconciled_no_broadcast: #{reason}",
        timestamp: now
      })

      Audit.record(:reconcile_failed, %{
        request_id: req.id,
        reason: reason,
        amount_piconeros: req.amount_piconeros,
        kind: req.kind,
        destination: req.destination,
        at: now
      })

      {:ok, updated}
    end
  end

  @doc "All payout requests, regardless of status."
  @spec list_requests() :: [Payout.t()]
  defdelegate list_requests(), to: Store, as: :list_payouts

  @doc """
  True if a non-terminal `:quote_underpayment_refund` payout exists
  for the given Quote. The Markets scheduler consults this to defer
  expiring a Quote whose refund is still in flight — the refund's
  rules check re-reads the quote row for its amount bound.
  """
  @spec quote_underpayment_pending?(binary()) :: boolean()
  def quote_underpayment_pending?(quote_id) when is_binary(quote_id) do
    :quote_underpayment_refund
    |> Store.list_payouts_by_kind()
    |> Enum.any?(fn p -> p.source_quote_id == quote_id and Payout.in_flight?(p) end)
  end

  @doc "Payout requests for a specific position."
  @spec list_requests_for_position(binary()) :: [Payout.t()]
  defdelegate list_requests_for_position(position_id), to: Store, as: :list_payouts_for_position

  @doc "Payout requests in a specific status (e.g. `:pending`, `:awaiting_operator`)."
  @spec list_requests_by_status(Payout.status()) :: [Payout.t()]
  defdelegate list_requests_by_status(status), to: Store, as: :list_payouts_by_status

  @doc "All requests still in flight (non-terminal status)."
  @spec list_in_flight_requests() :: [Payout.t()]
  defdelegate list_in_flight_requests(), to: Store, as: :list_in_flight_payouts

  @doc """
  Applies a list of WAL entries to the local Federation ETS table.
  Storage-domain entry point used by `Storage.Replicator`; in the
  symmetric bi-directional model every node applies entries from
  its peers.

  See `PerpWalk.Federation.Store.replicate_entries/1`.
  """
  @spec replicate_entries([Locker.WAL.Entry.t()]) :: :ok
  defdelegate replicate_entries(entries), to: Store

  # --- Federation Runtime Status ---
  #
  # These wrap the underlying Cartel runtime so Telemetry and the
  # admin dashboard don't have to import Cartel directly. The
  # Federation domain owns the boundary; Cartel is an implementation
  # detail.

  @doc """
  True if the federation has enough peers online to meet its signing
  threshold. Returns false (fail-closed) if the runtime is unavailable
  — `quorum_lost?/0` and every caller that gates on it is treating
  "we can't tell" as "we don't have quorum", which is the only safe
  posture when funds depend on the answer.
  """
  @spec quorum?() :: boolean()
  def quorum? do
    Cartel.quorum?()
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc """
  True when quorum is intact but at least one peer is offline — the
  safety margin has been eaten and a second peer failure would lose
  quorum. Drives the `:degraded` PIP state on every public LiveView.
  """
  @spec degraded?() :: boolean()
  def degraded? do
    quorum?() and online_peer_count() + 1 < member_count()
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc """
  True when online peer count has dropped below the signing threshold.
  Drives HALTED state: new-liability writes (quote generation, market
  creation, position purchase) are refused at the application layer
  until quorum returns.
  """
  @spec quorum_lost?() :: boolean()
  def quorum_lost?, do: not quorum?()

  @doc """
  Single source of truth for the footer federation PIP colour across
  both user and admin surfaces:

    - `:critical` — quorum lost OR operator has halted signing
      (either state means new liability writes are refused).
    - `:degraded` — quorum intact but at least one peer is offline
      (safety margin gone; second failure would lose quorum).
    - `:ok` — full member set online, signing enabled.

  Admin used to derive this from `Telemetry.Facade.health_components`,
  which drives its `:federation` entry from active alerts. There is no
  alert for the "quorum intact but peer down" case, so the admin pip
  never turned yellow at 2/3 — it stayed orange while user side
  correctly went to `:degraded`. Both surfaces call this now.
  """
  @spec pip_status() :: :ok | :degraded | :critical
  def pip_status do
    cond do
      quorum_lost?() -> :critical
      halted?() -> :critical
      degraded?() -> :degraded
      true -> :ok
    end
  end

  @doc """
  Total federation members configured (this node + peers). Returns
  1 if the runtime is unavailable.
  """
  @spec member_count() :: pos_integer()
  def member_count do
    Cartel.Supervisor.config().n
  rescue
    _ -> 1
  catch
    :exit, _ -> 1
  end

  @doc """
  Currently online peer count (excludes this node). Returns 0 if
  the runtime is unavailable.
  """
  @spec online_peer_count() :: non_neg_integer()
  def online_peer_count do
    Cartel.connected_count()
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  @doc """
  Configured peer node atoms (excludes this node), sorted for
  deterministic iteration. Returns `[]` if the runtime is
  unavailable.

  These are *configured* peers, not just currently-online ones —
  callers needing the live-online view should use
  `online_peer_count/0`. Use this for fanout to every peer the
  federation expects to see (Monero signing rounds, reserves
  attestation broadcasts, leader-probe split-brain detection).

  Injectable seam: `config :perpwalk, :federation, peer_nodes_override: [...]`
  short-circuits the runtime lookup. Application boot gates this to
  non-production environments only; production refuses to start with
  the override set (see `PerpWalk.Application.assert_no_peer_nodes_override!/0`).
  """
  @spec peer_nodes() :: [atom()]
  def peer_nodes do
    case Application.get_env(:perpwalk, :federation, [])
         |> Keyword.get(:peer_nodes_override) do
      nil -> peers_from_runtime()
      list when is_list(list) -> list
    end
  end

  defp peers_from_runtime do
    Cartel.config().peer_nodes
    |> Map.values()
    |> Enum.sort()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc """
  Threshold required to sign (e.g. 2 in a 2-of-3 federation).
  Returns 1 if the runtime is unavailable.
  """
  @spec threshold() :: pos_integer()
  def threshold do
    Cartel.Supervisor.config().t
  rescue
    _ -> 1
  catch
    :exit, _ -> 1
  end

  @doc """
  True if the operator has halted federation auto-signing via
  `Federation.Console.halt/0`. Returns false if the runtime is
  unavailable.
  """
  @spec halted?() :: boolean()
  def halted? do
    Signer.halted?()
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc """
  Halts federation auto-signing. Cross-domain entry point — other
  domains (Monero.Poller on reorg detection, MultisigGuard on
  address mismatch, telemetry on critical alerts) call this rather
  than reaching directly into `Federation.Signer`.

  Idempotent. Safe to call repeatedly; the underlying Signer
  already swallows duplicate halts.
  """
  @spec halt_signing() :: :ok
  def halt_signing do
    Signer.halt()
  rescue
    err ->
      require Logger
      Logger.error("Facade: halt_signing raised, reason=#{inspect(err)}")
      :ok
  catch
    :exit, reason ->
      require Logger
      Logger.error("Facade: halt_signing exited, reason=#{inspect(reason)}")
      :ok
  end

  @doc """
  Appends an operator-action event to the durable audit log.
  Cross-domain entry point so external callers (Monero.Poller for
  reorg telemetry, telemetry for alert escalation) don't reach
  directly into `Federation.Audit`.
  """
  @spec record_audit(atom(), map()) :: :ok
  def record_audit(kind, details) when is_atom(kind) and is_map(details) do
    Audit.record(kind, details)
  end

  @doc """
  The expected multisig address from production config (set by the
  bootstrap ceremony and pinned in vault). Returns `nil` when not
  yet configured — the case that holds before the ceremony runs.
  """
  @spec expected_multisig_address() :: String.t() | nil
  def expected_multisig_address do
    Application.get_env(:perpwalk, :multisig_address)
  end

  @doc """
  Verifies the wallet RPC reports the configured multisig address.

  Returns `:ok` when wallet's `get_address` matches the configured
  expected address, or `{:error, reason}` describing the mismatch.
  Skips the check (returns `:ok`) when `expected_multisig_address/0`
  is nil — pre-ceremony boots should not block on missing config.
  """
  @spec verify_multisig_address() :: :ok | {:error, term()}
  def verify_multisig_address do
    case expected_multisig_address() do
      nil ->
        :ok

      expected when is_binary(expected) ->
        case PerpWalk.Monero.Facade.address() do
          {:ok, ^expected} -> :ok
          {:ok, actual} -> {:error, {:address_mismatch, expected: expected, actual: actual}}
          {:error, reason} -> {:error, {:wallet_unavailable, reason}}
        end
    end
  end

  # --- Federation RPC (used by reserves attestation collector) ---

  @doc "Signs a federation RPC request. See `Federation.RPC.Auth.sign_request/2`."
  @spec sign_rpc_request(atom(), term()) :: map()
  defdelegate sign_rpc_request(method, args), to: PerpWalk.Federation.RPC.Auth, as: :sign_request

  @doc "Verifies a federation RPC response. See `Federation.RPC.Auth.verify_response/3`."
  @spec verify_rpc_response(term(), atom(), binary()) :: {:ok, term()} | {:error, term()}
  defdelegate verify_rpc_response(response, method, expected_nonce),
    to: PerpWalk.Federation.RPC.Auth,
    as: :verify_response

  @doc """
  Dispatches a federation RPC call to the peer's RPC handler. Wraps
  `:rpc.call/5` against the federation's `RPC.Peer` module so the
  caller doesn't need to know the remote module name. Used by the
  reserves attestation collector.
  """
  @spec rpc_call_peer(node(), atom(), map(), pos_integer()) :: term()
  def rpc_call_peer(node, method, request, timeout) do
    :rpc.call(node, PerpWalk.Federation.RPC.Peer, method, [request], timeout)
  end
end
