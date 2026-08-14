defmodule PerpWalkWeb.Live.Components.MarketCard do
  @moduledoc """
  Read-only display of a single market — used as a row in the
  browse table and as the heading block in the detail view.

  Five columns: META (category + state badges side-by-side),
  MARKET (description), INFO, POOL, TIME. The category and state
  badges share one cell so they read as a single piece of metadata
  about the market — matching the tight badge pair on
  `/markets/:id`. INFO is status-aware:

  - `:active` — YES/NO mid-probabilities as decimals + a
    10-segment odds bar
  - `:pending` — vote tally and reputation
  - any other status — empty (the STATE pill carries the meaning)
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  import PerpWalkWeb.Live.Components.Badges

  alias PerpWalkWeb.Live.Helpers

  attr(:market, :map, required: true, doc: "the Market struct")
  attr(:vote_summary, :map, default: %{up: 0, down: 0}, doc: "for pending markets")
  attr(:positions, :list, default: [], doc: "positions for this market — drives the POOL cell")
  attr(:now, :any, required: true, doc: "current DateTime for relative-time rendering")

  def market_card(assigns) do
    assigns = assign(assigns, :navigate_to, "/markets/#{assigns.market.id}")

    ~H"""
    <tr
      class="bp-data-table-row-interactive"
      data-market-id={@market.id}
      tabindex="0"
      phx-click={JS.navigate(@navigate_to)}
      phx-keydown={JS.navigate(@navigate_to)}
      phx-key="Enter"
    >
      <td class="bp-cell-wide">
        <div class="pw-meta-pair">
          <.category_badge category={@market.category} />
          <.state_label market={@market} />
        </div>
      </td>

      <td class="bp-cell-auto" title={@market.description}>
        <span class="bp-row-desc">{@market.description}</span>
      </td>

      {render_info_cell(assigns)}

      <td class="bp-cell-amount pw-markets-pool">{pool_or_dash(@market, @positions)}</td>

      {render_time_cell(assigns)}
    </tr>
    """
  end

  # Renders the TIME cell. When a meaningful timestamp drives the
  # label, wraps it in `<time datetime="...">` so the machine-readable
  # ISO 8601 form sits alongside the relative human form. Falls back
  # to a plain `<td>—</td>` for statuses with no anchor datetime.
  defp render_time_cell(%{market: market, now: now} = assigns) do
    case time_pair(market, now) do
      {datetime, label} ->
        assigns =
          assigns
          |> assign(:datetime_iso, DateTime.to_iso8601(datetime))
          |> assign(:label, label)

        ~H"""
        <td class="bp-cell-label pw-markets-time">
          <time datetime={@datetime_iso}>{@label}</time>
        </td>
        """

      nil ->
        ~H"""
        <td class="bp-cell-label pw-markets-time">—</td>
        """
    end
  end

  # --- Status-Aware INFO Cell ---

  defp render_info_cell(%{market: %{status: :active}} = assigns) do
    {yes_segs, no_segs} = Helpers.odds_bar_segments(assigns.market.pool)

    assigns =
      assigns
      |> assign(:yes_segs, yes_segs)
      |> assign(:no_segs, no_segs)

    ~H"""
    <td class="bp-cell-wide">
      <span class="bp-bar">
        <span class={"bp-bar-yes bp-bar-w-#{@yes_segs * 10}"}></span>
        <span class={"bp-bar-no bp-bar-w-#{@no_segs * 10}"}></span>
      </span>
    </td>
    """
  end

  defp render_info_cell(%{market: %{status: :pending}} = assigns) do
    ~H"""
    <td class="bp-cell-wide">
      <div class="pw-vote-summary">
        <span class="pw-vote-up">▲ {@vote_summary.up}</span>
        <span class="pw-vote-down">▼ {@vote_summary.down}</span>
        <span class={"pw-rep #{rep_class(@market.reputation)}"}>
          {format_rep(@market.reputation)}
        </span>
      </div>
    </td>
    """
  end

  defp render_info_cell(assigns) do
    ~H"""
    <td class="bp-cell-wide bp-empty-cell">—</td>
    """
  end

  # --- POOL / TIME Helpers ---

  defp pool_or_dash(%{status: :awaiting_deposit}, _positions), do: "—"
  defp pool_or_dash(%{status: :pending}, _positions), do: "—"
  defp pool_or_dash(%{status: :rejected}, _positions), do: Helpers.format_pool_total([], 0)

  defp pool_or_dash(%{deposit_amount: deposit} = _market, positions),
    do: Helpers.format_pool_total(positions, deposit)

  # Returns the datetime anchor + human-readable label for the TIME
  # cell, or `nil` when no anchor exists for this status. The caller
  # uses the datetime to populate `<time datetime="...">` so the cell
  # carries both the machine-readable ISO 8601 and the relative form.
  defp time_pair(%{status: status, resolved_at: %DateTime{} = at}, now)
       when status in [:settled, :voided],
       do: {at, Helpers.time_since(at, now)}

  defp time_pair(%{status: :rejected, created_at: %DateTime{} = at}, now),
    do: {at, Helpers.time_since(at, now)}

  defp time_pair(%{status: :pending, created_at: %DateTime{} = at}, now),
    do: {at, Helpers.time_since(at, now)}

  defp time_pair(%{status: status, expiry: %DateTime{} = at}, now)
       when status in [:active, :expired, :resolving],
       do: {at, Helpers.time_until(at, now)}

  defp time_pair(_, _), do: nil

  defp rep_class(rep) when rep > 0, do: "bp-color-accent"
  defp rep_class(rep) when rep < 0, do: "bp-color-grey"
  defp rep_class(_), do: ""

  defp format_rep(rep) when rep > 0, do: "+#{rep}"
  defp format_rep(rep), do: "#{rep}"
end
