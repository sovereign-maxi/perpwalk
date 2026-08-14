defmodule PerpWalk.Federation.Console do
  @moduledoc """
  Operator-facing iex helpers for Federation operations.

  All mutating operations are deliberately iex-only — there is no
  HTTP endpoint, no LiveView form. Operator presence at a terminal
  is itself a security control: a stolen browser session can't
  force-sign a payout, can't halt the federation, can't rotate
  keys.

  ## Usage

  Connect to a running node:

      $ iex --remsh perpwalk@anchor-1

  Then:

      iex> PerpWalk.Federation.Console.list_pending()
      iex> PerpWalk.Federation.Console.review("abc123...")
      iex> PerpWalk.Federation.Console.force_sign("abc123...")
      iex> PerpWalk.Federation.Console.reconcile_paid_out("abc123...", "txid")
      iex> PerpWalk.Federation.Console.reconcile_failed("abc123...", "no_matching_transfer")
      iex> PerpWalk.Federation.Console.halt()
      iex> PerpWalk.Federation.Console.resume()
      iex> PerpWalk.Federation.Console.rotate_keys()
      iex> PerpWalk.Federation.Console.current_processor()
      iex> PerpWalk.Federation.Console.promote_processor(:p2)

  ## Output

  Functions that print return `:ok`; functions that return data
  return the data structure. Where there's no obvious value to
  return (`halt/0`, `resume/0`), the function returns `:ok` after
  applying the action.
  """

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents
  alias PerpWalk.Federation.{Audit, Bootstrap, Facade, Payout, Signer}
  alias PerpWalk.Federation.Store, as: FederationStore
  alias PerpWalk.Role

  @doc """
  Prints a summary of every in-flight payout request, grouped by
  status. Returns `:ok`.
  """
  @spec list_pending() :: :ok
  def list_pending do
    requests = Facade.list_in_flight_requests()

    if requests == [] do
      IO.puts("No in-flight payout requests.")
    else
      requests
      |> Enum.group_by(& &1.status)
      |> Enum.each(fn {status, reqs} ->
        IO.puts("\n[#{status}] (#{length(reqs)})")

        Enum.each(reqs, fn r ->
          IO.puts(
            "  #{short(r.id)}  position=#{short(r.position_id)}  amount=#{format_xmr(r.amount_piconeros)}  age=#{age(r.created_at)}"
          )
        end)
      end)
    end

    :ok
  end

  @doc """
  Prints full detail for a single request — fields, current state,
  rule_failure_reason if any, and the on-chain txid if submitted.
  Returns the request struct.
  """
  @spec review(binary()) :: Payout.t() | {:error, :not_found}
  def review(request_id) when is_binary(request_id) do
    case Facade.get_request(request_id) do
      {:ok, req} ->
        IO.puts("""

        Request #{req.id}
          status:           #{req.status}
          kind:             #{req.kind}
          position_id:      #{req.position_id}
          market_id:        #{req.market_id}
          account_id:       #{req.account_id}
          amount:           #{format_xmr(req.amount_piconeros)}
          destination:      #{req.destination}
          created_at:       #{req.created_at}
          updated_at:       #{req.updated_at}
          payout_txid:      #{req.payout_txid || "—"}
          rule_failure:     #{req.rule_failure_reason || "—"}
        """)

        req

      {:error, :not_found} = err ->
        IO.puts("Request #{request_id} not found.")
        err
    end
  end

  @doc """
  Operator override: force-approve a `:awaiting_operator` request
  by transitioning it back to `:rules_passed`. The Signer will
  pick it up on the next tick (or call `Signer.run_now/0` to
  apply immediately).

  Returns the updated request, or `{:error, :not_found |
  :invalid_transition}`.
  """
  @spec force_sign(binary()) ::
          {:ok, Payout.t()} | {:error, :not_found | :invalid_transition | :halted}
  def force_sign(request_id) when is_binary(request_id) do
    if Signer.halted?() do
      IO.puts(
        "force_sign refused: Signer is halted. Resume first (after verifying " <>
          "the halt cause) or coordinate with the operator who issued the halt."
      )

      {:error, :halted}
    else
      do_force_sign(request_id)
    end
  end

  defp do_force_sign(request_id) do
    case Facade.force_approve(request_id) do
      {:ok, updated} ->
        IO.puts("Forced #{short(updated.id)} → :rules_passed (was :awaiting_operator)")
        IO.puts("Run Signer.run_now/0 to apply immediately, or wait for the next tick.")
        {:ok, updated}

      {:error, :invalid_transition} = err ->
        IO.puts("Request not in :awaiting_operator status; force_sign refused.")
        err

      {:error, :not_found} = err ->
        IO.puts("Request #{request_id} not found.")
        err
    end
  end

  @doc """
  Halt all auto-signing on this node. Use when something looks
  wrong and you want every payout queued for manual review before
  any further signatures land on-chain. Other guardians remain
  unaffected — halt is local.
  """
  @spec halt() :: :ok
  def halt do
    Signer.halt()
    now = DateTime.utc_now()
    EventBus.publish(%FederationEvents.SigningHalted{timestamp: now})
    Audit.record(:signing_halted, %{at: now})
    IO.puts("Federation auto-signing HALTED on this node. Other peers unaffected.")
    :ok
  end

  @doc "Resume auto-signing after `halt/0`."
  @spec resume() :: :ok
  def resume do
    Signer.resume()
    now = DateTime.utc_now()
    EventBus.publish(%FederationEvents.SigningResumed{timestamp: now})
    Audit.record(:signing_resumed, %{at: now})
    IO.puts("Federation auto-signing resumed.")
    :ok
  end

  @doc """
  Re-runs the multisig setup ceremony — used when keys must be
  rotated after a compromise or as routine maintenance. Operator
  is responsible for first wiping wallet state on each node;
  Monero's multisig protocol can't re-prepare a wallet that's
  already partway through setup.
  """
  @spec rotate_keys() :: {:ok, String.t()} | {:error, term()}
  def rotate_keys do
    IO.puts("""

    Federation key rotation:

      1. Wipe wallet state on EACH guardian:
         - stop monero-wallet-rpc
         - mv $WALLET_DIR/wallet $WALLET_DIR/wallet.rotated.$(date +%s)
         - start monero-wallet-rpc with a fresh wallet

      2. Confirm all 3 nodes have fresh wallets and are reachable
         via Cartel.connected_peers().

      3. Re-run this command after wiping. It will run
         Federation.Bootstrap.run/0 to drive a fresh ceremony.
    """)

    case IO.gets("Wallets wiped and ready? (yes/N) ") do
      "yes\n" ->
        now = DateTime.utc_now()
        Audit.record(:rotate_keys_initiated, %{at: now})

        case Bootstrap.run() do
          {:ok, address} = ok ->
            Audit.record(:rotate_keys_completed, %{address: address, at: DateTime.utc_now()})
            ok

          {:error, reason} = err ->
            Audit.record(:rotate_keys_failed, %{reason: inspect(reason), at: DateTime.utc_now()})
            err
        end

      _ ->
        {:error, :cancelled}
    end
  end

  @doc """
  Aborts a request stuck at `:pending`, `:rules_passed`,
  `:awaiting_operator`, or `:signing` after a crash mid-round.
  Marks the Payout `:failed` so it leaves the in-flight queue and
  does not get re-driven.

  Refused on `:submitted`: the on-chain tx has broadcast and the
  payout is awaiting Markets-side finalisation. Blindly aborting
  would clear the broadcast marker AND leave the source
  Position/Dispute claimable — the next claim builds a fresh tx
  and pays the same recipient twice. If the tx genuinely never
  landed (deep reorg, orphaned block), that is a distinct flow;
  do NOT use abort here.

  Refused on `:settlement_unknown`: use `reconcile_failed/2`
  which requires an explicit operator confirmation that no
  broadcast happened.
  """
  @spec abort(binary(), String.t()) ::
          {:ok, Payout.t()} | {:error, :not_found | :invalid_transition}
  def abort(request_id, reason \\ "operator abort") when is_binary(request_id) do
    case Facade.abort_request(request_id, reason) do
      {:ok, updated} ->
        IO.puts("Aborted #{short(updated.id)} → :failed (reason: #{reason})")
        {:ok, updated}

      {:error, reason} = err ->
        IO.puts("abort refused: #{inspect(reason)}")
        err
    end
  end

  @doc """
  Resolves a `:settlement_unknown` payout after the operator has
  reconciled against wallet transfer history.

  Use when the auto-signer has pinned a request in
  `:settlement_unknown` because a multisig submit RPC returned an
  ambiguous result (timeout, transport error, 5xx). Operator's job:

    1. `PerpWalk.Federation.Console.review(request_id)` — confirms
       the amount, destination, and current status.
    2. On the guardian: query `wallet-rpc get_transfers out=true` and
       look for an outgoing transfer matching the amount and
       destination in the request's expected time window.
    3a. If a matching outgoing transfer exists:

          iex> Console.reconcile_paid_out(request_id, "<txid_from_wallet>")

    3b. If NO matching transfer exists (wallet confirmed no broadcast):

          iex> Console.reconcile_failed(request_id, "no_matching_transfer")

  Auto-signer NEVER resolves `:settlement_unknown` on its own — the
  ambiguity is precisely why we captured that state.
  """
  @spec reconcile_paid_out(binary(), String.t()) ::
          {:ok, Payout.t()} | {:error, :not_found | :invalid_transition}
  def reconcile_paid_out(request_id, txid)
      when is_binary(request_id) and is_binary(txid) do
    case Facade.reconcile_settlement(request_id, {:paid_out, txid}) do
      {:ok, updated} = ok ->
        IO.puts("Reconciled #{short(updated.id)} → :paid_out (txid=#{txid})")
        ok

      {:error, reason} = err ->
        IO.puts("reconcile_paid_out refused: #{inspect(reason)}")
        err
    end
  end

  @doc """
  Marks a `:settlement_unknown` payout as `:failed` after operator
  confirmed no broadcast ever happened. The source (Position,
  Dispute, etc.) can then re-enqueue a fresh Payout. See
  `reconcile_paid_out/2` for the operator workflow.
  """
  @spec reconcile_failed(binary(), String.t()) ::
          {:ok, Payout.t()} | {:error, :not_found | :invalid_transition}
  def reconcile_failed(request_id, reason)
      when is_binary(request_id) and is_binary(reason) do
    case Facade.reconcile_settlement(request_id, {:failed, reason}) do
      {:ok, updated} = ok ->
        IO.puts("Reconciled #{short(updated.id)} → :failed (reason: #{reason})")
        ok

      {:error, err_reason} = err ->
        IO.puts("reconcile_failed refused: #{inspect(err_reason)}")
        err
    end
  end

  @doc """
  Re-drives a `:rules_passed` request that the Signer has stalled
  on (e.g. backend recovered after `:wallet_unreachable`). Triggers
  one tick on this node's Signer immediately.
  """
  @spec retry(binary()) :: {:ok, Payout.t()} | {:error, :not_found}
  def retry(request_id) when is_binary(request_id) do
    case Facade.get_request(request_id) do
      {:ok, request} ->
        :ok = Signer.run_now()
        IO.puts("Retry tick driven for #{short(request.id)} (status: #{request.status})")
        {:ok, request}

      {:error, :not_found} = err ->
        IO.puts("Request #{request_id} not found.")
        err
    end
  end

  @doc """
  Prints the federation income breakdown — earned, drawn, and
  withdrawable balance — without enqueuing anything.
  """
  @spec income_status() :: :ok
  def income_status do
    breakdown = PerpWalk.Markets.Federation.Ledger.breakdown()
    drawn = Facade.federation_income_drawn()
    withdrawable = max(0, breakdown.total_piconeros - drawn)

    IO.puts("Federation income:")
    IO.puts("  slashed     = #{format_xmr(breakdown.slashed_piconeros)}")
    IO.puts("  burned      = #{format_xmr(breakdown.burned_piconeros)}")
    IO.puts("  spread (5/6) = #{format_xmr(breakdown.federation_spread_piconeros)}")
    IO.puts("  total earned = #{format_xmr(breakdown.total_piconeros)}")
    IO.puts("  drawn        = #{format_xmr(drawn)}")
    IO.puts("  withdrawable = #{format_xmr(withdrawable)}")
    :ok
  end

  @doc """
  Enqueues a federation income withdrawal for `amount_piconeros` to
  `destination`. Subject to the standard rules pipeline (cooldown,
  rate cap, destination sanity) AND a hard cap at the live
  `Markets.Federation.Ledger.withdrawable_piconeros/0` so a stale
  console snapshot can't authorise an over-draw.

  `account_id` records which guardian operator initiated the
  withdrawal — surfaced in the audit log alongside the override
  trail.
  """
  @spec withdraw_federation_income(pos_integer(), String.t(), String.t()) ::
          {:ok, Payout.t()} | {:error, term()}
  def withdraw_federation_income(amount_piconeros, destination, account_id)
      when is_integer(amount_piconeros) and amount_piconeros > 0 and
             is_binary(destination) and is_binary(account_id) do
    # Halt gate matches what user-facing services enforce: a halted
    # system should refuse to enqueue NEW payouts so the operator's
    # mental model "halt blocks all writes" actually holds. The
    # Signer's drive_writes? would later refuse to sign anyway, but
    # the WAL row + uniqueness slot would still be claimed.
    PerpWalk.Guards.ensure_operational!()

    case Facade.enqueue_federation_income_withdrawal(amount_piconeros, destination, account_id) do
      {:ok, payout} ->
        now = DateTime.utc_now()

        # PayoutRequested is the same event Cashier emits for user
        # payouts — surfaces operator withdrawals on the dashboard
        # event stream and (eventually) the Nostr alert channel.
        # Without this, federation income withdrawals are invisible
        # to every observer except the Payout row itself.
        EventBus.publish(%FederationEvents.PayoutRequested{
          request_id: payout.id,
          position_id: payout.position_id,
          market_id: payout.market_id,
          account_id: payout.account_id,
          kind: payout.kind,
          amount_piconeros: payout.amount_piconeros,
          destination: payout.destination,
          timestamp: payout.created_at
        })

        # Durable forensic record of the operator action — mirrors
        # the audit trail attached to `:operator_override` and
        # `:operator_abort`. The Payout row alone shows what was
        # requested; the audit log preserves who initiated, from
        # which node, and at what wall-clock time.
        Audit.record(:federation_income_withdrawal_initiated, %{
          request_id: payout.id,
          amount_piconeros: amount_piconeros,
          destination: destination,
          requesting_account_id: account_id,
          at: now
        })

        IO.puts("Federation income withdrawal queued:")
        IO.puts("  request_id    = #{payout.id}")
        IO.puts("  amount        = #{format_xmr(amount_piconeros)}")
        IO.puts("  destination   = #{destination}")
        IO.puts("  requested_by  = #{account_id}")
        IO.puts("  status        = :pending — will be evaluated by the Signer on the next tick.")
        {:ok, payout}

      {:error, reason} = err ->
        IO.puts("Federation income withdrawal failed: #{inspect(reason)}")
        err
    end
  end

  @doc """
  Prints the currently-designated processor set and whether the
  local node is in it. Reads `Application.get_env(:perpwalk,
  :designated_processors)` on each reachable guardian so cluster
  consistency is visible at a glance.
  """
  @spec current_processor() :: :ok
  def current_processor do
    all_nodes = [Node.self() | Facade.peer_nodes()]

    IO.puts("Local participant: #{Role.participant_id()}")
    IO.puts("Local designated?: #{Role.designated_processor?()}")
    IO.puts("Local designated set: #{inspect(Role.designated_processors())}")
    IO.puts("")
    IO.puts("Cluster view:")

    Enum.each(all_nodes, fn node ->
      case remote_designated_set(node) do
        {:ok, list} -> IO.puts("  #{inspect(node)}: #{inspect(list)}")
        {:error, reason} -> IO.puts("  #{inspect(node)}: unreachable (#{inspect(reason)})")
      end
    end)

    :ok
  end

  @doc """
  Promotes `target` to the sole designated processor cluster-wide.
  WAL-appends a `:processor_promotion` entry with a monotonically
  increasing epoch; the entry replicates to every guardian and each
  applies it locally via `apply_wal_entry/2`. Followers converge on
  the new set within one replication round.

  The promotion is DURABLE — a node restart replays the WAL entry
  before `Role.designated_processors/0` is first consulted. There is
  no inventory-revert-on-restart quirk any more.

  There is no "partial application" failure mode: either the WAL
  entry lands (the leader acknowledges the append + Sealer signature)
  and the whole cluster converges, or the append fails (WAL down /
  signing key missing / stale epoch) and no node has switched.

  Refuses:
    * targets that aren't valid participant ids
    * epochs less than or equal to the currently-active one (racing
      operators can't accidentally resurrect a stale target)
  """
  @spec promote_processor(atom()) ::
          :ok | {:error, :invalid_target | :stale_epoch | term()}
  def promote_processor(target) when is_atom(target) do
    if target in Role.valid_participants() do
      do_promote(target)
    else
      IO.puts(
        "promote_processor refused: #{inspect(target)} is not a valid participant_id. " <>
          "Valid: #{inspect(Role.valid_participants())}"
      )

      {:error, :invalid_target}
    end
  end

  defp do_promote(target) do
    next_epoch = next_promotion_epoch()
    now = DateTime.utc_now()

    case FederationStore.persist_processor_promotion(
           [target],
           next_epoch,
           Role.participant_id(),
           now
         ) do
      :ok ->
        IO.puts(
          "Designated processor promotion committed → #{inspect(target)} " <>
            "(epoch #{next_epoch})"
        )

        IO.puts(
          "  Replicating to peers; converged set will be visible on each guardian " <>
            "after their next WAL replication round."
        )

        Audit.record(:processor_promoted, %{
          new_processor: target,
          epoch: next_epoch,
          source: Role.participant_id(),
          at: now
        })

        :ok

      {:error, :stale_epoch} = err ->
        IO.puts(
          "promote_processor refused: a newer promotion has already committed " <>
            "(current epoch #{current_promotion_epoch()}). Re-check with " <>
            "current_processor/0 before retrying."
        )

        err

      {:error, reason} = err ->
        IO.puts("promote_processor failed: #{inspect(reason)}")
        err
    end
  end

  defp next_promotion_epoch, do: current_promotion_epoch() + 1

  defp current_promotion_epoch do
    case FederationStore.lookup_processor_promotion() do
      {_set, epoch} -> epoch
      :none -> 0
    end
  end

  defp remote_designated_set(node) do
    if node == Node.self() do
      {:ok, Role.designated_processors()}
    else
      case :rpc.call(node, PerpWalk.Role, :designated_processors, [], 5_000) do
        list when is_list(list) -> {:ok, list}
        {:badrpc, reason} -> {:error, reason}
        other -> {:error, {:unexpected, other}}
      end
    end
  end

  # --- Helpers ---

  defp short(id) when is_binary(id) and byte_size(id) >= 8, do: String.slice(id, 0, 8)
  defp short(id), do: to_string(id)

  defp format_xmr(piconeros) when is_integer(piconeros) do
    xmr = piconeros / 1_000_000_000_000
    "#{:erlang.float_to_binary(xmr, decimals: 6)} XMR"
  end

  defp age(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3_600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end
end
