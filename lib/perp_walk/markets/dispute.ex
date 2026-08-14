defmodule PerpWalk.Markets.Dispute do
  @moduledoc """
  A community-flagged dispute against a market's submitted resolution.

  Each `account_id` may flag at most one dispute per market —
  uniqueness is enforced upstream by the dispute store keyed on
  `{account_id, market_id}`. Disputes carry a stake: when a user
  flags a dispute, they're committing XMR to back the claim that
  the resolution is wrong. If guardian re-review confirms the
  creator's resolution, the disputer is partially slashed. If
  guardian re-review reverses it, the disputer's stake is fully
  refunded (and the creator's deposit is slashed instead).

  ## Lifecycle

      :awaiting_deposit  user clicked "dispute", subaddress allocated,
                         waiting for on-chain confirmation
      :live              deposit confirmed; counts toward review threshold
      :resolved_for      guardians confirmed the creator's resolution,
                         this dispute is on the losing side, partial
                         slash
      :resolved_against  guardians reversed the creator's resolution,
                         this dispute is on the winning side, full
                         refund due
      :refunded_full     refund payout submitted on-chain
      :refunded_partial  partial refund (post-slash) payout submitted
                         on-chain

  Threshold counts only `:live` disputes. A user whose deposit
  hasn't confirmed yet is not signal — they haven't committed.
  """

  @type status ::
          :awaiting_deposit
          | :cancelled
          | :live
          | :resolved_for
          | :resolved_against
          | :refunded_full
          | :refunded_partial

  @type t :: %__MODULE__{
          account_id: binary(),
          market_id: binary(),
          status: status(),
          stake_amount_piconeros: pos_integer(),
          deposit_subaddress: String.t(),
          deposit_subaddress_index: non_neg_integer(),
          deposit_confirmed_at: DateTime.t() | nil,
          slashed_amount_piconeros: non_neg_integer(),
          resolved_at: DateTime.t() | nil,
          created_at: DateTime.t()
        }

  @enforce_keys [
    :account_id,
    :market_id,
    :status,
    :stake_amount_piconeros,
    :deposit_subaddress,
    :deposit_subaddress_index,
    :created_at
  ]
  defstruct [
    :account_id,
    :market_id,
    :status,
    :stake_amount_piconeros,
    :deposit_subaddress,
    :deposit_subaddress_index,
    :deposit_confirmed_at,
    :resolved_at,
    :created_at,
    slashed_amount_piconeros: 0
  ]

  # --- Construction ---

  @doc """
  Creates a new dispute in `:awaiting_deposit`. Caller is
  responsible for allocating the subaddress and validating the
  stake amount before reaching this constructor.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, atom()}
  def new(opts) do
    account_id = Keyword.fetch!(opts, :account_id)
    market_id = Keyword.fetch!(opts, :market_id)
    stake = Keyword.fetch!(opts, :stake_amount_piconeros)
    subaddress = Keyword.fetch!(opts, :deposit_subaddress)
    subaddress_index = Keyword.fetch!(opts, :deposit_subaddress_index)

    cond do
      not (is_binary(account_id) and is_binary(market_id)) ->
        {:error, :invalid_account_or_market}

      not (is_integer(stake) and stake > 0) ->
        {:error, :invalid_stake_amount}

      not (is_binary(subaddress) and byte_size(subaddress) > 0) ->
        {:error, :invalid_deposit_subaddress}

      # Index must be strictly positive — index 0 is the wallet's
      # primary address (operator-controlled), never an allocated
      # subaddress. Allowing 0 here would silently skip the
      # `disputes_by_subaddress` index population in
      # `Markets.Store.insert_dispute/2` (which guards on `> 0`),
      # making the deposit invisible to the Poller's by-subaddress
      # attribution and orphaning the funds. The wallet RPC returns
      # monotonically incrementing indexes starting at 1; a 0 here
      # signals an allocator bug or a forged constructor opt.
      not (is_integer(subaddress_index) and subaddress_index > 0) ->
        {:error, :invalid_deposit_subaddress_index}

      true ->
        {:ok,
         %__MODULE__{
           account_id: account_id,
           market_id: market_id,
           status: :awaiting_deposit,
           stake_amount_piconeros: stake,
           deposit_subaddress: subaddress,
           deposit_subaddress_index: subaddress_index,
           created_at: DateTime.utc_now()
         }}
    end
  end

  # --- State Transitions ---

  @doc """
  Transitions `:awaiting_deposit → :live` once the on-chain
  deposit confirms. Stamps `deposit_confirmed_at`.
  """
  @spec confirm_deposit(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def confirm_deposit(%__MODULE__{status: :awaiting_deposit} = d) do
    {:ok, %{d | status: :live, deposit_confirmed_at: DateTime.utc_now()}}
  end

  def confirm_deposit(_), do: {:error, :invalid_transition}

  @doc """
  Transitions `:awaiting_deposit → :cancelled` — the disputer
  closed the modal without funding. Terminal status; the WAL
  retains the record for audit but the UI filters it out, and a
  fresh dispute on the same `(account, market)` is permitted.
  """
  @spec cancel(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def cancel(%__MODULE__{status: :awaiting_deposit} = d) do
    {:ok, %{d | status: :cancelled, resolved_at: DateTime.utc_now()}}
  end

  def cancel(_), do: {:error, :invalid_transition}

  @doc """
  Transitions `:live → :resolved_for` — guardians confirmed the
  creator's resolution. Disputer was wrong; partial slash applies.
  Records the absolute slashed amount for accounting.
  """
  @spec resolve_for(t(), pos_integer()) :: {:ok, t()} | {:error, :invalid_transition}
  def resolve_for(%__MODULE__{status: :live} = d, slashed_amount)
      when is_integer(slashed_amount) and slashed_amount >= 0 and
             slashed_amount <= d.stake_amount_piconeros do
    {:ok,
     %{
       d
       | status: :resolved_for,
         slashed_amount_piconeros: slashed_amount,
         resolved_at: DateTime.utc_now()
     }}
  end

  def resolve_for(_, _), do: {:error, :invalid_transition}

  @doc """
  Transitions `:live → :resolved_against` — guardians reversed
  the creator's resolution. Disputer was right; full refund due,
  no slash.
  """
  @spec resolve_against(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def resolve_against(%__MODULE__{status: :live} = d) do
    {:ok, %{d | status: :resolved_against, resolved_at: DateTime.utc_now()}}
  end

  def resolve_against(_), do: {:error, :invalid_transition}

  @doc """
  Transitions a resolved dispute to its terminal refunded state.
  `:resolved_for → :refunded_partial`, `:resolved_against →
  :refunded_full`. Used after the federation submits the refund
  payout transaction.
  """
  @spec mark_refunded(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def mark_refunded(%__MODULE__{status: :resolved_for} = d) do
    {:ok, %{d | status: :refunded_partial}}
  end

  def mark_refunded(%__MODULE__{status: :resolved_against} = d) do
    {:ok, %{d | status: :refunded_full}}
  end

  def mark_refunded(_), do: {:error, :invalid_transition}

  # --- Predicates ---

  @doc "Returns true if the dispute counts toward the review threshold."
  @spec live?(t()) :: boolean()
  def live?(%__MODULE__{status: :live}), do: true
  def live?(_), do: false

  @doc """
  True for any dispute that has had a non-zero slash applied —
  i.e. terminal `:resolved_for` or `:refunded_partial`. Used by the
  operator-income ledger to sum house earnings.
  """
  @spec slashed?(t()) :: boolean()
  def slashed?(%__MODULE__{status: status, slashed_amount_piconeros: amount})
      when status in [:resolved_for, :refunded_partial] and amount > 0,
      do: true

  def slashed?(_), do: false

  @doc "The amount that should be refunded given the current dispute state."
  @spec refund_amount_piconeros(t()) :: non_neg_integer()
  def refund_amount_piconeros(%__MODULE__{
        status: :resolved_for,
        stake_amount_piconeros: stake,
        slashed_amount_piconeros: slashed
      }) do
    stake - slashed
  end

  def refund_amount_piconeros(%__MODULE__{
        status: :resolved_against,
        stake_amount_piconeros: stake
      }) do
    stake
  end

  def refund_amount_piconeros(_), do: 0
end
