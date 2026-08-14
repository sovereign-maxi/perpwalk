defmodule PerpWalk.Markets.Market do
  @moduledoc """
  Stateful aggregate governing the lifecycle of a market.

  State machine:

      PENDING → ACTIVE   → EXPIRED → RESOLVING → SETTLED
      PENDING → REJECTED                          (downvoted out, deposit burned)
      EXPIRED → VOIDED                            (operator missed deadline)
      RESOLVING → VOIDED                          (resolution undecidable)

  All transitions are pure functions returning `{:ok, market}` or
  `{:error, :invalid_transition}`. The aggregate carries the AMM pool
  inline; trades update the pool via `update_pool/2`.

  ## Deposit semantics (LP-capital model)

  `deposit_amount` is the creator's **initial liquidity** — real
  collateral that seeds the AMM pool at `deposit_amount / unit_size`
  contracts per side. The creator is the market's sole LP. Per
  outcome:

  - `:rejected` → deposit burns to house revenue (community-downvote
    spam gate; same as the old "bond" semantics)
  - `:settled` → residual pool (`pool.<winning_side> × unit_size`)
    returns to creator via `Markets.Services.Cashier.claim_creator_lp_return/3`
  - `:voided` → full deposit returns to creator

  `creator_lp_paid_out_at` is stamped by
  `mark_creator_lp_paid_out/1` once the Federation signs and
  submits the return on-chain. Gates double-claims.

  Pure module — no IO, no GenServer, no process state.
  """

  alias PerpWalk.Markets.{AMM, Categories}

  @type status ::
          :awaiting_deposit
          | :pending
          | :active
          | :expired
          | :resolving
          | :settled
          | :rejected
          | :voided

  @type outcome :: :yes | :no | :void

  @type t :: %__MODULE__{
          id: binary(),
          description: String.t(),
          resolution_criterion: String.t(),
          category: atom(),
          unit_size: pos_integer(),
          expiry: DateTime.t(),
          resolution_deadline: DateTime.t(),
          status: status(),
          pool: AMM.t(),
          creator_account_id: binary(),
          deposit_amount: pos_integer(),
          deposit_subaddress: String.t() | nil,
          deposit_subaddress_index: non_neg_integer() | nil,
          deposit_confirmed_at: DateTime.t() | nil,
          reputation: integer(),
          disputes_acknowledged_count: non_neg_integer(),
          created_at: DateTime.t(),
          resolution_submitted_at: DateTime.t() | nil,
          resolved_at: DateTime.t() | nil,
          outcome: outcome() | nil,
          creator_lp_paid_out_at: DateTime.t() | nil
        }

  @enforce_keys [
    :id,
    :description,
    :resolution_criterion,
    :category,
    :unit_size,
    :expiry,
    :resolution_deadline,
    :status,
    :pool,
    :creator_account_id,
    :deposit_amount,
    :created_at
  ]
  defstruct [
    :id,
    :description,
    :resolution_criterion,
    :category,
    :unit_size,
    :expiry,
    :resolution_deadline,
    :status,
    :pool,
    :creator_account_id,
    :deposit_amount,
    :deposit_subaddress,
    :deposit_subaddress_index,
    :deposit_confirmed_at,
    :created_at,
    :activated_at,
    :resolution_submitted_at,
    :resolved_at,
    :outcome,
    :creator_lp_paid_out_at,
    reputation: 0,
    disputes_acknowledged_count: 0
  ]

  # --- Construction ---

  @doc """
  Creates a new market in `:pending` status with the given parameters.

  Required keys:

  - `:description` — short one-line question (the title)
  - `:resolution_criterion` — longer prose describing how the market resolves
  - `:category` — one of `Categories.all/0`
  - `:unit_size` — atomic-unit size of one contract (e.g. piconeros)
  - `:expiry` — DateTime when betting closes
  - `:resolution_deadline` — DateTime by which operator must resolve
  - `:pool` — initial `AMM.t()` reserves
  - `:creator_account_id` — hashed access code of the creator
  - `:deposit_amount` — escrowed creation deposit in atomic units

  Returns `{:error, :invalid_category}` if the category is not in the
  canonical list.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, atom()}
  def new(opts) do
    description = Keyword.fetch!(opts, :description)
    resolution_criterion = Keyword.fetch!(opts, :resolution_criterion)
    category = Keyword.fetch!(opts, :category)
    unit_size = Keyword.fetch!(opts, :unit_size)
    expiry = Keyword.fetch!(opts, :expiry)
    resolution_deadline = Keyword.fetch!(opts, :resolution_deadline)
    pool = Keyword.fetch!(opts, :pool)
    creator_account_id = Keyword.fetch!(opts, :creator_account_id)
    deposit_amount = Keyword.fetch!(opts, :deposit_amount)
    deposit_subaddress = Keyword.get(opts, :deposit_subaddress)
    deposit_subaddress_index = Keyword.get(opts, :deposit_subaddress_index)
    initial_status = Keyword.get(opts, :status, :awaiting_deposit)

    cond do
      not Categories.valid?(category) ->
        {:error, :invalid_category}

      not (is_integer(unit_size) and unit_size > 0) ->
        {:error, :invalid_unit_size}

      not (is_integer(deposit_amount) and deposit_amount > 0) ->
        {:error, :invalid_deposit_amount}

      # Belt-and-braces: @enforce_keys only checks key presence, not
      # non-nil values. A forged WebSocket frame that bypasses the
      # LiveView auth gate would otherwise persist a market with
      # `creator_account_id: nil`, which has no owner for LP returns
      # or settlement payouts. Account-format validation (locksmith
      # hex shape) belongs in Identity — at this boundary just refuse
      # nil and the empty string.
      not (is_binary(creator_account_id) and byte_size(creator_account_id) > 0) ->
        {:error, :invalid_creator_account_id}

      DateTime.compare(resolution_deadline, expiry) != :gt ->
        {:error, :resolution_before_expiry}

      initial_status == :awaiting_deposit and is_nil(deposit_subaddress) ->
        {:error, :deposit_subaddress_required}

      true ->
        market = %__MODULE__{
          id: generate_id(),
          description: description,
          resolution_criterion: resolution_criterion,
          category: category,
          unit_size: unit_size,
          expiry: expiry,
          resolution_deadline: resolution_deadline,
          status: initial_status,
          pool: pool,
          creator_account_id: creator_account_id,
          deposit_amount: deposit_amount,
          deposit_subaddress: deposit_subaddress,
          deposit_subaddress_index: deposit_subaddress_index,
          created_at: DateTime.utc_now()
        }

        {:ok, market}
    end
  end

  # --- Predicates ---

  @doc """
  True iff `account_id` is the market's creator.

  Centralised so the "is this the creator?" check has a single
  authority. Voter, Disputer, and Trader refuse self-action on the
  creator's own market with distinct error atoms but the same
  underlying identity check; Resolver and Cashier gate creator-only
  paths (resolution submission, LP-return claim) on the inverse.
  LiveView surfaces mirror the same predicate so a button is never
  offered for an action the service layer would refuse.

  Comparison is constant-time via `Plug.Crypto.secure_compare/2` so
  the predicate stays safe to use on money-gating paths (Cashier's LP
  return) alongside the non-monetary moderation paths.

  Non-binary `account_id` (e.g. logged-out viewers passing `nil`)
  returns `false` so callers can use the predicate without first
  guarding the auth state.
  """
  @spec creator?(t(), binary() | nil) :: boolean()
  def creator?(%__MODULE__{creator_account_id: creator}, account_id)
      when is_binary(creator) and is_binary(account_id) do
    Plug.Crypto.secure_compare(creator, account_id)
  end

  def creator?(%__MODULE__{}, _), do: false

  # --- State Transitions ---

  @doc """
  Transitions a market from `:awaiting_deposit` to `:pending` once
  the creation deposit has confirmed on-chain. Stamps
  `deposit_confirmed_at`.
  """
  @spec confirm_deposit(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def confirm_deposit(%__MODULE__{status: :awaiting_deposit} = m) do
    {:ok, %{m | status: :pending, deposit_confirmed_at: DateTime.utc_now()}}
  end

  def confirm_deposit(_), do: {:error, :invalid_transition}

  @doc """
  Transitions a market from `:pending` to `:active` (community approved).
  Stamps `activated_at` with the transition moment — this is the
  market's "trading lifetime" start, used by the LiveView OddsChart
  to set the canvas left edge so the chart represents the period
  when trading was actually possible (not the `:awaiting_deposit` /
  `:pending` lead-in when no trades could happen).
  """
  @spec activate(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def activate(%__MODULE__{status: :pending} = m),
    do: {:ok, %{m | status: :active, activated_at: DateTime.utc_now()}}

  def activate(_), do: {:error, :invalid_transition}

  @doc "Transitions a market from `:pending` to `:rejected` (downvoted out)."
  @spec reject(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def reject(%__MODULE__{status: :pending} = m), do: {:ok, %{m | status: :rejected}}
  def reject(_), do: {:error, :invalid_transition}

  @doc "Transitions a market from `:active` to `:expired` (betting closed)."
  @spec expire(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def expire(%__MODULE__{status: :active} = m), do: {:ok, %{m | status: :expired}}
  def expire(_), do: {:error, :invalid_transition}

  @doc """
  Transitions a market from `:expired` to `:resolving` and records
  the operator's outcome decision. The 24-hour dispute window opens
  here; settlement occurs after the window closes.
  """
  @spec submit_resolution(t(), outcome()) :: {:ok, t()} | {:error, :invalid_transition}
  def submit_resolution(%__MODULE__{status: :expired} = m, outcome)
      when outcome in [:yes, :no, :void] do
    # `resolution_submitted_at` anchors the auto-settle dispute window
    # (see `Markets.Scheduler.auto_settle_uncontested/1`). Stamped
    # exactly once at submit; not refreshed by `reverse_resolution`
    # because the dispute window timing belongs to the original
    # submission, not the federation's later acknowledgement.
    {:ok, %{m | status: :resolving, outcome: outcome, resolution_submitted_at: DateTime.utc_now()}}
  end

  def submit_resolution(_, _), do: {:error, :invalid_transition}

  @doc """
  Reverses a previously submitted resolution while still in the
  dispute window. Allowed only from `:resolving`.
  """
  @spec reverse_resolution(t(), outcome()) :: {:ok, t()} | {:error, :invalid_transition}
  def reverse_resolution(%__MODULE__{status: :resolving} = m, new_outcome)
      when new_outcome in [:yes, :no, :void] do
    {:ok, %{m | outcome: new_outcome}}
  end

  def reverse_resolution(_, _), do: {:error, :invalid_transition}

  @doc """
  Transitions a market from `:resolving` to `:settled` and stamps
  the resolution timestamp. Settlement of positions is handled by
  the orchestration layer.

  A `:void` outcome is refused: voids go through `void/1` (which
  refunds every position). Settling a void-outcome market would
  stamp `:settled` while leaving every position `:open` forever —
  unpayable, un-refundable, terminal.
  """
  @spec settle(t()) :: {:ok, t()} | {:error, :invalid_transition | :invalid_outcome}
  def settle(%__MODULE__{status: :resolving, outcome: outcome} = m)
      when outcome in [:yes, :no] do
    {:ok, %{m | status: :settled, resolved_at: DateTime.utc_now()}}
  end

  def settle(%__MODULE__{status: :resolving}), do: {:error, :invalid_outcome}

  def settle(_), do: {:error, :invalid_transition}

  @doc """
  Voids a market — operator missed the resolution deadline or the
  outcome was undecidable. Allowed from `:expired` or `:resolving`.
  All positions are refunded and no fees collected.
  """
  @spec void(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def void(%__MODULE__{status: status} = m) when status in [:expired, :resolving] do
    {:ok, %{m | status: :voided, outcome: :void, resolved_at: DateTime.utc_now()}}
  end

  def void(_), do: {:error, :invalid_transition}

  # --- Pool Updates ---

  @doc """
  Updates the market's AMM pool with a new pool struct (e.g. after a
  trade). Allowed only while the market is `:active`.
  """
  @spec update_pool(t(), AMM.t()) :: {:ok, t()} | {:error, :invalid_transition}
  def update_pool(%__MODULE__{status: :active} = m, %AMM{} = new_pool) do
    {:ok, %{m | pool: new_pool}}
  end

  def update_pool(_, _), do: {:error, :invalid_transition}

  @doc """
  Stamps `creator_lp_paid_out_at` once the creator's liquidity
  return payout confirms on-chain. Idempotent — refuses on a market
  that already has the stamp so a re-fire from the Signer can't
  double-record. Distinct from `Position.pay_out/2` because the LP
  return lives at the market level (no Position involved); modelled
  the same way to keep the entry/exit symmetry obvious.
  """
  @spec mark_creator_lp_paid_out(t()) :: {:ok, t()} | {:error, :already_paid_out}
  def mark_creator_lp_paid_out(%__MODULE__{creator_lp_paid_out_at: nil} = m) do
    {:ok, %{m | creator_lp_paid_out_at: DateTime.utc_now()}}
  end

  def mark_creator_lp_paid_out(%__MODULE__{}), do: {:error, :already_paid_out}

  # --- Reputation ---

  @doc "Sets the market's reputation score (cached from `Moderation.reputation/1`)."
  @spec put_reputation(t(), integer()) :: t()
  def put_reputation(%__MODULE__{} = m, score) when is_integer(score) do
    %{m | reputation: score}
  end

  @doc """
  Records that the guardian federation has acknowledged the current
  dispute count — that is, has reviewed the disputed resolution and
  either confirmed or reversed it. Sets the count high-water mark so
  later `Resolver.settle/1` can detect new disputes filed after the
  acknowledgement and re-block settlement.
  """
  @spec acknowledge_disputes(t(), non_neg_integer()) :: t()
  def acknowledge_disputes(%__MODULE__{} = m, count)
      when is_integer(count) and count >= 0 do
    %{m | disputes_acknowledged_count: count}
  end

  # --- Predicates ---

  @doc "Returns true if the market's expiry has passed."
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expiry: e}) do
    DateTime.compare(DateTime.utc_now(), e) == :gt
  end

  @doc "Returns true if the market's resolution deadline has passed."
  @spec resolution_overdue?(t()) :: boolean()
  def resolution_overdue?(%__MODULE__{resolution_deadline: d}) do
    DateTime.compare(DateTime.utc_now(), d) == :gt
  end

  # --- Internal ---

  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
