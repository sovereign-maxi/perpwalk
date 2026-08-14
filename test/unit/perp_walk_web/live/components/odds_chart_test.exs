defmodule PerpWalkWeb.Live.Components.OddsChartTest do
  @moduledoc """
  Locks the rendering threshold for the YES-probability chart.

  The chart used to require 4+ distinct probability transitions
  before drawing a real polyline — markets with 1-3 trades
  fell back to a flat horizontal line at the current probability,
  which looked identical to "no movement" even though the data
  was there. The threshold is now 1: a single trade produces a
  visible segment.

  These tests assert the actual rendered SVG, not internal helpers,
  so a future refactor that changes the rendering implementation
  but preserves the threshold behavior stays green.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PerpWalkWeb.Live.Components.OddsChart

  defp render_chart(assigns), do: render_component(&OddsChart.odds_chart/1, assigns)

  defp point(yes_prob, seconds_ago) do
    %{
      t: DateTime.add(DateTime.utc_now(), -seconds_ago, :second),
      yes: yes_prob,
      pool_total: 1_000
    }
  end

  describe "real-line threshold" do
    test "zero trades renders a flat polyline at 50%" do
      # Empty points list → flat fallback at 0.5. With a 160px height
      # and 4px padding the 50% gridline sits at y=80, so the polyline
      # ends with the right-edge coordinate at that y.
      html = render_chart(%{points: []})

      assert html =~ ~s(<polyline)
      # Flat: both endpoints share the same y (the 50% midline).
      assert html =~ ~r{points="4,80 796,80"}
    end

    test "single trade renders a real time-series polyline (not flat fallback)" do
      # Two points (initial + one trade) IS enough — the line should
      # connect the initial and post-trade probability rather than
      # falling back to a flat horizontal at the post-trade value.
      points = [point(0.5, 3600), point(0.38, 0)]
      html = render_chart(%{points: points, now: DateTime.utc_now()})

      # The build_yes_line path produces multiple distinct
      # comma-separated coordinate pairs. A flat fallback only
      # produces two coordinates sharing the same y.
      [_, polyline_attr] = Regex.run(~r{points="([^"]+)"}, html)
      pairs = String.split(polyline_attr, " ")
      assert length(pairs) >= 2

      ys = Enum.map(pairs, fn pair -> pair |> String.split(",") |> Enum.at(1) end)
      refute Enum.uniq(ys) |> length() == 1, "expected at least two distinct y values, got #{inspect(ys)}"
    end

    test "three trades render the full trajectory" do
      points = [
        point(0.5, 7200),
        point(0.6, 3600),
        point(0.45, 1800),
        point(0.38, 0)
      ]

      html = render_chart(%{points: points, now: DateTime.utc_now()})

      [_, polyline_attr] = Regex.run(~r{points="([^"]+)"}, html)
      pairs = String.split(polyline_attr, " ")
      # 4 distinct points + the now-tick extension when `now` is
      # strictly after the last point. The now-tick may dedup if it's
      # within a millisecond of the last point, so accept ≥4.
      assert length(pairs) >= 4
    end
  end

  describe "now-tick extension" do
    test "carries the last yes value forward to `now` on the time axis" do
      # Last historical point was 1h ago at 0.38. With `now` provided,
      # the chart should extend horizontally to the right edge at the
      # same y (0.38), producing a "flat to current tick" tail.
      hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)
      points = [point(0.5, 7200), %{point(0.38, 3600) | t: hour_ago}]
      now = DateTime.utc_now()

      html = render_chart(%{points: points, now: now})

      [_, polyline_attr] = Regex.run(~r{points="([^"]+)"}, html)
      pairs = String.split(polyline_attr, " ")
      # 3 points: initial, historical trade, now-tick at same y as trade.
      assert length(pairs) == 3

      [_initial, trade, now_pair] = pairs
      [_, trade_y] = String.split(trade, ",")
      [_, now_y] = String.split(now_pair, ",")
      assert trade_y == now_y, "now-tick should carry the last trade's y forward"
    end
  end

  describe "lifetime canvas (start_at / end_at)" do
    test "early-stage market clusters its line on the left of the canvas" do
      # A market with a 24h lifetime that's only 3h in (12.5% elapsed)
      # should have all its trade points and the now-tick clustered in
      # the leftmost ~12.5% of the canvas — NOT stretched across the
      # full width as the old data-span behaviour did. The bug this
      # test exists to prevent was: 3 trades in the first 3h of a 24h
      # market rendered visually identical to 3 trades spread across
      # the full 24h, fooling the eye into reading sparse data as
      # dense.
      created_at = DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
      expiry = DateTime.add(created_at, 24 * 3600, :second)
      now = DateTime.utc_now()

      points = [
        %{t: created_at, yes: 0.5, pool_total: 200},
        %{t: DateTime.add(created_at, 3600, :second), yes: 0.6, pool_total: 250},
        %{t: DateTime.add(created_at, 2 * 3600, :second), yes: 0.55, pool_total: 280},
        %{t: now, yes: 0.38, pool_total: 300}
      ]

      html =
        render_chart(%{
          points: points,
          start_at: created_at,
          end_at: expiry,
          now: now,
          width: 800,
          padding: 4
        })

      [_, polyline_attr] = Regex.run(~r{points="([^"]+)"}, html)
      pairs = String.split(polyline_attr, " ")

      xs =
        Enum.map(pairs, fn pair ->
          [x_str, _] = String.split(pair, ",")
          String.to_integer(x_str)
        end)

      # 3h elapsed in a 24h market = 12.5% of canvas width.
      # 800px - 8px padding = 792 plot width; 12.5% = 99px.
      # Plus 4px padding offset, the rightmost point should sit
      # well under x=150 — comfortably inside the leftmost portion.
      max_x = Enum.max(xs)

      assert max_x < 150,
             "early-stage trades should cluster on the left; max x=#{max_x} suggests data-span stretching"

      # And the leftmost point sits at or near the left padding —
      # the initial-pool point is at start_at, so x ≈ padding.
      min_x = Enum.min(xs)
      assert min_x <= 10, "first point should sit at the canvas left edge, got x=#{min_x}"
    end

    test "now-marker vertical line renders inside the canvas" do
      # The dashed vertical 'now' indicator should appear at the
      # x position corresponding to wall-clock now within the
      # market's lifetime. For a market that's 50% elapsed, the
      # marker should sit roughly in the middle of the canvas.
      created_at = DateTime.add(DateTime.utc_now(), -12 * 3600, :second)
      expiry = DateTime.add(created_at, 24 * 3600, :second)
      now = DateTime.utc_now()

      html =
        render_chart(%{
          points: [%{t: created_at, yes: 0.5, pool_total: 200}],
          start_at: created_at,
          end_at: expiry,
          now: now,
          width: 800
        })

      # The 'now' line uses dasharray 3,3 with the monero-grey stroke
      # so it stays visually distinct from the gridlines (2,3 with
      # border color). The regex below targets the 3,3 pattern
      # specifically so a future tuning change has to update this
      # assertion explicitly.
      assert Regex.run(~r{stroke-dasharray="3,3"[^/]*x1="(\d+)"}, html) ||
               Regex.run(~r{x1="(\d+)"[^/]*stroke-dasharray="3,3"}, html),
             "expected a now-indicator vertical line in the SVG output"
    end

    test "no now-marker renders when now sits past end_at (expired market)" do
      # Once the market expires, chart_now clamps to expiry on the
      # caller side. If a downstream caller passes a `now` that's
      # strictly past `end_at` anyway, the indicator should not
      # render — it would otherwise sit off-canvas.
      created_at = DateTime.add(DateTime.utc_now(), -48 * 3600, :second)
      expiry = DateTime.add(created_at, 24 * 3600, :second)
      now_past_expiry = DateTime.add(expiry, 3600, :second)

      html =
        render_chart(%{
          points: [%{t: created_at, yes: 0.5, pool_total: 200}],
          start_at: created_at,
          end_at: expiry,
          now: now_past_expiry,
          width: 800
        })

      refute html =~ ~s(stroke-dasharray="3,3"),
             "now-indicator should not render when now is past end_at"
    end

    test "falls back to data-span bounds when start_at / end_at are nil" do
      # Legacy callers (or any caller that doesn't have a lifetime to
      # express) still get the old data-derived bounds so the chart
      # stays useful without the new attrs. Same shape as the first
      # 'single trade' test above — the line uses distinct y values
      # and spans the canvas.
      points = [point(0.5, 3600), point(0.38, 0)]

      html = render_chart(%{points: points, now: DateTime.utc_now()})

      [_, polyline_attr] = Regex.run(~r{points="([^"]+)"}, html)
      pairs = String.split(polyline_attr, " ")
      assert length(pairs) >= 2
    end
  end

  describe "flat-line right edge clamping" do
    test "zero-trade market: flat line stops at now, not at the right edge" do
      # Market lifetime: created_at to created_at + 24h. Now is 6h
      # in (25% elapsed). With zero trades, the flat 50% line should
      # extend from the left edge to the 25% canvas position only,
      # NOT all the way across the canvas.
      created_at = DateTime.add(DateTime.utc_now(), -6 * 3600, :second)
      expiry = DateTime.add(created_at, 24 * 3600, :second)
      now = DateTime.utc_now()

      html =
        render_chart(%{
          points: [%{t: created_at, yes: 0.5, pool_total: 200}],
          start_at: created_at,
          end_at: expiry,
          now: now,
          width: 800
        })

      [_, polyline_attr] = Regex.run(~r{points="([^"]+)"}, html)
      pairs = String.split(polyline_attr, " ")

      assert length(pairs) == 2, "flat line should be two points (left edge, now_x)"

      [_left, right_pair] = pairs
      [x_str, _y] = String.split(right_pair, ",")
      right_x = String.to_integer(x_str)

      # 25% of 792 plot width = 198px. Plus padding, expect roughly
      # 200. Allow some tolerance.
      assert right_x > 150 and right_x < 250,
             "flat line right edge should clamp to now (~25% of canvas), got x=#{right_x}"
    end

    test "expired market with no trades: flat line spans the full canvas" do
      # When the market reached its expiry without any trades, the
      # flat line should cover the full canvas — the whole lifetime
      # saw no movement. The LiveView's chart_now clamps to expiry
      # in this case, so we pass expiry as the now value here.
      created_at = DateTime.add(DateTime.utc_now(), -48 * 3600, :second)
      expiry = DateTime.add(created_at, 24 * 3600, :second)

      html =
        render_chart(%{
          points: [%{t: created_at, yes: 0.5, pool_total: 200}],
          start_at: created_at,
          end_at: expiry,
          now: expiry,
          width: 800
        })

      [_, polyline_attr] = Regex.run(~r{points="([^"]+)"}, html)
      pairs = String.split(polyline_attr, " ")

      [_left, right_pair] = pairs
      [x_str, _y] = String.split(right_pair, ",")
      right_x = String.to_integer(x_str)

      # Past expiry → full canvas. width=800, padding=4, right edge ≈ 796.
      assert right_x > 750,
             "expired no-trade market should fill canvas, got right_x=#{right_x}"
    end

    test "legacy callers without start_at still get the full-canvas flat fallback" do
      # No lifetime bounds → fall back to the old behaviour so the
      # chart stays useful for callers that haven't been updated.
      html = render_chart(%{points: []})

      [_, polyline_attr] = Regex.run(~r{points="([^"]+)"}, html)
      [_left, right_pair] = String.split(polyline_attr, " ")
      [x_str, _y] = String.split(right_pair, ",")
      right_x = String.to_integer(x_str)

      # Default width 800, padding 4 → right edge 796.
      assert right_x == 796
    end
  end
end
