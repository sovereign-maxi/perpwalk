defmodule PerpWalk.Markets.Leaderboard do
  @moduledoc """
  Calibration ranking of accounts by prediction accuracy.

  For every `:settled` market with a binary outcome we determine
  each position's correctness by comparing `position.side` against
  `market.outcome`. Accounts are aggregated to `(wins, total)` and
  filtered by a minimum-sample threshold; accounts below the
  threshold don't appear on the leaderboard at all (their win-rate
  is too noisy to be meaningful signal).

  ## What this surface deliberately doesn't show

  - **No PnL or piconero values.** The signal we want to amplify is
    "who's calibrated," not "who's whaling." Showing piconero
    aggregates also doxxes account scale, which compounds across
    markets into a fingerprint.
  - **No per-market positions.** Aggregates only. Same reasoning —
    we don't want to make it cheap to map an account_id to its
    full betting history from this page.
  - **No identifying handle besides the venue-derived one.** Display
    handle comes from `Identity.Account.handle_for/1` against the
    `account_id`, which is itself a salted hash of the keyphrase.

  ## What it does show

  - Rank (by win-rate descending)
  - Friendly handle
  - Total resolved markets the account had a position on
  - Win count
  - Win percentage (integer, no decimal)
  - Last settled-at timestamp — staleness signal

  ## Voided markets

  `:voided` markets refund every position; they don't represent a
  correct/incorrect prediction. They're excluded from both the win
  and total counts so a flurry of voided markets doesn't dilute or
  boost calibration scores.

  ## Status transitions and `:paid_out`

  Once a position transitions from `:settled_winner` to `:paid_out`
  (or `:refunded` → `:paid_out`), the position-side `status` field
  alone no longer encodes whether it was a win. We sidestep that by
  reading from the MARKET side: a position contributes to the
  leaderboard iff its market is `:settled` and the position's side
  matches the market's outcome. The position's status doesn't
  factor into the decision — `:open` positions on settled markets
  shouldn't exist (Resolver's atomic settle transitions every
  open position), but if they do they're just counted by
  side-vs-outcome like the others.

  Pure module — no IO, no GenServer.
  """

  alias PerpWalk.Identity.Facade, as: IdentityFacade
  alias PerpWalk.Markets.{Facade, Market, Position}

  @default_min_resolved 10
  @default_limit 20

  @type entry :: %{
          rank: pos_integer(),
          account_id: binary(),
          handle: String.t(),
          markets_resolved: pos_integer(),
          wins: non_neg_integer(),
          win_pct: 0..100,
          last_active_at: DateTime.t() | nil
        }

  @doc """
  Computes the calibration ranking. Returns a list of entries
  sorted by win percentage descending, then by total resolved
  markets descending (tiebreak — more resolved = more confidence
  in the percentage), then by account_id ascending (final
  deterministic tiebreak).

  ## Options

    * `:min_resolved` (default `10`) — accounts must have at least
      this many resolved markets to appear.
    * `:limit` (default `20`) — how many top entries to return.
  """
  @spec compute(keyword()) :: [entry()]
  def compute(opts \\ []) do
    min_resolved = Keyword.get(opts, :min_resolved, @default_min_resolved)
    limit = Keyword.get(opts, :limit, @default_limit)

    :settled
    |> Facade.list_markets_by_status()
    |> Enum.filter(&binary_outcome?/1)
    |> aggregate_accounts()
    |> Enum.filter(fn {_aid, stats} -> stats.total >= min_resolved end)
    |> Enum.sort_by(&sort_key/1)
    |> Enum.take(limit)
    |> Enum.with_index(1)
    |> Enum.map(&to_entry/1)
  end

  # --- Internal ---

  # Status is already `:settled` (indexed read) — this only screens
  # out `:void` outcomes; `:yes`/`:no` reach the leaderboard.
  defp binary_outcome?(%Market{outcome: outcome}) when outcome in [:yes, :no], do: true
  defp binary_outcome?(_), do: false

  defp aggregate_accounts(settled_markets) do
    settled_markets
    |> Enum.reduce(%{}, fn %Market{} = market, acc ->
      market.id
      |> Facade.list_positions_for_market()
      |> Enum.reduce(acc, fn %Position{} = pos, inner ->
        bump_account(inner, pos.account_id, pos.side == market.outcome, last_active_of(pos))
      end)
    end)
  end

  defp bump_account(acc, account_id, win?, last_at) do
    Map.update(
      acc,
      account_id,
      %{wins: bool_to_int(win?), total: 1, last_active_at: last_at},
      fn current ->
        %{
          wins: current.wins + bool_to_int(win?),
          total: current.total + 1,
          last_active_at: latest(current.last_active_at, last_at)
        }
      end
    )
  end

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0

  # `settled_at` is set during the atomic settle transition; if a
  # position is still `:open` (shouldn't happen on a `:settled`
  # market, but defended against) we fall back to `created_at`.
  defp last_active_of(%Position{settled_at: %DateTime{} = dt}), do: dt
  defp last_active_of(%Position{created_at: %DateTime{} = dt}), do: dt

  defp latest(nil, %DateTime{} = dt), do: dt

  defp latest(%DateTime{} = a, %DateTime{} = b) do
    if DateTime.compare(a, b) == :gt, do: a, else: b
  end

  defp sort_key({account_id, %{wins: wins, total: total}}) do
    pct = win_pct(wins, total)
    # Descending pct, descending total, ascending id.
    {-pct, -total, account_id}
  end

  defp win_pct(_wins, 0), do: 0
  defp win_pct(wins, total), do: div(wins * 100, total)

  defp to_entry({{account_id, stats}, rank}) do
    %{
      rank: rank,
      account_id: account_id,
      handle: IdentityFacade.handle_for(account_id),
      markets_resolved: stats.total,
      wins: stats.wins,
      win_pct: win_pct(stats.wins, stats.total),
      last_active_at: stats.last_active_at
    }
  end
end
