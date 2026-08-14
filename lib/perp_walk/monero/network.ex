defmodule PerpWalk.Monero.Network do
  @moduledoc """
  Currently configured Monero network for this deployment.

  One of `:mainnet`, `:stagenet`, or `:testnet`. Selected at boot from
  the `PERP_WALK_NETWORK` environment variable via `config/runtime.exs`.
  Defaults to `:mainnet` when unset.

  Every Monero-touching surface (address validation, future address
  parsing, future confirmation thresholds, future block-explorer URLs)
  routes through here so flipping network is a single boot-time switch.
  """

  @type t :: :mainnet | :stagenet | :testnet

  @doc "The active Monero network for this deployment."
  @spec current() :: t()
  def current, do: Application.get_env(:perpwalk, :network, :mainnet)
end
