defmodule PerpWalk.Markets.Services.Cashier do
  @moduledoc """
  Markets-side entry point for outflows: winner payouts on settled
  markets, refunds on voided markets.

  The Cashier validates that a Position is in a payable state and
  computes the on-chain amount via `Position.payout/2`. It then
  hands off to `Federation.Facade.enqueue_payout/3`, which queues
  a `Payout` for federation signing — every Monero outflow
  goes through 2-of-3 multisig, never a synchronous single-key
  transfer (was retired in 8f3).

  ## Flow

      claim_payout(position_id, destination)
        ↓
      validate position is :settled_winner or :refunded
        ↓
      fetch market, compute payout amount
        ↓
      Federation.Facade.enqueue_payout → Payout persisted
        ↓
      Federation.Signer picks up the request, runs
      Rules, coordinates 2-of-3 signing, submits on-chain
        ↓
      Position transitions to :paid_out when the signed tx is
      observed

  Cashier returns the `Payout` synchronously — the caller
  (LiveView, iex) shows the user "queued" and polls the request
  status (or subscribes to `Federation.PayoutRequested`).

  PERP WALK uses per-trade subaddresses for deposits but does NOT
  retain a withdraw destination — the user provides one at claim
  time, every time. That keeps the platform's
  what-do-we-know-about-you surface to a minimum.

  ## Errors

  - `:position_not_found`
  - `:market_not_found`
  - `:not_payable` — position is `:open`, `:settled_loser`, or `:paid_out`
  """

  require Logger

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents
  alias PerpWalk.Federation.Facade
  alias PerpWalk.Federation.Payout
  alias PerpWalk.Guards
  alias PerpWalk.Markets.{AMM, Dispute, Market, Position, Store}
  alias PerpWalk.Monero.Address

  @doc """
  Validates a position and enqueues a `Payout` with the
  Federation. Returns the request synchronously — the actual
  transfer happens asynchronously when the federation reaches
  threshold and submits.

  Requires `claimant_account_id` — the authenticated account
  attempting the claim. Refuses with `:not_owner` if the position
  belongs to a different account. Refuses with
  `:payout_already_pending` if a non-terminal Federation.Payout
  already references this position (idempotency guard).
  """
  @spec claim_payout(binary(), binary(), String.t()) ::
          {:ok, Payout.t()}
          | {:error,
             :position_not_found
             | :market_not_found
             | :not_payable
             | :not_owner
             | :invalid_destination
             | :payout_already_pending
             | term()}
  def claim_payout(position_id, claimant_account_id, destination)
      when is_binary(position_id) and is_binary(claimant_account_id) and
             is_binary(destination) and byte_size(destination) > 0 do
    Guards.ensure_operational!()

    with {:ok, position} <- fetch_position(position_id),
         :ok <- ensure_owner(position, claimant_account_id),
         :ok <- ensure_payable(position),
         :ok <- ensure_valid_destination(destination),
         {:ok, market} <- fetch_market(position.market_id),
         amount when amount > 0 <- Position.payout(position, market.unit_size),
         {:ok, request} <- Facade.enqueue_payout(position, amount, destination) do
      EventBus.publish(%FederationEvents.PayoutRequested{
        request_id: request.id,
        position_id: request.position_id,
        market_id: request.market_id,
        account_id: request.account_id,
        kind: request.kind,
        amount_piconeros: request.amount_piconeros,
        destination: request.destination,
        timestamp: request.created_at
      })

      {:ok, request}
    else
      0 -> {:error, :not_payable}
      other -> other
    end
  end

  @doc """
  Marks a position `:paid_out` once the Federation has submitted
  the payout transaction on-chain. Single Markets-domain entry
  point for the Federation.Signer's post-signing finalisation —
  keeps `Position.pay_out/2` and `Store.put_payout/1` private to
  the Markets bounded context.
  """
  @spec mark_paid_out(binary(), String.t()) ::
          {:ok, Position.t()}
          | {:error, :position_not_found | :invalid_transition | :already_paid_out | term()}
  def mark_paid_out(position_id, txid)
      when is_binary(position_id) and is_binary(txid) and byte_size(txid) > 0 do
    Guards.ensure_operational!()

    with {:ok, position} <- fetch_position(position_id),
         {:ok, paid} <- Position.pay_out(position, txid),
         :ok <- Store.put_payout(paid) do
      {:ok, paid}
    end
  end

  @doc """
  Validates a resolved dispute and enqueues a `Payout` for the
  refund with the Federation. Mirrors `claim_payout/3` but for
  disputes (which carry no `position_id`). Returns the request
  synchronously.

  `claimant_account_id` MUST be the auth'd session's account; the
  function uses it both to scope the dispute lookup AND to verify
  ownership defensively. Mismatch yields `:not_owner` even if a
  dispute happened to be returned by some other path. This is the
  same belt-and-braces shape `claim_payout/3` uses — auth is
  structural via the lookup key, but the explicit ownership check
  documents the contract and forecloses any future refactor where
  the lookup and auth get separated.
  """
  @spec claim_dispute_refund(binary(), binary(), String.t()) ::
          {:ok, Payout.t()}
          | {:error,
             :dispute_not_found
             | :not_owner
             | :not_refundable
             | :refund_already_pending
             | term()}
  def claim_dispute_refund(claimant_account_id, market_id, destination)
      when is_binary(claimant_account_id) and is_binary(market_id) and
             is_binary(destination) and byte_size(destination) > 0 do
    Guards.ensure_operational!()

    with {:ok, dispute} <- fetch_dispute(claimant_account_id, market_id),
         :ok <- ensure_dispute_owner(dispute, claimant_account_id),
         :ok <- ensure_refundable(dispute),
         :ok <- ensure_valid_destination(destination),
         amount when amount > 0 <- Dispute.refund_amount_piconeros(dispute),
         {:ok, request} <- Facade.enqueue_dispute_refund(dispute, amount, destination) do
      EventBus.publish(%FederationEvents.PayoutRequested{
        request_id: request.id,
        position_id: nil,
        market_id: request.market_id,
        account_id: request.account_id,
        kind: request.kind,
        amount_piconeros: request.amount_piconeros,
        destination: request.destination,
        timestamp: request.created_at
      })

      {:ok, request}
    else
      0 -> {:error, :not_refundable}
      other -> other
    end
  end

  @doc """
  Enqueues the creator's liquidity-return payout. Mirrors
  `claim_payout/3` and `claim_dispute_refund/3` for the creator-LP
  flow:

      market settles (or voids) → creator visits portfolio / market detail →
        clicks "Claim Liquidity Return" → enters destination → this fires →
          Federation.Payout enqueued → Signer picks it up → on-chain → done

  Computes the residual deterministically from market state:

  - `:settled` markets → `pool.<winning_side> × unit_size`
  - `:voided` markets → full `deposit_amount`

  `claimant_account_id` MUST match `market.creator_account_id`. The
  uniqueness check at the Federation Store guarantees one LP return
  per market regardless of concurrent claim attempts.
  """
  @spec claim_creator_lp_return(binary(), binary(), String.t()) ::
          {:ok, Payout.t()}
          | {:error,
             :market_not_found
             | :not_creator
             | :market_not_returnable
             | :invalid_destination
             | :lp_return_already_pending
             | term()}
  def claim_creator_lp_return(claimant_account_id, market_id, destination)
      when is_binary(claimant_account_id) and is_binary(market_id) and
             is_binary(destination) and byte_size(destination) > 0 do
    Guards.ensure_operational!()

    with {:ok, market} <- fetch_market(market_id),
         :ok <- ensure_creator(market, claimant_account_id),
         :ok <- ensure_lp_returnable(market),
         :ok <- ensure_valid_destination(destination),
         amount when amount > 0 <- lp_return_amount(market),
         {:ok, request} <-
           Facade.enqueue_creator_lp_return(market_id, claimant_account_id, amount, destination) do
      EventBus.publish(%FederationEvents.PayoutRequested{
        request_id: request.id,
        position_id: nil,
        market_id: request.market_id,
        account_id: request.account_id,
        kind: request.kind,
        amount_piconeros: request.amount_piconeros,
        destination: request.destination,
        timestamp: request.created_at
      })

      {:ok, request}
    else
      0 -> {:error, :market_not_returnable}
      other -> other
    end
  end

  @doc """
  Marks a creator LP return as `:returned` once the Federation has
  submitted the payout transaction on-chain. Single Markets-domain
  entry point for the Signer's post-signing finalisation of LP
  returns. Stamps `market.creator_lp_paid_out_at` and emits a
  `CreatorLpReturned` event.
  """
  @spec mark_creator_lp_returned(binary(), String.t()) ::
          {:ok, Market.t()} | {:error, :market_not_found | :already_paid_out | term()}
  def mark_creator_lp_returned(market_id, txid)
      when is_binary(market_id) and is_binary(txid) and byte_size(txid) > 0 do
    Guards.ensure_operational!()

    with {:ok, market} <- fetch_market(market_id),
         {:ok, updated} <- Market.mark_creator_lp_paid_out(market),
         :ok <-
           Store.put_market_cas(updated, %{
             status: market.status,
             creator_lp_paid_out_at: nil
           }) do
      {:ok, updated}
    end
  end

  @doc """
  Marks a dispute as `:refunded_full` or `:refunded_partial` once
  the Federation has submitted the refund transaction on-chain.
  Single Markets-domain entry point for `Federation.Signer`'s
  post-signing finalisation of dispute refunds.
  """
  @spec mark_dispute_refunded(binary(), binary()) ::
          {:ok, Dispute.t()}
          | {:error, :dispute_not_found | :invalid_transition | term()}
  def mark_dispute_refunded(account_id, market_id)
      when is_binary(account_id) and is_binary(market_id) do
    Guards.ensure_operational!()

    with {:ok, dispute} <- fetch_dispute(account_id, market_id),
         {:ok, refunded} <- Dispute.mark_refunded(dispute),
         :ok <- Store.put_dispute(refunded) do
      {:ok, refunded}
    end
  end

  # --- Internal ---

  defp fetch_position(id) do
    case Store.get_position(id) do
      {:ok, p} -> {:ok, p}
      {:error, :not_found} -> {:error, :position_not_found}
    end
  end

  defp fetch_market(id) do
    case Store.get_market(id) do
      {:ok, %Market{} = m} -> {:ok, m}
      {:error, :not_found} -> {:error, :market_not_found}
    end
  end

  defp ensure_payable(%Position{status: :settled_winner}), do: :ok
  defp ensure_payable(%Position{status: :refunded}), do: :ok
  defp ensure_payable(%Position{}), do: {:error, :not_payable}

  # Constant-time comparison. account_id is not strictly a crypto
  # secret (it's derived from the keyphrase), but it's the only
  # binding between an authenticated session and the position whose
  # payout is about to be released. Use `Plug.Crypto.secure_compare/2`
  # for parity with the rest of the codebase's auth-adjacent equality
  # checks rather than leak length-prefix timing on the owner check.
  defp ensure_owner(%Position{account_id: owner}, claimant)
       when is_binary(owner) and is_binary(claimant) do
    if Plug.Crypto.secure_compare(owner, claimant), do: :ok, else: {:error, :not_owner}
  end

  defp ensure_owner(_position, _claimant), do: {:error, :not_owner}

  # Address validation routes through `PerpWalk.Monero.Address`, same
  # source of truth as Federation.Rules.destination_sanity. Keeping
  # the check here too so a future caller that bypasses the rule
  # engine (or any path that runs Cashier outside the Signer flow)
  # can't enqueue a Payout with a malformed destination — better to
  # reject at the request boundary than have a doomed Payout sit at
  # :awaiting_operator forever.
  defp ensure_valid_destination(dest) when is_binary(dest) do
    if Address.valid?(dest) do
      :ok
    else
      {:error, :invalid_destination}
    end
  end

  defp ensure_dispute_owner(%Dispute{account_id: owner}, claimant)
       when is_binary(owner) and is_binary(claimant) do
    if Plug.Crypto.secure_compare(owner, claimant), do: :ok, else: {:error, :not_owner}
  end

  defp ensure_dispute_owner(_dispute, _claimant), do: {:error, :not_owner}

  defp fetch_dispute(account_id, market_id) do
    case Store.get_dispute(account_id, market_id) do
      {:ok, d} -> {:ok, d}
      {:error, :not_found} -> {:error, :dispute_not_found}
    end
  end

  defp ensure_refundable(%Dispute{status: :resolved_against}), do: :ok
  defp ensure_refundable(%Dispute{status: :resolved_for}), do: :ok
  defp ensure_refundable(%Dispute{}), do: {:error, :not_refundable}

  defp ensure_creator(market, claimant) do
    if Market.creator?(market, claimant),
      do: :ok,
      else: {:error, :not_creator}
  end

  # Markets in `:settled` or `:voided` are the only states where the
  # creator's LP capital can be returned. `:rejected` markets had
  # the deposit burned to house. Anything else is mid-lifecycle —
  # the LP capital is still in the active pool.
  defp ensure_lp_returnable(%Market{status: :settled, creator_lp_paid_out_at: nil}), do: :ok
  defp ensure_lp_returnable(%Market{status: :voided, creator_lp_paid_out_at: nil}), do: :ok
  defp ensure_lp_returnable(%Market{creator_lp_paid_out_at: %DateTime{}}), do: {:error, :already_paid_out}
  defp ensure_lp_returnable(%Market{}), do: {:error, :market_not_returnable}

  @doc """
  Returns the piconero amount the creator can claim back as their
  LP residual. Mirrors `Federation.Rules.creator_lp_expected_amount/1`
  — same deterministic derivation from market state. Called both
  pre-enqueue (so we don't queue a payout the Signer will reject)
  and from the portfolio UI to render the claim preview.

  Pool reserves are in AMM subunits (see `AMM` moduledoc); convert
  to piconeros via `AMM.cost_to_piconeros/2`. Returns `0` for
  non-terminal market statuses so the UI safely shows the zero
  case rather than crashing.
  """
  @spec lp_return_amount(Market.t()) :: non_neg_integer()
  def lp_return_amount(%Market{status: :settled, outcome: :yes, pool: pool, unit_size: u, id: id}),
    do: AMM.cost_to_piconeros(pool.yes, u) + creator_spread_share(id)

  def lp_return_amount(%Market{status: :settled, outcome: :no, pool: pool, unit_size: u, id: id}),
    do: AMM.cost_to_piconeros(pool.no, u) + creator_spread_share(id)

  def lp_return_amount(%Market{status: :voided, deposit_amount: deposit}),
    do: deposit

  def lp_return_amount(_), do: 0

  @doc """
  Returns the creator's slice of the accumulated trade-spread for
  the market — 1/6 of the summed per-position spread (integer floor,
  same math the federation ledger uses). Pre-fix this share was
  computed in `Markets.Federation.Ledger.breakdown/0` and documented
  as "paid via the creator's LP return", but neither
  `lp_return_amount/1` nor `Federation.Rules.creator_lp_expected_amount/1`
  included it — the amount accumulated unattributed in the multisig
  forever. Now added to the settled-market LP return.

  Voided markets don't accumulate spread (no trades filled), so
  they omit this addition.
  """
  @spec creator_spread_share(binary()) :: non_neg_integer()
  def creator_spread_share(market_id) when is_binary(market_id) do
    positions_spread =
      market_id
      |> Store.list_positions_for_market()
      |> Enum.reduce(0, fn p, acc -> acc + (p.spread_piconeros || 0) end)

    # 1/6 of the captured spread — see
    # `Markets.Federation.Ledger`'s `@creator_share_num / @share_denom`.
    # Same integer-floor math so the two views stay coherent.
    div(positions_spread, 6)
  end
end
