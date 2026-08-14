defmodule PerpWalk.Markets.Position do
  @moduledoc """
  A user's position in a market: N contracts on one side, paid for at
  AMM-quoted cost (including the 1.5% spread).

  Positions transition through:

      OPEN → SETTLED_WINNER   (winning side at resolution)
      OPEN → SETTLED_LOSER    (losing side at resolution)
      OPEN → REFUNDED         (market voided — funds returned)

  The `amount_paid` is the total cost the user paid at AMM quote
  time, in the market's atomic unit (e.g. piconeros). On a winning
  resolution the payout is `contracts × unit_size`; on a losing
  resolution the payout is zero (the `amount_paid` is consumed by
  the settlement). On a void the `amount_paid` is refunded in full.

  Pure module — state transitions only, no IO.
  """

  alias PerpWalk.Markets.AMM

  @type status :: :open | :settled_winner | :settled_loser | :refunded | :paid_out
  @type outcome :: :yes | :no

  @type t :: %__MODULE__{
          id: binary(),
          market_id: binary(),
          account_id: binary(),
          side: AMM.side(),
          contracts: pos_integer(),
          amount_paid: pos_integer(),
          spread_piconeros: non_neg_integer(),
          status: status(),
          created_at: DateTime.t(),
          settled_at: DateTime.t() | nil,
          paid_out_at: DateTime.t() | nil,
          payout_txid: String.t() | nil
        }

  @enforce_keys [
    :id,
    :market_id,
    :account_id,
    :side,
    :contracts,
    :amount_paid,
    :spread_piconeros,
    :status,
    :created_at
  ]
  defstruct [
    :id,
    :market_id,
    :account_id,
    :side,
    :contracts,
    :amount_paid,
    :spread_piconeros,
    :status,
    :created_at,
    :settled_at,
    :paid_out_at,
    :payout_txid
  ]

  # --- Public API ---

  @doc """
  Opens a new position. `contracts`, `amount_paid` and `spread` come
  from the AMM quote at the time of order placement.

  `spread_piconeros` is the 1.5% spread component captured from this
  trade — durably persisted so settlement-time accounting can split
  it into the federation share (1.25% of trade cost) and the creator
  share (0.25% of trade cost) without re-deriving from the original
  pool state.

  The 5-arity form defaults `spread_piconeros: 0`. It exists for
  legacy test callers that don't exercise the federation-revenue
  ledger; production callers (`Trader`) MUST use 6-arity.
  """
  @spec new(binary(), binary(), AMM.side(), pos_integer(), pos_integer()) :: t()
  def new(market_id, account_id, side, contracts, amount_paid),
    do: new(market_id, account_id, side, contracts, amount_paid, 0)

  @spec new(binary(), binary(), AMM.side(), pos_integer(), pos_integer(), non_neg_integer()) :: t()
  def new(market_id, account_id, side, contracts, amount_paid, spread_piconeros)
      when is_binary(market_id) and is_binary(account_id) and side in [:yes, :no] and
             is_integer(contracts) and contracts > 0 and
             is_integer(amount_paid) and amount_paid > 0 and
             is_integer(spread_piconeros) and spread_piconeros >= 0 do
    %__MODULE__{
      id: generate_id(),
      market_id: market_id,
      account_id: account_id,
      side: side,
      contracts: contracts,
      amount_paid: amount_paid,
      spread_piconeros: spread_piconeros,
      status: :open,
      created_at: DateTime.utc_now()
    }
  end

  @doc """
  Settles a position against the market's outcome. The winning side
  becomes `:settled_winner`; the losing side becomes `:settled_loser`.

  Returns `{:error, :invalid_transition}` if the position is not in
  `:open` status.
  """
  @spec settle(t(), outcome()) :: {:ok, t()} | {:error, :invalid_transition}
  def settle(%__MODULE__{status: :open, side: side} = pos, outcome)
      when outcome in [:yes, :no] do
    new_status = if side == outcome, do: :settled_winner, else: :settled_loser
    {:ok, %{pos | status: new_status, settled_at: DateTime.utc_now()}}
  end

  def settle(_, _), do: {:error, :invalid_transition}

  @doc """
  Refunds a position when the market has been voided. Returns
  `{:error, :invalid_transition}` if the position is not open.
  """
  @spec refund(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def refund(%__MODULE__{status: :open} = pos) do
    {:ok, %{pos | status: :refunded, settled_at: DateTime.utc_now()}}
  end

  def refund(_), do: {:error, :invalid_transition}

  @doc """
  Marks a `:settled_winner` or `:refunded` position as `:paid_out`,
  recording the on-chain payout txid. Loser positions are terminal
  with no payout, and `:paid_out` is a one-shot terminal — a second
  call returns `{:error, :already_paid_out}` so accidental
  double-payment can't happen.
  """
  @spec pay_out(t(), String.t()) ::
          {:ok, t()}
          | {:error, :invalid_transition | :already_paid_out}
  def pay_out(%__MODULE__{status: status} = pos, txid)
      when status in [:settled_winner, :refunded] and is_binary(txid) do
    {:ok,
     %{
       pos
       | status: :paid_out,
         paid_out_at: DateTime.utc_now(),
         payout_txid: txid
     }}
  end

  def pay_out(%__MODULE__{status: :paid_out}, _txid), do: {:error, :already_paid_out}
  def pay_out(_, _), do: {:error, :invalid_transition}

  @doc """
  Payout for a position given the market's outcome and atomic
  `unit_size` (the value of one contract). Returns `0` for losers and
  `contracts * unit_size` for winners. Refunded positions return the
  original `amount_paid`.
  """
  @spec payout(t(), pos_integer()) :: non_neg_integer()
  def payout(%__MODULE__{status: :settled_winner, contracts: c}, unit_size)
      when is_integer(unit_size) and unit_size > 0 do
    c * unit_size
  end

  def payout(%__MODULE__{status: :settled_loser}, _unit_size), do: 0

  def payout(%__MODULE__{status: :refunded, amount_paid: amount}, _unit_size), do: amount

  def payout(%__MODULE__{status: :open}, _unit_size), do: 0

  def payout(%__MODULE__{status: :paid_out}, _unit_size), do: 0

  # --- Internal ---

  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
