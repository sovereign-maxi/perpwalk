defmodule PerpWalk.Markets.Moderation do
  @moduledoc """
  Pure community-moderation logic.

  Markets accumulate `Vote.t()` entries during their PENDING window.
  Strong negative community consensus triggers rejection — the
  creator's escrow deposit is sent to a verifiably unspendable
  address. This is the platform's only content-moderation lever;
  the operator never makes a content call.

  ## Burn decision: Wilson score lower bound

  The burn decision uses the lower bound of a one-sided Wilson
  score confidence interval on the downvote proportion. Reject
  when that lower bound crosses `burn_wilson_lower` (default
  0.6) AND total votes meet `burn_min_votes` (default 5).

  Why Wilson and not "net −N votes":

  - A net counter doesn't scale with sample size. 5 down on a
    market with 5 votes is "everyone hates it"; 5 down on a
    market with 100 votes is noise.
  - Wilson naturally requires more votes to be confident. A
    coordinated 5-troll cohort can't burn a fresh market because
    the lower bound on 5/5 is ~0.566 (below the 0.6 cutoff).
    Push to 6/6 and the lower bound is ~0.610 — burn.
  - Large-sample slim-majority downvotes don't trigger either:
    10/15 down is 67% but the lower bound is ~0.42.

  Pure module — no IO, no process state, no DateTime. Thresholds
  are read from application config so operators can tune
  per-deployment.
  """

  alias PerpWalk.Markets.Vote

  # --- Defaults ---

  # Lower bound on the Wilson confidence interval for the downvote
  # proportion at which a market is rejected. A small enough number
  # to make obvious 6-of-6 spam burns reachable; large enough that
  # a slim majority doesn't trigger.
  @default_burn_wilson_lower 0.6

  # Minimum total votes before a burn can fire. Wilson with very
  # small N is conservative enough on its own (1/1 down → ~0.05
  # lower bound), but the floor makes the operator-facing semantics
  # explicit: "below this many votes, no burn regardless."
  @default_burn_min_votes 5

  # Z-score for the Wilson interval. 1.96 ≈ 95% confidence.
  @default_burn_wilson_z 1.96

  # Absolute floor of unique dispute flags at which guardian re-review
  # is mandatory. Guards small markets — without it, a market with
  # only 3 position holders could be locked by 1 disputer if the
  # ratio were the only check.
  @default_dispute_threshold 5

  # Population ratio for scale-invariant review trigger. Applied on
  # top of the absolute floor: a market with 1000 position holders
  # needs `ceil(1000 * 0.05) = 50` disputers to trigger review, not
  # the small-market floor of 5.
  @default_dispute_ratio 0.05

  # Dispute stake as a percentage of the creator's initial liquidity
  # (LP seed), in basis points. 1000 bp = 10%.
  #
  # The stake scales deterministically with the creator's own
  # commitment: 1 XMR seeded → 0.1 XMR stake, 10 XMR → 1 XMR, etc.
  # No floor / ceiling logic — the deposit min/max (`min_deposit_piconeros`
  # / `max_deposit_piconeros` in `Markets.Services.Maker`) already
  # bound the effective range. Volume is deliberately ignored so
  # wash-trading between sock-puppets cannot influence the stake.
  @default_dispute_stake_pct_bps 1000

  # Slash percentage when a dispute is rejected (creator confirmed).
  # 50 = 50%. Configurable per-deployment.
  @default_dispute_slash_pct 50

  # --- Public API ---

  @doc """
  Net reputation: `up_count - down_count`. Higher is better; markets
  below the burn threshold (in absolute terms) are rejected.
  """
  @spec reputation([Vote.t()]) :: integer()
  def reputation(votes) when is_list(votes) do
    Enum.reduce(votes, 0, fn
      %Vote{direction: :up}, acc -> acc + 1
      %Vote{direction: :down}, acc -> acc - 1
    end)
  end

  @doc """
  Returns `true` if the votes warrant burning the market's creation
  deposit.

  Accepts a keyword opts list:

  - `:lower` — Wilson lower-bound cutoff in [0, 1]. Defaults to
    `#{@default_burn_wilson_lower}`.
  - `:min_votes` — minimum total votes before a burn can fire.
    Defaults to `#{@default_burn_min_votes}`.
  - `:z` — Wilson z-score (95% ≈ 1.96). Defaults to
    `#{@default_burn_wilson_z}`.
  """
  @spec burn?([Vote.t()]) :: boolean()
  def burn?(votes) when is_list(votes), do: burn?(votes, [])

  @spec burn?([Vote.t()], keyword()) :: boolean()
  def burn?(votes, opts) when is_list(votes) and is_list(opts) do
    lower_cut = Keyword.get(opts, :lower, default_burn_wilson_lower())
    min_votes = Keyword.get(opts, :min_votes, default_burn_min_votes())
    z = Keyword.get(opts, :z, default_burn_wilson_z())

    {up, down} = tally(votes)
    total = up + down

    total >= min_votes and wilson_lower(down, total, z) >= lower_cut
  end

  @doc """
  Counts votes by direction. Returns `{up_count, down_count}`.
  """
  @spec tally([Vote.t()]) :: {non_neg_integer(), non_neg_integer()}
  def tally(votes) when is_list(votes) do
    Enum.reduce(votes, {0, 0}, fn
      %Vote{direction: :up}, {u, d} -> {u + 1, d}
      %Vote{direction: :down}, {u, d} -> {u, d + 1}
    end)
  end

  @doc """
  One-sided Wilson lower bound on the down-vote proportion for `d`
  downvotes out of `n` total votes at z-score `z`. Returns `0.0`
  for `n == 0` so callers don't have to special-case it.
  """
  @spec wilson_lower(non_neg_integer(), non_neg_integer(), float()) :: float()
  def wilson_lower(_d, 0, _z), do: 0.0

  def wilson_lower(d, n, z)
      when is_integer(d) and is_integer(n) and d >= 0 and n > 0 and d <= n and is_number(z) and
             z > 0 do
    p_hat = d / n
    z2 = z * z
    numerator = p_hat + z2 / (2 * n) - z * :math.sqrt(p_hat * (1 - p_hat) / n + z2 / (4 * n * n))
    denominator = 1 + z2 / n

    # The closed form returns a near-zero negative for p_hat = 0
    # (floating-point dust in the sqrt + subtraction). Clamp to
    # [0.0, 1.0] for a clean lower bound.
    (numerator / denominator) |> max(0.0) |> min(1.0)
  end

  @doc "Default Wilson lower-bound cutoff for burn decision."
  @spec default_burn_wilson_lower() :: float()
  def default_burn_wilson_lower do
    get_moderation_config(:burn_wilson_lower, @default_burn_wilson_lower)
  end

  @doc "Default minimum total votes before a burn can fire."
  @spec default_burn_min_votes() :: pos_integer()
  def default_burn_min_votes do
    get_moderation_config(:burn_min_votes, @default_burn_min_votes)
  end

  @doc "Default Wilson z-score for burn decision."
  @spec default_burn_wilson_z() :: float()
  def default_burn_wilson_z do
    get_moderation_config(:burn_wilson_z, @default_burn_wilson_z)
  end

  @doc """
  Returns `true` if the dispute count warrants mandatory guardian
  re-review, scale-invariant against the size of the trader
  population.

  Threshold is `max(absolute_floor, ceil(position_holders * ratio))`:

  - The absolute floor (default 5) guards small markets — a market
    with 10 traders still needs 5 disputers to trigger review
    (50% of population), not 1.
  - The ratio (default 5%) ensures large markets scale up — a
    market with 1000 traders needs 50 disputers, not 5, so a
    coordinated 5-wallet attacker can't lock a high-volume market.

  Both knobs are configurable via `:moderation, :dispute_floor` and
  `:moderation, :dispute_ratio`. The mechanical rule stays simple
  (two ints, one multiplication, one max) which keeps the operator-
  intervention surface defensible as non-discretionary — distinct
  from "Wilson-95% with z-score Bayesian prior" which reads as
  curated discretion in the venue-as-oracle framing.
  """
  @spec dispute_review_required?(non_neg_integer(), non_neg_integer()) :: boolean()
  def dispute_review_required?(dispute_count, position_holders)
      when is_integer(dispute_count) and dispute_count >= 0 and
             is_integer(position_holders) and position_holders >= 0 do
    dispute_count >= scaled_threshold(position_holders)
  end

  @doc """
  Scaled review threshold for a given position-holder count.
  Exposed so the disputer can include it in
  `DisputeReReviewTriggered` for audit / dashboard surface.
  """
  @spec scaled_threshold(non_neg_integer()) :: pos_integer()
  def scaled_threshold(position_holders) when is_integer(position_holders) and position_holders >= 0 do
    floor = dispute_floor()
    ratio = dispute_ratio()
    max(floor, ceil(position_holders * ratio))
  end

  @doc "Absolute floor — minimum disputers required regardless of market size."
  @spec dispute_floor() :: pos_integer()
  def dispute_floor do
    get_moderation_config(:dispute_floor, @default_dispute_threshold)
  end

  @doc "Population ratio — fraction of position holders required (default 5%)."
  @spec dispute_ratio() :: float()
  def dispute_ratio do
    get_moderation_config(:dispute_ratio, @default_dispute_ratio)
  end

  @doc "Default dispute threshold (absolute floor)."
  @spec default_dispute_threshold() :: pos_integer()
  def default_dispute_threshold, do: @default_dispute_threshold

  @doc """
  Computes the per-disputer stake amount for a market. Fixed
  percentage of the creator's initial liquidity (LP seed), read
  from `:dispute_stake_pct_bps` config (default 1000 bps = 10%).

  Deterministic: the same deposit always yields the same stake.
  A serious market (large seed) demands a serious challenger
  (proportionally large stake). Volume is not a factor — wash-
  trading cannot influence the stake.
  """
  @spec dispute_stake_for_market(pos_integer()) :: pos_integer()
  def dispute_stake_for_market(deposit_amount)
      when is_integer(deposit_amount) and deposit_amount > 0 do
    pct_bps = get_config(:dispute_stake_pct_bps, @default_dispute_stake_pct_bps)
    div(deposit_amount * pct_bps, 10_000)
  end

  @doc "Slash percentage applied to disputers on the losing side. 0..100."
  @spec dispute_slash_pct() :: 0..100
  def dispute_slash_pct do
    pct = get_config(:dispute_slash_pct, @default_dispute_slash_pct)

    cond do
      not is_integer(pct) -> @default_dispute_slash_pct
      pct < 0 -> 0
      pct > 100 -> 100
      true -> pct
    end
  end

  @doc "Computes the absolute slash amount for a stake at the configured slash %."
  @spec slash_amount(pos_integer()) :: non_neg_integer()
  def slash_amount(stake) when is_integer(stake) and stake > 0 do
    div(stake * dispute_slash_pct(), 100)
  end

  defp get_config(key, default) do
    :perpwalk
    |> Application.get_env(:disputes, [])
    |> Keyword.get(key, default)
  end

  defp get_moderation_config(key, default) do
    :perpwalk
    |> Application.get_env(:moderation, [])
    |> Keyword.get(key, default)
  end
end
