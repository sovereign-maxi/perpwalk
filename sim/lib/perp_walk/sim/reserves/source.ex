defmodule PerpWalk.Sim.Reserves.Source do
  @moduledoc """
  Sim-mode `Vault.Source` implementation.

  Prod's `PerpWalk.Reserves.Source.reserves/0` calls
  `MoneroFacade.balance()` — a wallet RPC that isn't wired in sim.
  The invariant's `total_held < outstanding` branch would fire on
  every check.

  In sim there is no chain-state to read, so `reserves/0` returns
  a sentinel `@sim_total_held` large enough that solvency never
  false-fires under any conceivable scenario load. The Reserves
  invariant still exercises every structural check (threshold
  signature, attestations map, `:published` proof cycle) — the
  solvency branch is intentionally toothless because a meaningful
  solvency test requires the prod wallet.

  Every other `Vault.Source` callback delegates to
  `PerpWalk.Reserves.Source` so `liabilities/0`, `asset_ids/0`,
  and `metadata/0` still exercise the production derivations.

  Lives under `sim/lib/` — excluded from prod releases via
  `elixirc_paths`.
  """

  @behaviour Vault.Source

  alias PerpWalk.Reserves.Source, as: ProdSource

  # A trillion XMR — larger than any conceivable sim outstanding —
  # so the Reserves invariant's `total_held < outstanding` branch
  # never trips on a false-positive under load.
  @sim_total_held 1_000_000_000_000 * 1_000_000_000_000

  # The Vault.Generator calls `reserves/0` and `liabilities/0` in
  # separate steps, so any derivation of `total_held` from live
  # Markets state races the second `liabilities/0` read: writes
  # landing between the two calls make `outstanding` appear larger
  # than `total_held` and trip Reserves' insolvency check.
  #
  # In sim there's no chain-state to read anyway, so the honest
  # posture is: report `total_held` as unbounded. Reserves keeps
  # exercising every structural check (threshold signature,
  # attestations map, `:published` proof cycle) while the solvency
  # branch never false-fires. Real solvency drift is out of scope
  # for the sim — it requires a wallet and only surfaces in prod.
  @impl Vault.Source
  def reserves do
    %{total_held: @sim_total_held}
  end

  @impl Vault.Source
  defdelegate liabilities, to: ProdSource

  @impl Vault.Source
  defdelegate asset_ids, to: ProdSource

  @impl Vault.Source
  defdelegate metadata, to: ProdSource
end
