defmodule PerpWalk.Sim.Signing.Backend do
  @moduledoc """
  Sim-mode signing backend.

  The prod `Federation.Signer` defaults to a stub that returns
  `{:error, :no_signing_backend_configured}` — safe on production
  nodes without a real Monero multisig coordinator wired, but it
  freezes every enqueued payout at `:pending` in sim runs.

  This backend returns a synthetic hex txid derived from the
  request id, letting the Signer transition payouts through
  `:signing → :submitted → :paid_out` so scenarios can exercise
  the full pipeline and invariants like `PayoutPipeline` +
  `Orphans` see terminal transitions.

  ## Dust guard

  Real prod signing calls Monero wallet-rpc's `transfer` with
  `subtract_fee_from_outputs: [0]`. If the payout amount is below
  the network fee, the wallet-rpc rejects it (`not enough money`).
  This backend mirrors that behaviour: any `:quote_underpayment_refund`
  payout with `amount_piconeros` below `@fee_floor` gets rejected
  so the sim's dust scenario matches prod's dust behaviour and the
  Orphans invariant properly flags a stuck `:open` orphan.

  Lives in `sim/lib/` — excluded from `:prod` elixirc_paths, so
  production releases never load or reference this module.
  """

  alias PerpWalk.Federation.Payout

  # Approximate Monero fee at priority 1, ring 16. Real fee varies
  # with mempool congestion; a fixed floor keeps the sim
  # deterministic while still catching the dust-below-fee case
  # that prod would reject.
  @fee_floor 20_000_000

  @doc """
  Signs a Payout by producing a synthetic hex txid.

  Rejects dust below `@fee_floor` for `:quote_underpayment_refund`
  so the sim's dust underpayment case terminates as
  `PayoutFailed` — same terminal shape prod would produce when
  wallet-rpc refuses the transfer.
  """
  @spec sign(Payout.t()) :: {:ok, binary()} | {:error, term()}
  def sign(%Payout{kind: :quote_underpayment_refund, amount_piconeros: amount})
      when amount < @fee_floor do
    {:error, :amount_below_fee}
  end

  def sign(%Payout{id: id}) do
    {:ok, synthetic_txid(id)}
  end

  # 64-char lowercase hex, deterministic from the payout id so
  # scenario reports stay reproducible across seeds.
  defp synthetic_txid(payout_id) when is_binary(payout_id) do
    :sha256
    |> :crypto.hash("sim-signing-backend:" <> payout_id)
    |> Base.encode16(case: :lower)
  end
end
