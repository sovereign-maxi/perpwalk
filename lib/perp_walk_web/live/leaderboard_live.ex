defmodule PerpWalkWeb.LeaderboardLive do
  @moduledoc """
  Standalone calibration leaderboard at `/leaderboard`.

  Was previously a side panel on the markets browse page (`/markets`
  with a 2/3 + 1/3 grid). Promoted to its own route so each surface
  gets full viewport — the squeezed 1/3 width on `/markets` made the
  rank table harder to read than necessary, and a dedicated route
  is bookmarkable, mobile-friendly, and removes the grid-CSS rigging.

  Table chrome is the shared `bp-data-table` used across `/markets`
  and `/portfolio`, with pagination via the shared `Paginator`
  component. Columns: rank, handle, resolved, wins, losses, %,
  last active. A periodic tick keeps the LAST ACTIVE relative-time
  labels fresh between event-driven refreshes.

  Subscribes to `MarketSettled` and `MarketVoided` events so the
  ranking updates live when a market resolves (or vanishes from the
  denominator).
  """

  use PerpWalkWeb, :live_view

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.Facade, as: MarketsFacade
  alias PerpWalkWeb.Live.Components.Paginator
  alias PerpWalkWeb.Live.Helpers
  alias PerpWalkWeb.Messages

  # Loose threshold for low-volume launch; raise once volume justifies
  # 10. Mirrors the value MarketsLive used when the panel still lived
  # there so the same accounts surface in both places before launch.
  @min_resolved 3

  # Effectively unlimited — the pagination slice below is what caps
  # the DOM. `compute/1`'s current implementation is O(markets ×
  # positions) whether we cap at 50 or 10_000; the sort has already
  # run either way.
  @compute_limit 10_000

  @per_page 25

  # Cadence for the periodic `:tick` that keeps the LAST ACTIVE
  # relative-time labels fresh between market events. Same 30s
  # rhythm as MarketsLive.
  @tick_interval_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      EventBus.subscribe(MarketsEvents.MarketSettled)
      EventBus.subscribe(MarketsEvents.MarketVoided)
      Helpers.subscribe_to_pip_events()
      schedule_tick()
    end

    {:ok,
     socket
     |> assign(:page_title, Messages.page_title_leaderboard())
     |> assign(:health, Helpers.fetch_footer_health())
     |> assign(:page, 1)
     |> assign(:per_page, @per_page)
     |> assign_now()
     |> load_leaderboard()}
  end

  @impl true
  def handle_event("paginate", %{"page" => page}, socket) do
    page = parse_page(page)

    new_page =
      Paginator.clamp_page(page, length(socket.assigns.all_rows), socket.assigns.per_page)

    {:noreply, socket |> assign(:page, new_page) |> assign_page_slice()}
  end

  # Catch-all so a forged client frame for an event this LiveView
  # doesn't recognise becomes a silent no-op rather than a process
  # crash that tears down the WebSocket.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(%MarketsEvents.MarketSettled{}, socket),
    do: {:noreply, refresh(socket)}

  def handle_info(%MarketsEvents.MarketVoided{}, socket),
    do: {:noreply, refresh(socket)}

  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, assign_now(socket)}
  end

  def handle_info(msg, socket) do
    case Helpers.handle_pip_event(msg, socket) do
      :pass -> {:noreply, socket}
      handled -> handled
    end
  end

  # --- Internal ---

  defp refresh(socket), do: socket |> assign_now() |> load_leaderboard()

  defp assign_now(socket), do: assign(socket, :now, DateTime.utc_now())

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval_ms)

  defp load_leaderboard(socket) do
    rows =
      MarketsFacade.compute_leaderboard(min_resolved: @min_resolved, limit: @compute_limit)

    new_page =
      Paginator.clamp_page(socket.assigns[:page] || 1, length(rows), socket.assigns.per_page)

    socket
    |> assign(:all_rows, rows)
    |> assign(:total_count, length(rows))
    |> assign(:page, new_page)
    |> assign_page_slice()
  end

  defp assign_page_slice(socket) do
    rows =
      Paginator.slice(socket.assigns.all_rows, socket.assigns.page, socket.assigns.per_page)

    assign(socket, :rows, rows)
  end

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  defp parse_page(value) when is_integer(value) and value >= 1, do: value
  defp parse_page(_), do: 1

  @impl true
  def render(assigns) do
    ~H"""
    <Helpers.app_header current_handle={@current_handle} current_page={:leaderboard} />

    <Helpers.app_sub_nav current_handle={@current_handle} current_page={:leaderboard} />

    <main class="bp-root">
      <h1 class="bp-sr-only">{Messages.panel_leaderboard()}</h1>
      <div class="bp-page-wide bp-page-fill">
        <.announcements items={Helpers.announcements()} />

        <.panel title={Messages.panel_leaderboard()}>
          <div class="bp-table-scroll">
            <Helpers.table_empty_state
              :if={@total_count == 0}
              message={Messages.empty_no_rankings()}
            />

            <table :if={@total_count > 0} class="bp-data-table">
              <thead>
                <tr>
                  <th scope="col" class="bp-cell-num">
                    {Messages.column_rank()}
                  </th>
                  <th scope="col" class="bp-cell-auto">
                    {Messages.column_handle()}
                  </th>
                  <th scope="col" class="bp-cell-num">
                    {Messages.column_resolved()}
                  </th>
                  <th scope="col" class="bp-cell-num">
                    {Messages.column_wins()}
                  </th>
                  <th scope="col" class="bp-cell-num">
                    {Messages.column_losses()}
                  </th>
                  <th scope="col" class="bp-cell-num">
                    {Messages.column_win_pct()}
                  </th>
                  <th scope="col" class="bp-cell-label">
                    {Messages.column_last_active()}
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @rows}>
                  <td class="bp-cell-num">{entry.rank}</td>
                  <td class="bp-cell-auto">@{entry.handle}</td>
                  <td class="bp-cell-num">{entry.markets_resolved}</td>
                  <td class="bp-cell-num">{entry.wins}</td>
                  <td class="bp-cell-num">{entry.markets_resolved - entry.wins}</td>
                  <td class="bp-cell-num">{entry.win_pct}%</td>
                  <td class="bp-cell-label">{Helpers.time_since(entry.last_active_at, @now)}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <Paginator.paginator
            page={@page}
            total={@total_count}
            per_page={@per_page}
            label={Messages.paginator_label_leaderboard()}
          />
        </.panel>
      </div>

      <Helpers.app_footer health={@health} />
    </main>
    """
  end
end
