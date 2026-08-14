defmodule PerpWalk.Sim.Scenarios.Federation.Income do
  @moduledoc """
  Stresses operator federation-income withdrawal — the half-cap
  security control, uniqueness-scope enforcement, and end-to-end
  accounting.

  Honest actor mix produces the underlying income:

  - Rejected market deposits burn to house.
  - Slashed dispute stakes (adversarial dispute-flag pattern via
    the `Adversary` actor).
  - 5/6 of trade spread on any market that settles.

  Every `:withdraw_every` ticks the scenario reads the current
  withdrawable balance and calls
  `Federation.Console.withdraw_federation_income/3` for
  approximately half of it — matching the operator's expected
  cadence. Every `:concurrent_at` tick the scenario fires two
  withdrawals back-to-back to exercise the uniqueness scope
  (`:federation_income`); the second must reject with
  `:income_already_pending`.

  ## Invariant coverage

  - `Payout.Pipeline` — every enqueued `:federation_income`
    payout must reach a terminal state.
  - `Idempotency` — no two concurrent `:federation_income`
    payouts in flight (uniqueness scope).
  - Conservation — the ledger's `drawn` counter equals the sum
    of successful withdrawal amounts.

  ## Default actor mix

  Standard honest crew scaled up on the disputer side to keep
  slash income flowing. No new actor roles — the withdrawals
  fire from `on_tick/3`.
  """

  @behaviour PerpWalk.Sim.Scenarios.Scenario

  require Logger

  alias PerpWalk.Federation.Console
  alias PerpWalk.Identity.Facade, as: IdentityFacade
  alias PerpWalk.Markets.Federation.Ledger
  alias PerpWalk.Sim.Subaddresses

  @defaults %{
    creators: 5,
    voters: 20,
    traders: 50,
    disputers: 20,
    guardians: 1,
    claimers: 2
  }

  @default_withdraw_every 200
  @default_concurrent_at 400

  @impl PerpWalk.Sim.Scenarios.Scenario
  def init(opts) do
    counts =
      @defaults
      |> Enum.map(fn {role, default} -> {role, Keyword.get(opts, role, default)} end)
      |> Map.new()

    actors = [
      %{role: :creator, count: counts.creators, opts: []},
      %{role: :voter, count: counts.voters, opts: []},
      %{role: :trader, count: counts.traders, opts: []},
      %{role: :disputer, count: counts.disputers, opts: []},
      %{role: :guardian, count: counts.guardians, opts: []},
      %{role: :claimer, count: counts.claimers, opts: []}
    ]

    {:ok, %{account_id: operator_account_id}} = IdentityFacade.register()

    {:ok,
     %{
       actors: actors,
       state: %{
         operator_account_id: operator_account_id,
         withdraw_every: Keyword.get(opts, :withdraw_every, @default_withdraw_every),
         concurrent_at: Keyword.get(opts, :concurrent_at, @default_concurrent_at),
         successful_withdrawals: 0,
         refused_withdrawals: 0
       }
     }}
  end

  @impl PerpWalk.Sim.Scenarios.Scenario
  def on_tick(_now, tick, state) do
    state =
      state
      |> maybe_periodic_withdraw(tick)
      |> maybe_concurrent_burst(tick)

    {:ok, [], state}
  end

  # --- Internal ---

  defp maybe_periodic_withdraw(state, tick) when rem(tick, state.withdraw_every) == 0 and tick > 0 do
    attempt_withdraw_half(state)
  end

  defp maybe_periodic_withdraw(state, _tick), do: state

  defp maybe_concurrent_burst(state, tick) when tick == state.concurrent_at do
    # Fire two back-to-back withdrawals. The second must be
    # refused by the uniqueness scope — that's the coverage.
    state = attempt_withdraw_half(state)
    attempt_withdraw_half(state)
  end

  defp maybe_concurrent_burst(state, _tick), do: state

  defp attempt_withdraw_half(state) do
    available = safe_withdrawable()
    amount = div(available, 2)

    if amount > 0 do
      case Console.withdraw_federation_income(amount, sim_destination(), state.operator_account_id) do
        {:ok, _payout} ->
          %{state | successful_withdrawals: state.successful_withdrawals + 1}

        {:error, reason} ->
          Logger.debug("Federation.Income: withdraw refused, reason=#{inspect(reason)}")
          %{state | refused_withdrawals: state.refused_withdrawals + 1}
      end
    else
      state
    end
  end

  defp safe_withdrawable do
    Ledger.withdrawable_piconeros()
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp sim_destination do
    {:ok, %{address: addr}} = Subaddresses.next()
    addr
  end
end
