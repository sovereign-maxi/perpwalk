defmodule PerpWalk.Monero.Address do
  @moduledoc """
  Monero address operations, scoped to the configured network.

  Address prefix characters by network:

    * Mainnet:  `4` (standard / integrated), `8` (subaddress)
    * Stagenet: `5` (standard / integrated), `7` (subaddress)
    * Testnet:  `9` or `A` (standard / integrated), `B` (subaddress)

  The single source of truth for "is this a valid address right now":
  cashier, federation rules, peer signing policy, and the user-facing
  claim form all consult `valid?/1` so flipping network is a config
  change, not a coordinated edit across four call sites.

  Network selection lives in `PerpWalk.Monero.Network`.
  """

  alias PerpWalk.Monero.Network

  # Hard cap on input length before the regex runs. Real Monero
  # addresses max out at 106 chars; rejecting >150 bounds adversarial
  # input even though Elixir's regex engine is generally bounded.
  @max_input_length 150

  @doc """
  True if the address is valid for the active Monero network.
  """
  @spec valid?(any()) :: boolean()
  def valid?(addr) when is_binary(addr) and byte_size(addr) <= @max_input_length do
    Regex.match?(regex(), addr)
  end

  def valid?(_), do: false

  @doc "Network-specific address regex."
  @spec regex() :: Regex.t()
  def regex do
    case Network.current() do
      :stagenet -> ~r/^[57][1-9A-HJ-NP-Za-km-z]{94,105}$/
      :testnet -> ~r/^[9AB][1-9A-HJ-NP-Za-km-z]{94,105}$/
      _ -> ~r/^[48][1-9A-HJ-NP-Za-km-z]{94,105}$/
    end
  end

  @doc "Human-readable prefix description for user-facing copy."
  @spec prefix_description() :: String.t()
  def prefix_description do
    case Network.current() do
      :stagenet -> "5 (standard) or 7 (subaddress)"
      :testnet -> "9, A, or B"
      _ -> "4 (standard/integrated) or 8 (subaddress)"
    end
  end

  @doc "Maximum accepted input length for an address (defeats ReDoS on adversarial input)."
  @spec max_input_length() :: pos_integer()
  def max_input_length, do: @max_input_length
end
