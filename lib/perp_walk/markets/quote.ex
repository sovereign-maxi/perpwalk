defmodule PerpWalk.Markets.Quote do
  @moduledoc """
  A pending trade waiting for on-chain confirmation.

  PERP WALK uses per-trade subaddresses (see
  `project_perp_walk_money_flow.md` memory) — every Buy click
  generates a fresh subaddress, the user pays into it, and the
  position only materialises once `Darks.Poller` sees the deposit
  confirmed.

  Quotes lock in:
  - `contracts` — the share count the user is buying
  - `amount_paid_piconeros` — the locked-in cost at quote time
    (cost from `AMM.quote/3` converted via `AMM.cost_to_piconeros/2`
    at the market's `unit_size`)

  At fill time, the AMM is consulted again with the
  current pool state. If the locked-in cost still buys at least
  `contracts` shares, we fill at the locked cost. Otherwise the
  quote is invalidated and refunded.

  Pure module — no IO, no GenServer.
  """

  alias PerpWalk.Markets.AMM
  alias PerpWalk.Monero.Address

  @type t :: %__MODULE__{
          id: binary(),
          market_id: binary(),
          account_id: binary(),
          side: AMM.side(),
          contracts: pos_integer(),
          amount_paid_piconeros: pos_integer(),
          spread_piconeros: non_neg_integer(),
          subaddress: String.t(),
          subaddress_index: non_neg_integer(),
          refund_address: String.t(),
          expires_at: DateTime.t(),
          created_at: DateTime.t()
        }

  @enforce_keys [
    :id,
    :market_id,
    :account_id,
    :side,
    :contracts,
    :amount_paid_piconeros,
    :spread_piconeros,
    :subaddress,
    :subaddress_index,
    :refund_address,
    :expires_at,
    :created_at
  ]
  defstruct [
    :id,
    :market_id,
    :account_id,
    :side,
    :contracts,
    :amount_paid_piconeros,
    :spread_piconeros,
    :subaddress,
    :subaddress_index,
    :refund_address,
    :expires_at,
    :created_at
  ]

  @doc """
  Builds a Quote with a generated id and `:created_at = utc_now`.

  All amounts are in piconeros (1 XMR = 1_000_000_000_000 piconeros).
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    market_id = Keyword.fetch!(opts, :market_id)
    account_id = Keyword.fetch!(opts, :account_id)
    side = Keyword.fetch!(opts, :side)
    contracts = Keyword.fetch!(opts, :contracts)
    amount_paid_piconeros = Keyword.fetch!(opts, :amount_paid_piconeros)
    spread_piconeros = Keyword.fetch!(opts, :spread_piconeros)
    subaddress = Keyword.fetch!(opts, :subaddress)
    subaddress_index = Keyword.fetch!(opts, :subaddress_index)
    refund_address = Keyword.fetch!(opts, :refund_address)
    expires_at = Keyword.fetch!(opts, :expires_at)

    valid_side!(side)
    valid_contracts!(contracts)
    valid_amount!(amount_paid_piconeros)
    valid_spread!(spread_piconeros)
    valid_subaddress_index!(subaddress_index)
    valid_refund_address!(refund_address)

    %__MODULE__{
      id: generate_id(),
      market_id: market_id,
      account_id: account_id,
      side: side,
      contracts: contracts,
      amount_paid_piconeros: amount_paid_piconeros,
      spread_piconeros: spread_piconeros,
      subaddress: subaddress,
      subaddress_index: subaddress_index,
      refund_address: refund_address,
      expires_at: expires_at,
      created_at: DateTime.utc_now()
    }
  end

  @doc "Returns true once `expires_at` has passed."
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{expires_at: at}, %DateTime{} = now) do
    DateTime.compare(now, at) != :lt
  end

  # --- Internal ---

  defp valid_side!(side) when side in [:yes, :no], do: :ok
  defp valid_side!(side), do: raise(ArgumentError, "invalid side: #{inspect(side)}")

  defp valid_contracts!(c) when is_integer(c) and c > 0, do: :ok
  defp valid_contracts!(c), do: raise(ArgumentError, "contracts must be positive integer, got: #{inspect(c)}")

  defp valid_amount!(a) when is_integer(a) and a > 0, do: :ok
  defp valid_amount!(a), do: raise(ArgumentError, "amount_paid_piconeros must be positive integer, got: #{inspect(a)}")

  defp valid_spread!(s) when is_integer(s) and s >= 0, do: :ok
  defp valid_spread!(s), do: raise(ArgumentError, "spread_piconeros must be non-negative integer, got: #{inspect(s)}")

  # Index must be strictly positive — index 0 is the wallet's
  # primary address. Allowing 0 here would silently skip
  # `quotes_by_subaddress` population in `Markets.Store.insert_quote/2`
  # (which guards on `> 0`) and the Poller would be unable to attribute
  # the deposit, orphaning the funds.
  defp valid_subaddress_index!(i) when is_integer(i) and i > 0, do: :ok

  defp valid_subaddress_index!(i),
    do: raise(ArgumentError, "subaddress_index must be a positive integer, got: #{inspect(i)}")

  # Refund destination the user provides at quote creation. Delegates
  # format validation to `PerpWalk.Monero.Address.valid?/1` — same check
  # `Federation.Rules.destination_sanity` uses on payout destinations,
  # so refund_address and payout destination validation stay in lockstep.
  defp valid_refund_address!(addr) when is_binary(addr) do
    if Address.valid?(addr),
      do: :ok,
      else: raise(ArgumentError, "refund_address is not a well-formed Monero address")
  end

  defp valid_refund_address!(other),
    do: raise(ArgumentError, "refund_address must be a string, got: #{inspect(other)}")

  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
