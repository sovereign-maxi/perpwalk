defmodule PerpWalkAdminWeb.Live.Components.Sparkline do
  @moduledoc """
  Pure SVG sparkline for the admin dashboard.

  Compact line chart with optional label + current value above it.
  Used for system metrics that arrive as a rolling window of recent
  samples. No JavaScript, no charting library.
  """

  use Phoenix.Component

  attr(:data, :list, required: true, doc: "list of numeric values, oldest first")
  attr(:width, :integer, default: 200)
  attr(:height, :integer, default: 50)
  attr(:color, :string, default: "var(--color-accent)")
  attr(:label, :string, default: nil)
  attr(:value, :string, default: nil)
  attr(:unit, :string, default: "%")
  attr(:max_value, :float, default: nil, doc: "fixed Y-axis max (e.g. 100.0 for percentages)")

  def sparkline(assigns) do
    points = build_points(assigns.data, assigns.width, assigns.height, assigns.max_value)

    assigns = assign(assigns, :points, points)

    ~H"""
    <div class="bp-sparkline">
      <div :if={@label} class="bp-sparkline-header">
        <span class="bp-sparkline-label">{@label}</span>
        <span :if={@value} class="bp-sparkline-value">{@value}{@unit}</span>
      </div>
      <svg
        viewBox={"0 0 #{@width} #{@height}"}
        class="bp-sparkline-svg"
        preserveAspectRatio="none"
        role="img"
        aria-label="Activity sparkline"
      >
        <polyline
          :if={@points != ""}
          fill="none"
          stroke={@color}
          stroke-width="1.5"
          stroke-linejoin="round"
          stroke-linecap="round"
          points={@points}
        />
      </svg>
    </div>
    """
  end

  defp build_points([], _w, _h, _max), do: ""
  defp build_points([_], _w, _h, _max), do: ""

  defp build_points(data, width, height, max_value) do
    values =
      Enum.map(data, fn
        {_ts, v} -> v
        v when is_number(v) -> v
        _ -> 0
      end)

    max_val = if max_value, do: max_value, else: max(Enum.max(values), 1)
    range = max(max_val, 0.1)
    count = length(values)
    step = width / max(count - 1, 1)
    padding = 2

    values
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {val, idx} ->
      x = Float.round(idx * step, 1)
      y = Float.round(padding + (height - 2 * padding) * (1 - val / range), 1)
      "#{x},#{y}"
    end)
  end
end
