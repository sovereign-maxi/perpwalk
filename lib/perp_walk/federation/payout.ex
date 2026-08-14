defmodule PerpWalk.Federation.Payout do
  @moduledoc """
  A queued outflow awaiting federation signing.

  PERP WALK never transfers funds synchronously from a user-facing
  request — every Monero outflow goes through a 2-of-3 multisig
  ceremony. The Payout is the durable record of that
  request: who is being paid, how much, why, and where in the
  signing pipeline it currently sits.

  ## State machine

      :pending             — created, awaiting rule evaluation
        ↓
      :rules_passed        — Rules engine cleared the request; eligible
                             for auto-signing
        ↓
      :signing             — federation peers are coordinating multisig
                             rounds
        ↓
      :submitted           — fully-signed tx broadcast to the network
        ↓
      :paid_out            — on-chain confirmation observed; Position
                             transitions in tandem

  Side branches:

      :pending → :awaiting_operator — Rules rejected; queued for
                                       manual review
      :awaiting_operator → :rules_passed — operator force-signed via
                                       Federation.Console; rules are
                                       re-evaluated before signing
      :rules_passed → :failed       — force-sign rule revalidation
                                       rejected (terminal — operator
                                       must enqueue fresh request)
      :rules_passed → :settlement_unknown — submit RPC returned an
                                       ambiguous result (timeout, 5xx,
                                       null-result, transport error).
                                       The tx MAY have been broadcast.
                                       Auto-signer will NOT retry —
                                       operator must reconcile against
                                       wallet-side transfer history and
                                       transition manually via console.
      :settlement_unknown → :paid_out — operator confirmed on-chain
                                       broadcast; supplies the txid
                                       recovered from wallet transfers
      :settlement_unknown → :failed  — operator confirmed no broadcast
                                       ever happened; payout is safe
                                       to re-enqueue as a fresh request
      any → :failed                — non-recoverable error (refund
                                     or operator action required)

  ## Why this is a Federation entity, not a Markets entity

  The request lives in the Federation domain because the Federation
  owns the queue, the rules, and the signing orchestration. Markets
  doesn't need to know how a payout becomes a transaction — only
  that one was requested and (eventually) one was completed. The
  link back to Markets is either `position_id` (winner / position
  refund) or the `(account_id, market_id)` tuple (dispute refund);
  the link forward to chain reality is the eventual `payout_txid`.

  Pure module — state transitions only, no IO.
  """

  alias PerpWalk.Markets.{Dispute, Position}

  @type status ::
          :pending
          | :rules_passed
          | :signing
          | :submitted
          | :paid_out
          | :awaiting_operator
          | :settlement_unknown
          | :failed

  @type kind ::
          :winner_payout
          | :refund
          | :dispute_refund_full
          | :dispute_refund_partial
          | :federation_income
          | :creator_lp_return
          | :quote_underpayment_refund

  @type t :: %__MODULE__{
          id: binary(),
          position_id: binary() | nil,
          source_quote_id: binary() | nil,
          market_id: binary(),
          account_id: binary(),
          kind: kind(),
          amount_piconeros: pos_integer(),
          destination: String.t(),
          status: status(),
          rule_failure_reason: String.t() | nil,
          payout_txid: String.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @enforce_keys [
    :id,
    :market_id,
    :account_id,
    :kind,
    :amount_piconeros,
    :destination,
    :status,
    :created_at,
    :updated_at
  ]

  defstruct [
    :id,
    :position_id,
    :source_quote_id,
    :market_id,
    :account_id,
    :kind,
    :amount_piconeros,
    :destination,
    :status,
    :rule_failure_reason,
    :payout_txid,
    :created_at,
    :updated_at
  ]

  @doc """
  Builds a fresh `:pending` Payout for a position.

  `kind` is derived from the position's status — `:settled_winner`
  → `:winner_payout`, `:refunded` → `:refund`. Other statuses raise.
  """
  @spec new(Position.t(), pos_integer(), String.t()) :: t()
  def new(%Position{} = position, amount_piconeros, destination)
      when is_integer(amount_piconeros) and amount_piconeros > 0 and
             is_binary(destination) and byte_size(destination) > 0 do
    now = DateTime.utc_now()

    %__MODULE__{
      id: generate_id(),
      position_id: position.id,
      market_id: position.market_id,
      account_id: position.account_id,
      kind: kind_for(position),
      amount_piconeros: amount_piconeros,
      destination: destination,
      status: :pending,
      created_at: now,
      updated_at: now
    }
  end

  @doc """
  Builds a fresh `:pending` Payout for a resolved dispute. `kind`
  is derived from the dispute status — `:resolved_against` →
  `:dispute_refund_full`, `:resolved_for` → `:dispute_refund_partial`.
  Other statuses raise.

  Disputes carry no `position_id`; the `(account_id, market_id)`
  tuple uniquely identifies the source dispute and is already
  embedded in the Payout struct.
  """
  @spec new_dispute_refund(Dispute.t(), pos_integer(), String.t()) :: t()
  def new_dispute_refund(%Dispute{} = dispute, amount_piconeros, destination)
      when is_integer(amount_piconeros) and amount_piconeros > 0 and
             is_binary(destination) and byte_size(destination) > 0 do
    now = DateTime.utc_now()

    %__MODULE__{
      id: generate_id(),
      position_id: nil,
      market_id: dispute.market_id,
      account_id: dispute.account_id,
      kind: dispute_kind_for(dispute),
      amount_piconeros: amount_piconeros,
      destination: destination,
      status: :pending,
      created_at: now,
      updated_at: now
    }
  end

  @doc """
  True if the payout is for a dispute refund (no associated
  Position; finalisation transitions a Dispute, not a Position).
  """
  @spec dispute_refund?(t()) :: boolean()
  def dispute_refund?(%__MODULE__{kind: kind})
      when kind in [:dispute_refund_full, :dispute_refund_partial],
      do: true

  def dispute_refund?(_), do: false

  @doc """
  Builds a `:pending` Payout that withdraws accumulated federation
  income (slash + burn + 5/6 of trade spread) to a guardian-specified
  destination. Carries no position_id and no market_id (it crosses
  all markets); we use `"federation"` as a sentinel market_id and
  the operator account as `account_id` so the existing storage
  schema accepts it without nullable changes.

  The amount must be ≤ `Markets.Federation.Ledger.withdrawable_piconeros/0`.
  Rules enforce that at sign time, not here.
  """
  @spec new_federation_income(pos_integer(), String.t(), String.t()) :: t()
  def new_federation_income(amount_piconeros, destination, requesting_account_id)
      when is_integer(amount_piconeros) and amount_piconeros > 0 and
             is_binary(destination) and byte_size(destination) > 0 and
             is_binary(requesting_account_id) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: generate_id(),
      position_id: nil,
      market_id: "federation",
      account_id: requesting_account_id,
      kind: :federation_income,
      amount_piconeros: amount_piconeros,
      destination: destination,
      status: :pending,
      created_at: now,
      updated_at: now
    }
  end

  @doc "True if the payout is a federation income withdrawal."
  @spec federation_income?(t()) :: boolean()
  def federation_income?(%__MODULE__{kind: :federation_income}), do: true
  def federation_income?(_), do: false

  @doc """
  Builds a `:pending` Payout that returns a market creator's
  liquidity at settlement (residual = `winning_side × unit_size`)
  or void (full deposit). Carries no `position_id` — the link back
  to the market is `(market_id, account_id)` where `account_id` is
  the creator. Auto-issued by `Resolver.settle/1` and `Resolver.void/1`;
  also reachable via `Federation.Console` for operator-driven cases
  (manual settlement, dispute reversal).
  """
  @spec new_creator_lp_return(binary(), binary(), pos_integer(), String.t()) :: t()
  def new_creator_lp_return(market_id, creator_account_id, amount_piconeros, destination)
      when is_binary(market_id) and is_binary(creator_account_id) and
             is_integer(amount_piconeros) and amount_piconeros > 0 and
             is_binary(destination) and byte_size(destination) > 0 do
    now = DateTime.utc_now()

    %__MODULE__{
      id: generate_id(),
      position_id: nil,
      market_id: market_id,
      account_id: creator_account_id,
      kind: :creator_lp_return,
      amount_piconeros: amount_piconeros,
      destination: destination,
      status: :pending,
      created_at: now,
      updated_at: now
    }
  end

  @doc "True if the payout is a creator liquidity return."
  @spec creator_lp_return?(t()) :: boolean()
  def creator_lp_return?(%__MODULE__{kind: :creator_lp_return}), do: true
  def creator_lp_return?(_), do: false

  @doc """
  Builds a `:pending` Payout that returns funds a user sent to a
  quote subaddress but which fell short of the locked quote price.
  The quote never fills (Poller refuses to `fill_quote` when
  `amount < expected`); the subaddress balance sits in federation
  custody until this refund is signed and broadcast.

  `source_quote_id` is the load-bearing uniqueness key — one refund
  per underpaid quote, ever. Store enforces it inside its serialised
  mailbox so a Poller re-fire on the same txid can't double-issue.
  """
  @spec new_quote_underpayment_refund(binary(), binary(), binary(), pos_integer(), String.t()) ::
          t()
  def new_quote_underpayment_refund(quote_id, account_id, market_id, amount_piconeros, destination)
      when is_binary(quote_id) and byte_size(quote_id) > 0 and
             is_binary(account_id) and is_binary(market_id) and
             is_integer(amount_piconeros) and amount_piconeros > 0 and
             is_binary(destination) and byte_size(destination) > 0 do
    now = DateTime.utc_now()

    %__MODULE__{
      id: generate_id(),
      position_id: nil,
      source_quote_id: quote_id,
      market_id: market_id,
      account_id: account_id,
      kind: :quote_underpayment_refund,
      amount_piconeros: amount_piconeros,
      destination: destination,
      status: :pending,
      created_at: now,
      updated_at: now
    }
  end

  @doc "True if the payout is a quote-underpayment refund."
  @spec quote_underpayment_refund?(t()) :: boolean()
  def quote_underpayment_refund?(%__MODULE__{kind: :quote_underpayment_refund}), do: true
  def quote_underpayment_refund?(_), do: false

  @doc """
  True if the payout is in a terminal status — `:paid_out` or
  `:failed`. Terminal payouts no longer count against uniqueness
  checks (`:paid_out` is one-shot by definition; `:failed` allows
  retry).
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}) when status in [:paid_out, :failed], do: true
  def terminal?(%__MODULE__{}), do: false

  @doc "Marks a pending request as having passed rule evaluation."
  @spec mark_rules_passed(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def mark_rules_passed(%__MODULE__{status: :pending} = req),
    do: {:ok, %{req | status: :rules_passed, updated_at: DateTime.utc_now()}}

  def mark_rules_passed(_), do: {:error, :invalid_transition}

  @doc "Marks a pending request as queued for operator review."
  @spec mark_awaiting_operator(t(), String.t()) :: {:ok, t()} | {:error, :invalid_transition}
  def mark_awaiting_operator(%__MODULE__{status: :pending} = req, reason)
      when is_binary(reason) do
    {:ok,
     %{
       req
       | status: :awaiting_operator,
         rule_failure_reason: reason,
         updated_at: DateTime.utc_now()
     }}
  end

  def mark_awaiting_operator(_, _), do: {:error, :invalid_transition}

  @doc """
  Operator override — clears a `:awaiting_operator` request to
  `:rules_passed` so the Signer picks it up for signing on the
  next tick. The original `rule_failure_reason` is preserved as
  audit trail.
  """
  @spec mark_force_approved(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def mark_force_approved(%__MODULE__{status: :awaiting_operator} = req) do
    {:ok, %{req | status: :rules_passed, updated_at: DateTime.utc_now()}}
  end

  def mark_force_approved(_), do: {:error, :invalid_transition}

  @doc """
  Begins federation signing for a rules-cleared request.

  Operator force-sign goes through `mark_force_approved/1` first
  (`:awaiting_operator` → `:rules_passed`) so the rule-revalidation
  pass in `Federation.Signer` still runs. Direct
  `:awaiting_operator` → `:signing` is rejected here to prevent any
  future caller from skipping that revalidation.
  """
  @spec mark_signing(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def mark_signing(%__MODULE__{status: :rules_passed} = req),
    do: {:ok, %{req | status: :signing, updated_at: DateTime.utc_now()}}

  def mark_signing(_), do: {:error, :invalid_transition}

  @doc "Marks a signing request as submitted on-chain with the resulting txid."
  @spec mark_submitted(t(), String.t()) :: {:ok, t()} | {:error, :invalid_transition}
  def mark_submitted(%__MODULE__{status: :signing} = req, txid) when is_binary(txid) do
    {:ok,
     %{
       req
       | status: :submitted,
         payout_txid: txid,
         updated_at: DateTime.utc_now()
     }}
  end

  def mark_submitted(_, _), do: {:error, :invalid_transition}

  @doc """
  Marks a rules-cleared or actively-signing request as `:settlement_unknown` —
  the multisig submit RPC returned an ambiguous result (timeout, 5xx,
  transport error, null-result) so the tx MAY or MAY NOT have been
  broadcast. The Signer never retries this state; the operator must
  reconcile against wallet-side transfer history and transition manually
  via `mark_reconciled_paid_out/2` or `mark_reconciled_failed/2`.

  This is the "unknown outcome" state. Blindly retrying with a fresh
  coin selection when the previous submit may have succeeded is the
  classic double-payout foot-gun.
  """
  @spec mark_settlement_unknown(t(), String.t()) ::
          {:ok, t()} | {:error, :invalid_transition}
  def mark_settlement_unknown(%__MODULE__{status: status} = req, reason)
      when status in [:rules_passed, :signing] and is_binary(reason) do
    {:ok,
     %{
       req
       | status: :settlement_unknown,
         rule_failure_reason: reason,
         updated_at: DateTime.utc_now()
     }}
  end

  def mark_settlement_unknown(_, _), do: {:error, :invalid_transition}

  @doc """
  Operator-driven resolution — the payout was reconciled against
  wallet transfers and the tx IS on-chain with the given txid.
  Transitions `:settlement_unknown` → `:paid_out` directly, pinning
  the recovered txid. Refused on any other status.
  """
  @spec mark_reconciled_paid_out(t(), String.t()) ::
          {:ok, t()} | {:error, :invalid_transition}
  def mark_reconciled_paid_out(%__MODULE__{status: :settlement_unknown} = req, txid)
      when is_binary(txid) and byte_size(txid) > 0 do
    {:ok,
     %{
       req
       | status: :paid_out,
         payout_txid: txid,
         updated_at: DateTime.utc_now()
     }}
  end

  def mark_reconciled_paid_out(_, _), do: {:error, :invalid_transition}

  @doc "Marks a submitted request as confirmed on-chain — terminal."
  @spec mark_paid_out(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def mark_paid_out(%__MODULE__{status: :submitted} = req),
    do: {:ok, %{req | status: :paid_out, updated_at: DateTime.utc_now()}}

  def mark_paid_out(_), do: {:error, :invalid_transition}

  @doc """
  Operator-driven resolution — the payout was reconciled against
  wallet transfers and NO broadcast ever happened; the request can
  be safely re-enqueued as a fresh Payout. Transitions
  `:settlement_unknown` → `:failed` with an operator-supplied reason.
  Refused on any other status (use `mark_failed/2` for other paths).
  """
  @spec mark_reconciled_failed(t(), String.t()) ::
          {:ok, t()} | {:error, :invalid_transition}
  def mark_reconciled_failed(%__MODULE__{status: :settlement_unknown} = req, reason)
      when is_binary(reason) do
    {:ok,
     %{
       req
       | status: :failed,
         rule_failure_reason: reason,
         updated_at: DateTime.utc_now()
     }}
  end

  def mark_reconciled_failed(_, _), do: {:error, :invalid_transition}

  @doc """
  Marks a request as failed — terminal. Used for non-recoverable
  errors and operator aborts on stuck pre-broadcast requests.

  Refused on `:paid_out`: that state means the tx is on-chain AND
  the Markets-side bookkeeping completed. "Failing" it would create
  inconsistent ledger reads without affecting actual funds (which
  are already out). Operator interventions targeting `:paid_out`
  should be expressed as a separate corrective Payout, not a state
  rewrite.

  Refused on `:submitted`: the on-chain tx has broadcast (we hold
  the `payout_txid`) and the Position/Dispute is awaiting
  finalisation. Transitioning to `:failed` would clear the
  broadcast marker via the abort path AND leave the source
  (Position, Dispute) in a claimable state — the next claim
  builds a fresh tx and pays the same recipient twice. If the
  operator genuinely needs to abandon a `:submitted` payout
  (e.g. tx orphaned by a deep reorg), that is a distinct flow
  requiring explicit source-side reversal, not a naive state
  rewrite.

  Refused on `:settlement_unknown`: broadcast status is
  under active reconciliation. Blindly failing here defeats
  the whole point of the state — operator MUST use
  `mark_reconciled_failed/2` after verifying wallet-side that
  no broadcast happened.
  """
  @spec mark_failed(t(), String.t()) :: {:ok, t()} | {:error, :invalid_transition}
  def mark_failed(%__MODULE__{status: status}, _reason)
      when status in [:paid_out, :submitted, :settlement_unknown],
      do: {:error, :invalid_transition}

  def mark_failed(%__MODULE__{} = req, reason) when is_binary(reason) do
    {:ok,
     %{
       req
       | status: :failed,
         rule_failure_reason: reason,
         updated_at: DateTime.utc_now()
     }}
  end

  @doc """
  True when the request is still in flight — anything that isn't
  `:paid_out` or `:failed`. `:submitted` is in-flight: the on-chain
  tx has been broadcast but the position hasn't been finalised yet.
  """
  @spec in_flight?(t()) :: boolean()
  def in_flight?(%__MODULE__{} = p), do: not terminal?(p)

  def in_flight?(_), do: false

  # --- Internal ---

  defp kind_for(%Position{status: :settled_winner}), do: :winner_payout
  defp kind_for(%Position{status: :refunded}), do: :refund

  defp kind_for(%Position{status: status}),
    do: raise(ArgumentError, "Position in #{inspect(status)} is not eligible for payout")

  defp dispute_kind_for(%Dispute{status: :resolved_against}), do: :dispute_refund_full
  defp dispute_kind_for(%Dispute{status: :resolved_for}), do: :dispute_refund_partial

  defp dispute_kind_for(%Dispute{status: status}),
    do: raise(ArgumentError, "Dispute in #{inspect(status)} is not eligible for refund")

  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
