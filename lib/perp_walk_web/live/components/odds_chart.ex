defmodule PerpWalkWeb.Live.Components.OddsChart do
  @moduledoc """
  Time-series chart of a market's YES probability.

  Renders an SVG line chart as soon as the market has any
  probability movement at all — initial 50% plus a single trade is
  enough to draw the first segment. With zero trades the chart
  falls back to a flat horizontal line at 50% so the panel keeps
  its full height and the gridlines have a reference line to read
  against.

  Pure function component. No JavaScript, no charting library.
  Re-renders whenever the parent passes a new `points` list.
  """

  use Phoenix.Component

  # Minimum distinct probability transitions needed to draw a real
  # time-series line. With 1, a single trade (initial + 1 distinct
  # post-trade value = 2 points = 1 transition) is enough to draw a
  # segment; combined with `extend_to_now/2` the line carries flat to
  # the current tick so even a single trade produces visible
  # trajectory rather than a flat fallback. Earlier versions used 4
  # ("3 trades looks sparse") but the cost — chart looking unmoved
  # for the first few trades — was worse than sparseness.
  @chart_min_trades 1

  attr(:points, :list,
    required: true,
    doc: "list of %{t: DateTime.t(), yes: float(), pool_total: integer()}"
  )

  attr(:start_at, :any,
    default: nil,
    doc:
      "Market's earliest moment for the time canvas (typically " <>
        "`market.created_at`). The leftmost x position maps to this " <>
        "timestamp. When nil, falls back to the first point's time " <>
        "so old callers without the attribute keep the legacy " <>
        "data-span behaviour."
  )

  attr(:end_at, :any,
    default: nil,
    doc:
      "Market's latest moment for the time canvas (typically " <>
        "`market.expiry`). The rightmost x position maps to this " <>
        "timestamp. Combined with `start_at` this fixes the canvas " <>
        "to the market's full lifetime — trades early in a long " <>
        "market cluster on the left, with the remainder of the " <>
        "canvas representing time not yet elapsed. When nil, falls " <>
        "back to the last point's time."
  )

  attr(:now, :any,
    default: nil,
    doc:
      "Optional current DateTime — when provided, the right edge " <>
        "of the line is extended to `now` (carrying the last point's " <>
        "yes value) so the chart shows a flat extension to the " <>
        "current tick. The vertical 'now' indicator also renders at " <>
        "this position when it sits inside the canvas."
  )

  attr(:width, :integer, default: 800)
  attr(:height, :integer, default: 160)
  attr(:padding, :integer, default: 4)

  def odds_chart(assigns) do
    enough_trades? = compute_trade_count(assigns.points) >= @chart_min_trades
    {t0_ms, t1_ms} = canvas_bounds(assigns)

    yes_line =
      if enough_trades? and t1_ms > t0_ms do
        build_yes_line(
          extend_to_now(assigns.points, assigns.now),
          t0_ms,
          t1_ms,
          assigns.width,
          assigns.height,
          assigns.padding
        )
      else
        # Thin or empty history — draw a flat line at the current
        # AMM-derived YES probability so the chart panel keeps its
        # full height and the gridlines have a reference line to
        # read against. With lifetime canvas bounds (start_at /
        # end_at) supplied, the line clamps at `now_x` rather than
        # spanning the full canvas — the empty space to the right of
        # the now indicator represents time the market hasn't reached
        # yet, the same semantic the real-line path uses. Markets
        # that have already expired without trades render their flat
        # line across the full canvas.
        right_x =
          flat_right_edge_x(t0_ms, t1_ms, assigns.now, assigns.width, assigns.padding)

        build_flat_line(assigns.points, right_x, assigns.height, assigns.padding)
      end

    now_x = now_marker_x(assigns.now, t0_ms, t1_ms, assigns.width, assigns.padding)
    gridlines = gridline_ys(assigns.height, assigns.padding)

    assigns =
      assigns
      |> assign(:yes_line, yes_line)
      |> assign(:gridlines, gridlines)
      |> assign(:now_x, now_x)

    ~H"""
    <div class="pw-odds-chart">
      <div class="pw-odds-chart-frame">
        <svg
          viewBox={"0 0 #{@width} #{@height}"}
          class="pw-odds-chart-svg"
          preserveAspectRatio="none"
          role="img"
          aria-label="YES probability over time"
        >
          <line
            :for={y <- @gridlines}
            x1={@padding}
            x2={@width - @padding}
            y1={y}
            y2={y}
            stroke="var(--color-border)"
            stroke-width="1"
            stroke-dasharray="2,3"
            vector-effect="non-scaling-stroke"
          />
          <polyline
            fill="none"
            stroke="var(--color-accent)"
            stroke-width="1"
            stroke-linejoin="round"
            stroke-linecap="round"
            points={@yes_line}
          />
          <line
            :if={@now_x != nil}
            x1={@now_x}
            x2={@now_x}
            y1={@padding}
            y2={@height - @padding}
            stroke="var(--color-monero-grey)"
            stroke-width="1"
            stroke-dasharray="3,3"
            stroke-opacity="0.8"
            vector-effect="non-scaling-stroke"
          />
        </svg>
      </div>
    </div>
    """
  end

  # Canvas time bounds. When `start_at` / `end_at` are supplied, they
  # define the full market lifetime — the same line of trades looks
  # different on a 24h market vs a 7d market because the canvas width
  # represents elapsed-vs-remaining time, not data span. Falls back to
  # data-derived bounds for legacy callers that don't pass the attrs.
  defp canvas_bounds(%{start_at: %DateTime{} = s, end_at: %DateTime{} = e}) do
    {DateTime.to_unix(s, :millisecond), DateTime.to_unix(e, :millisecond)}
  end

  defp canvas_bounds(%{points: []}), do: {0, 0}

  defp canvas_bounds(%{points: points}) do
    first = hd(points)
    last = List.last(points)
    {DateTime.to_unix(first.t, :millisecond), DateTime.to_unix(last.t, :millisecond)}
  end

  # X coordinate for the vertical "now" indicator. Nil when `now`
  # is outside the canvas (expired markets where now > end_at, or
  # historical replays where now < start_at), so the indicator
  # disappears once the market's lifetime closes.
  defp now_marker_x(nil, _t0, _t1, _w, _p), do: nil

  defp now_marker_x(%DateTime{} = now, t0, t1, width, padding) when t1 > t0 do
    now_ms = DateTime.to_unix(now, :millisecond)

    if now_ms >= t0 and now_ms <= t1 do
      plot_width = width - 2 * padding
      round(padding + (now_ms - t0) / (t1 - t0) * plot_width)
    end
  end

  defp now_marker_x(_, _, _, _, _), do: nil

  # --- Tiered Rendering Helpers ---

  # Distinct YES-probability values minus one (the initial state).
  # Each trade moves the AMM pool, which produces a new yes value;
  # status-transition `:market_put` entries reuse the pool unchanged,
  # so they share a yes value with whichever trade preceded them and
  # don't inflate the count. A market with only its initial state
  # has 1 unique yes → 0 trades.
  defp compute_trade_count([]), do: 0

  defp compute_trade_count(points) do
    distinct = points |> Enum.dedup_by(& &1.yes) |> length()
    max(distinct - 1, 0)
  end

  # Reference gridlines at the natural probability anchors —
  # 25%, 50%, 75% YES. Returned as y-coordinates inside the SVG
  # viewBox so the line elements can be rendered without needing
  # to redo the y-mapping in the template. Math matches
  # `build_yes_line/4`'s `yes_y` computation.
  defp gridline_ys(height, padding) do
    plot_height = height - 2 * padding

    for yes <- [0.25, 0.5, 0.75] do
      padding + (1.0 - yes) * plot_height
    end
  end

  # --- Coord Building ---

  defp build_yes_line([], _t0, _t1, _w, _h, _p), do: nil
  defp build_yes_line([_], _t0, _t1, _w, _h, _p), do: nil

  defp build_yes_line(points, t0_ms, t1_ms, width, height, padding) do
    span = t1_ms - t0_ms

    if span <= 0 do
      nil
    else
      plot_width = width - 2 * padding
      plot_height = height - 2 * padding

      Enum.map_join(points, " ", fn %{t: t, yes: y} ->
        ts = DateTime.to_unix(t, :millisecond)
        x = padding + (ts - t0_ms) / span * plot_width
        yes_y = padding + (1.0 - clamp(y)) * plot_height
        "#{round(x)},#{round(yes_y)}"
      end)
    end
  end

  defp clamp(y) when y < 0, do: 0.0
  defp clamp(y) when y > 1, do: 1.0
  defp clamp(y), do: y * 1.0

  # Flat horizontal line at the current YES probability. Used when
  # there isn't enough history to produce a time-series shape —
  # keeps the chart panel at full height while still showing
  # meaningful information (50/50 for a fresh market; whatever the
  # AMM has moved to after a thin sequence of points). Reads as
  # "market has not moved off this level."
  #
  # `right_x` is precomputed by `flat_right_edge_x/5` at the call
  # site so the lifetime-canvas clamp lives in one place and this
  # function stays focused on positioning the constant-y polyline.
  defp build_flat_line(points, right_x, height, padding) do
    yes = current_yes(points)
    plot_height = height - 2 * padding
    y = padding + (1.0 - clamp(yes)) * plot_height
    "#{padding},#{round(y)} #{right_x},#{round(y)}"
  end

  defp flat_right_edge_x(t0_ms, t1_ms, %DateTime{} = now, width, padding)
       when is_integer(t0_ms) and is_integer(t1_ms) and t1_ms > t0_ms do
    now_ms = DateTime.to_unix(now, :millisecond)

    cond do
      now_ms <= t0_ms ->
        padding

      now_ms >= t1_ms ->
        width - padding

      true ->
        plot_width = width - 2 * padding
        round(padding + (now_ms - t0_ms) / (t1_ms - t0_ms) * plot_width)
    end
  end

  defp flat_right_edge_x(_t0, _t1, _now, width, padding), do: width - padding

  defp current_yes([]), do: 0.5
  defp current_yes(points), do: List.last(points).yes

  # Appends a "now" tick to the right edge so traded markets show a
  # flat extension to the current tick (visually "no recent activity").
  # Only fires when `now` is strictly after the last historical point.
  defp extend_to_now([], _now), do: []
  defp extend_to_now(points, nil), do: points

  defp extend_to_now(points, %DateTime{} = now) do
    last = List.last(points)

    if DateTime.compare(now, last.t) == :gt do
      points ++ [%{last | t: now}]
    else
      points
    end
  end
end
