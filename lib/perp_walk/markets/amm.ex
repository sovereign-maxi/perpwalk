defmodule PerpWalk.Markets.AMM do
  @moduledoc """
  Polymarket-style FPMM (Fixed Product Market Maker) for binary
  YES/NO outcome markets.

  Pool reserves and AMM costs are integer **subunit** counts, where
  one user-facing contract equals `pool_scale/0` subunits (currently
  `1000`). The constant-product invariant `K = YES × NO` defines the
  pricing curve.

  ## Why subunits

  At single-contract trade sizes on modest-depth pools, naive
  integer arithmetic on contract-granular reserves rounds the
  quadratic-solved cost catastrophically upward — a 0.5006-contract
  fair cost ceilings to 1 contract, then a 0.015-contract spread
  ceilings to another 1, yielding 2 contracts of cost on a 1-contract
  trade. Effective spread becomes ~300% instead of 3%.

  Storing the pool 1000× denser fixes this without changing the
  user-facing semantics. The same trade now rounds at 0.001-contract
  precision: 0.5006 → 501 subunits (0.501 contracts), spread 8 subunits
  (0.008 contracts), total 509 subunits ≈ 0.509 contracts of cost. Fair
  price restored.

  Callers convert at the boundary via `to_subunits/1` (contracts →
  subunits, for the AMM input) and `cost_to_piconeros/2` (subunit
  cost → piconero amount, for persisted Position / Quote amounts).
  The pool reserves never appear in user-facing displays — those go
  through `mid_probability/2` (a ratio; scale-invariant) or the
  position summary (denominated in piconeros).

  ## Pool seeding (LP-capital model)

  The initial reserves represent **real collateral** put up by the
  market creator (the sole LP per market). With deposit `D` and unit
  size `U`, the pool starts at `(D/U) × pool_scale` subunits on each
  side — backed by `D` of real collateral via the conditional-tokens
  construction (1 YES + 1 NO = 1 collateral unit). This is what
  gives the FPMM its solvency guarantee: at any state, the winning
  side's claims at resolution exactly equal the collateral collected.
  The operator never has to deploy capital under any market outcome.

  See `Markets.Services.Maker.create_market/1` for the seeding code
  path and `project_perp_walk_creator_lp_model.md` for the economic
  framing.

  ## Conditional-tokens model

  A buy is modelled as a 1:1 collateral split: the user deposits `c`
  collateral, which mints `c YES + c NO` via the conditional-tokens
  framework. The pool absorbs all `c` of the opposite-side tokens,
  growing that reserve by `c`. The pool's bought-side reserve adjusts
  to maintain `K`, ending at `(bought + c - dY, other + c)`. The
  user keeps `dY` contracts.

  Solving for `c` given target `dY` yields a quadratic:

      c² + c(bought + other − dY) − dY · other = 0
      c = (−(bought + other − dY) + √((bought + other − dY)² + 4·dY·other)) / 2

  This collateral-splitting structure is what makes FPMM pricing
  match marginal probability for small trades. A plain
  "user-takes-contracts-out-of-pool" constant product (without
  splitting) overcharges by a constant factor at every trade size —
  the operator's edge becomes the curve itself rather than the
  documented spread.

  Marginal probability is `other_reserve / (bought + other)`; the
  two sides sum to 1 exactly at the marginal point before the
  spread is applied.

  ## Spread

  A **1.5% spread** is applied on top of every trade's fair-curve cost
  via ceiling division (fractional remainders favour the house). The
  spread component is returned separately from the fair cost by
  `quote_breakdown/3` so callers can persist it on the Position's
  `spread_piconeros` field. At settlement, `Markets.Federation.Ledger`
  splits the accumulated spread into a **1.25% federation share** and a
  **0.25% creator share** (the creator share is paid via
  `Cashier.claim_creator_lp_return/3` as part of the creator's
  LP-return payout).

  ## Rounding

  Both the discriminant's square root and the final division-by-2 use
  ceiling rounding, so any fractional remainder is captured as a
  larger cost (operator's favour). This means:

  - The pool's `K` may drift fractionally upward over many trades
    (in the operator's favour). Tests assert `K_new ≥ K_old`.
  - A trade for very small contract counts on a deep pool can round
    up to a single integer of cost; this is acceptable.
  - The pool can never collapse to zero on either side: callers must
    provide initial reserves large enough that the smallest expected
    trade is meaningful.

  Pure module — no IO, no GenServer, no process state.
  """

  # --- Constants ---

  # Per-trade spread in parts per million. 15_000 ppm = 1.5%.
  @spread_ppm 15_000
  @ppm 1_000_000

  # Subunits per user-facing contract. Pool reserves and AMM cost
  # outputs are expressed in subunits so the quadratic-solved cost
  # rounds at sub-contract precision rather than whole-contract
  # precision. See moduledoc "Why subunits". 1000 gives 0.001-
  # contract precision, which is finer than any display rounds to
  # and leaves enormous headroom under 64-bit integer arithmetic.
  @pool_scale 1000

  # --- Types ---

  @type t :: %__MODULE__{yes: pos_integer(), no: pos_integer()}
  @type side :: :yes | :no

  @enforce_keys [:yes, :no]
  defstruct [:yes, :no]

  # --- Public API ---

  @doc """
  Subunits per user-facing contract. Public so callers can divide
  pool reserves back to contract-count for operator displays.
  """
  @spec pool_scale() :: pos_integer()
  def pool_scale, do: @pool_scale

  @doc """
  Converts a whole-contract count to subunits (multiplies by
  `pool_scale/0`). Callers pass the result into `quote/3` or
  `quote_breakdown/3`.
  """
  @spec to_subunits(non_neg_integer()) :: non_neg_integer()
  def to_subunits(contracts) when is_integer(contracts) and contracts >= 0 do
    contracts * @pool_scale
  end

  @doc """
  Converts a subunit cost (from `quote/3` or `quote_breakdown/3`,
  or a raw pool reserve) to piconeros at the market's `unit_size`.

  Uses ceiling division on the `/ pool_scale` step so any fractional
  remainder favours the house — same rounding direction as the AMM's
  internal cost computation.

      cost_to_piconeros(509, 10_000_000_000) == 5_090_000_000
      cost_to_piconeros(1, 10_000_000_000) == 10_000_000  # 1 subunit = 1/1000 contract
  """
  @spec cost_to_piconeros(non_neg_integer(), pos_integer()) :: non_neg_integer()
  def cost_to_piconeros(cost_subunits, unit_size_piconeros)
      when is_integer(cost_subunits) and cost_subunits >= 0 and
             is_integer(unit_size_piconeros) and unit_size_piconeros > 0 do
    ceil_div(cost_subunits * unit_size_piconeros, @pool_scale)
  end

  @doc """
  Creates a pool with positive YES and NO reserves (in subunits).
  The product `yes * no` becomes the initial invariant `K`. Callers
  should pass already-scaled values, typically via `to_subunits/1`
  applied to a contract-count pool depth.
  """
  @spec new(pos_integer(), pos_integer()) :: t()
  def new(yes, no) when is_integer(yes) and yes > 0 and is_integer(no) and no > 0 do
    %__MODULE__{yes: yes, no: no}
  end

  @doc "Constant-product invariant `K = YES × NO`."
  @spec invariant(t()) :: pos_integer()
  def invariant(%__MODULE__{yes: y, no: n}), do: y * n

  @doc """
  Marginal probability of `side` as a `{numerator, denominator}`
  tuple of integers — the caller can format it however they need
  (percentage, decimal, basis points) without losing precision.

  YES probability is `NO_reserve / total`; NO probability is
  `YES_reserve / total`. The two sum to 1 exactly at the marginal
  point (before the 1.5% spread is added).
  """
  @spec mid_probability(t(), side()) :: {non_neg_integer(), pos_integer()}
  def mid_probability(%__MODULE__{yes: y, no: n}, :yes), do: {n, y + n}
  def mid_probability(%__MODULE__{yes: y, no: n}, :no), do: {y, y + n}

  @doc """
  Quotes the cost of buying `contracts_subunits` of `side` and
  returns the resulting pool. Both the requested amount and the
  returned cost are in **subunits** — callers convert at the boundary
  via `to_subunits/1` and `cost_to_piconeros/2`.

  Returns:
  - `{:ok, cost, new_pool}` on success — `cost` is in subunits and
    includes the 1.5% spread markup
  - `{:error, :insufficient_liquidity}` if the trade would empty
    the source side

  The spread is applied with ceiling division; fractional
  remainders favour the house.
  """
  @spec quote(t(), side(), pos_integer()) ::
          {:ok, pos_integer(), t()} | {:error, :insufficient_liquidity | :invalid_contracts}
  def quote(pool, side, contracts_subunits) do
    case quote_breakdown(pool, side, contracts_subunits) do
      {:ok, %{cost: cost, pool: new_pool}} -> {:ok, cost, new_pool}
      {:error, _} = err -> err
    end
  end

  @doc """
  Like `quote/3` but returns the spread component separately so the
  caller can durably record it. Use this when persisting a Quote /
  Position so settlement-time accounting can split the spread into
  federation vs creator revenue.

      {:ok, %{cost: 1015, amm_cost: 1000, spread: 15, pool: pool'}}

  All four numeric fields are in subunits.
  """
  @spec quote_breakdown(t(), side(), pos_integer()) ::
          {:ok, %{cost: pos_integer(), amm_cost: pos_integer(), spread: non_neg_integer(), pool: t()}}
          | {:error, :insufficient_liquidity | :invalid_contracts}
  def quote_breakdown(%__MODULE__{yes: y, no: n}, :yes, contracts)
      when is_integer(contracts) and contracts > 0 do
    if contracts >= y do
      {:error, :insufficient_liquidity}
    else
      amm_cost = fpmm_cost(y, n, contracts)
      new_n = n + amm_cost
      new_y = y + amm_cost - contracts
      assert_invariant_non_decreasing!(y * n, new_y * new_n, {:yes, contracts, y, n})
      build_breakdown(amm_cost, %__MODULE__{yes: new_y, no: new_n})
    end
  end

  def quote_breakdown(%__MODULE__{yes: y, no: n}, :no, contracts)
      when is_integer(contracts) and contracts > 0 do
    if contracts >= n do
      {:error, :insufficient_liquidity}
    else
      amm_cost = fpmm_cost(n, y, contracts)
      new_y = y + amm_cost
      new_n = n + amm_cost - contracts
      assert_invariant_non_decreasing!(y * n, new_y * new_n, {:no, contracts, y, n})
      build_breakdown(amm_cost, %__MODULE__{yes: new_y, no: new_n})
    end
  end

  # Catch-all for non-positive / non-integer contracts and side
  # outside `[:yes, :no]`. Callers are expected to validate at the
  # request boundary; this clause is a fail-closed safety net so an
  # unvalidated path returns a tagged error rather than crashing the
  # caller with a FunctionClauseError.
  def quote_breakdown(%__MODULE__{}, _side, _contracts), do: {:error, :invalid_contracts}

  # Runtime enforcement of the K = YES × NO invariant. The math is
  # supposed to be K-non-decreasing across trades (integer rounding
  # grows K, never shrinks). A K-decreasing outcome indicates either
  # an fpmm_cost/isqrt_ceil regression, an integer-overflow-like
  # corruption, or crafted-input abuse — none safe to continue on.
  # Raise so the transaction rolls back at the caller (Trader
  # captures the raise and refuses the trade) and operators see the
  # exception in logs instead of a silent value leak.
  #
  # Pre-fix the invariant existed only as a unit-test bound; nothing
  # re-checked the pool state after a live trade.
  defp assert_invariant_non_decreasing!(k_before, k_after, ctx) do
    if k_after < k_before do
      raise ArgumentError,
            "AMM: K invariant regressed (before=#{k_before}, after=#{k_after}, " <>
              "ctx=#{inspect(ctx)}) — refusing trade to avoid value leak"
    end

    :ok
  end

  # --- Internal ---

  # Polymarket-style FPMM with collateral splitting.
  #
  # The user deposits `c` collateral; conditional-tokens semantics
  # split it 1:1 into `c` YES + `c` NO. The pool absorbs the entire
  # NO side (so the opposite-of-bought reserve grows by `c`), and the
  # pool's bought-side reserve adjusts to maintain `K = bought × other`,
  # ending at `(bought + c - dY, other + c)`. The user keeps `dY`
  # contracts. Solving the resulting quadratic for `c` given target
  # `dY`:
  #
  #     c² + c(bought + other - dY) - dY × other = 0
  #     c = (-(bought + other - dY) + √((bought + other - dY)² + 4·dY·other)) / 2
  #
  # `bought` is the reserve of the side the user is buying contracts
  # OF; `other` is the opposite-side reserve that the user's NO-half
  # accumulates into. Both `isqrt_ceil/1` and `ceil_div/2` round in
  # the operator's favour so any fractional remainder grows the pool
  # rather than shrinks it — `K` is non-decreasing across trades.
  defp fpmm_cost(bought, other, contracts) do
    b = bought + other - contracts
    discriminant = b * b + 4 * contracts * other
    sqrt_d = isqrt_ceil(discriminant)
    ceil_div(sqrt_d - b, 2)
  end

  defp build_breakdown(amm_cost, new_pool) do
    spread = ceil_div(amm_cost * @spread_ppm, @ppm)
    {:ok, %{cost: amm_cost + spread, amm_cost: amm_cost, spread: spread, pool: new_pool}}
  end

  defp ceil_div(num, den) when den > 0, do: div(num + den - 1, den)

  # Integer ceiling square root via Newton's method. Returns the
  # smallest positive integer `s` such that `s² ≥ n`. Used by
  # `fpmm_cost/3` so the discriminant's irrational root rounds up,
  # in the operator's favour. The discriminant is always positive
  # (sum of two positive products), so a zero clause is unreachable
  # and omitted.
  defp isqrt_ceil(n) when is_integer(n) and n > 0 do
    f = isqrt_floor(n)
    if f * f == n, do: f, else: f + 1
  end

  defp isqrt_floor(n) when is_integer(n) and n > 0 do
    isqrt_newton(n, n)
  end

  defp isqrt_newton(x, n) do
    next = div(div(n, x) + x, 2)
    if next >= x, do: x, else: isqrt_newton(next, n)
  end
end
