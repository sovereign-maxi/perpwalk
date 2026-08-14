defmodule PerpWalk.Markets.History do
  @moduledoc """
  Historical time-series queries derived from the Markets WAL.

  Pure read-side functions — walk the WAL, filter to the relevant
  Markets entries for a given market id, and extract derived
  time-series like the YES probability over time.

  Reads the production WAL (`PerpWalk.Storage.WAL`) directly via
  `Locker.WAL.read_all/1` — the Markets domain owns its own WAL
  types and operates on them.
  """

  alias Locker.WAL.Entry
  alias PerpWalk.Markets.AMM

  @wal_server PerpWalk.Storage.WAL

  @typedoc "A point in the per-market time series — YES probability + pool depth."
  @type odds_point :: %{t: DateTime.t(), yes: float(), pool_total: non_neg_integer()}

  @doc """
  Returns the YES-probability time series for the given market,
  ordered ascending by time. Includes the initial AMM state (taken
  from the `:awaiting_deposit` `:market_put` write) plus every
  `:quote_filled` and `:trade_executed` snapshot of the moved pool,
  plus the final `:market_resolved` snapshot.

  Returns `{:ok, [odds_point()]}` on success or `{:error, reason}`
  if the WAL is unavailable. An empty list means the market has
  no recorded state in the WAL.
  """
  @spec odds_history(binary()) :: {:ok, [odds_point()]} | {:error, term()}
  def odds_history(market_id) when is_binary(market_id) do
    case safe_read_all() do
      {:ok, entries} ->
        points =
          entries
          |> Enum.flat_map(&extract_point(&1, market_id))
          |> Enum.sort_by(& &1.t, DateTime)

        {:ok, points}

      {:error, _} = err ->
        err
    end
  end

  # --- Internal ---

  defp safe_read_all do
    Locker.WAL.read_all(@wal_server)
  catch
    :exit, _ -> {:error, :wal_unavailable}
  end

  # `:market_put` fires on every status transition — created
  # → awaiting_deposit → pending → active → expired → resolving →
  # settled / voided / rejected. The chart's story is *trading*,
  # which only starts when the market transitions to `:active`. The
  # initial chart point is the `:active` write at `activated_at`,
  # carrying the AMM pool at that exact moment (still the initial
  # seed since no trades have landed yet).
  #
  # Pre-activated_at WAL entries fall back to the `:awaiting_deposit`
  # write at `created_at` so historical markets without the new
  # field still render a sensible initial point. That's strictly a
  # legacy-data accommodation — fresh activations always emit the
  # `:active` point.
  defp extract_point(%Entry{type: :market_put, payload: payload}, market_id)
       when is_map(payload) do
    case payload do
      %{id: ^market_id, status: :active, activated_at: t, pool: pool} when not is_nil(t) ->
        [%{t: parse_dt(t), yes: yes_probability(pool), pool_total: pool_total(pool)}]

      %{id: ^market_id, status: :awaiting_deposit, activated_at: nil, created_at: t, pool: pool} ->
        [%{t: parse_dt(t), yes: yes_probability(pool), pool_total: pool_total(pool)}]

      %{id: ^market_id, status: :awaiting_deposit, created_at: t, pool: pool}
      when not is_map_key(payload, :activated_at) ->
        # Legacy WAL entries written before `activated_at` was a field
        # on the persisted Market shape; carry the created_at anchor
        # so old markets keep their existing chart behaviour.
        [%{t: parse_dt(t), yes: yes_probability(pool), pool_total: pool_total(pool)}]

      _ ->
        []
    end
  end

  # Production trade path: user creates a Quote, deposits XMR, the
  # Monero poller observes the confirmation and calls
  # `Trader.fill_quote/2`, which writes `:quote_filled`. Same payload
  # shape as `:trade_executed` — market struct + position struct.
  defp extract_point(
         %Entry{
           type: :quote_filled,
           payload: %{market: %{id: id} = market, position: %{created_at: trade_t}}
         },
         market_id
       )
       when id == market_id do
    [
      %{
        t: parse_dt(trade_t),
        yes: yes_probability(market.pool),
        pool_total: pool_total(market.pool)
      }
    ]
  end

  # Instant-trade path used by `Trader.place_position/4`. Currently
  # test-only — production trades all go through the quote→fill
  # path above. Kept for test coverage and for the case where a
  # future caller wants to bypass the quote step.
  defp extract_point(
         %Entry{
           type: :trade_executed,
           payload: %{market: %{id: id} = market, position: %{created_at: trade_t}}
         },
         market_id
       )
       when id == market_id do
    [
      %{
        t: parse_dt(trade_t),
        yes: yes_probability(market.pool),
        pool_total: pool_total(market.pool)
      }
    ]
  end

  defp extract_point(
         %Entry{type: :market_resolved, payload: %{market: %{id: id, resolved_at: t} = market}},
         market_id
       )
       when id == market_id do
    [%{t: parse_dt(t), yes: yes_probability(market.pool), pool_total: pool_total(market.pool)}]
  end

  defp extract_point(_entry, _market_id), do: []

  defp yes_probability(%{yes: y, no: n}) when is_integer(y) and is_integer(n) and y + n > 0 do
    n / (y + n)
  end

  defp yes_probability(%AMM{yes: y, no: n}) when is_integer(y) and is_integer(n) and y + n > 0 do
    n / (y + n)
  end

  defp yes_probability(_), do: 0.5

  defp pool_total(%{yes: y, no: n}) when is_integer(y) and is_integer(n), do: y + n
  defp pool_total(%AMM{yes: y, no: n}), do: y + n
  defp pool_total(_), do: 0

  defp parse_dt(%DateTime{} = dt), do: dt

  defp parse_dt(iso) when is_binary(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    dt
  end

  defp parse_dt(_), do: DateTime.utc_now()
end
