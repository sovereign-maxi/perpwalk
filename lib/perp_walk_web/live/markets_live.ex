defmodule PerpWalkWeb.MarketsLive do
  @moduledoc """
  Markets browse LiveView — lists every market in a single
  scrollable table with status- and category-filter pills and a
  sort dropdown. Subscribes to the Markets event bus and updates
  rows in real time as markets transition state or pools move.

  Filter and sort state lives in URL params so users can bookmark
  or share filtered views.
  """

  use PerpWalkWeb, :live_view

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.{Categories, Facade}
  alias PerpWalkWeb.Live.Components.{MarketCard, Paginator}
  alias PerpWalkWeb.Live.Helpers
  alias PerpWalkWeb.Messages

  # User-facing filter atoms, ordered for the dropdown. `:pending`
  # is a viewer-facing union bucket that collapses `:awaiting_deposit`
  # + `:pending` (see `filter_by_status/2`). `:expired` and
  # `:resolving` are exposed as their own filter options per the
  # canonical state outline at /docs/#states — the action prompt
  # for non-creators differs between the two (wait for creator vs
  # decide to dispute), so users benefit from being able to filter
  # to each state independently.
  @primary_status_filters ~w(all active pending expired resolving settled voided rejected)a
  @per_page 25

  # Cadence for the periodic `:tick` that keeps relative-time
  # labels (e.g. "5m ago", "2h 14m") fresh between market events.
  # 30s is fine-grained enough that sub-minute buckets ("now",
  # "30s") still feel live, while keeping per-page CPU trivial.
  @tick_interval_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      subscribe_to_markets_events()
      Helpers.subscribe_to_pip_events()
      schedule_tick()
    end

    {:ok,
     socket
     |> assign(:page_title, Messages.page_title_markets())
     |> assign(:status_filter, :all)
     |> assign(:category_filter, :all)
     |> assign(:page, 1)
     |> assign(:per_page, @per_page)
     |> assign(:health, Helpers.fetch_footer_health())
     |> assign_now()
     |> load_markets()}
  end

  @impl true
  def handle_event("filter_status", %{"status" => value}, socket) do
    status = parse_status(value)

    {:noreply,
     socket
     |> assign(:status_filter, status)
     |> assign(:page, 1)
     |> assign_filtered()}
  end

  def handle_event("filter_category", %{"category" => value}, socket) do
    category = parse_category(value)

    {:noreply,
     socket
     |> assign(:category_filter, category)
     |> assign(:page, 1)
     |> assign_filtered()}
  end

  def handle_event("paginate", %{"page" => page}, socket) do
    page = parse_page(page)

    new_page =
      Paginator.clamp_page(page, length(socket.assigns.filtered_rows), socket.assigns.per_page)

    {:noreply, socket |> assign(:page, new_page) |> assign_page_slice()}
  end

  # Catch-all so a forged client frame for an event this LiveView
  # doesn't recognise becomes a silent no-op rather than a process
  # crash that tears down the WebSocket.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(%MarketsEvents.MarketCreated{}, socket), do: {:noreply, refresh(socket)}
  def handle_info(%MarketsEvents.MarketDepositConfirmed{}, socket), do: {:noreply, refresh(socket)}
  def handle_info(%MarketsEvents.MarketActivated{}, socket), do: {:noreply, refresh(socket)}
  def handle_info(%MarketsEvents.MarketRejected{}, socket), do: {:noreply, refresh(socket)}
  def handle_info(%MarketsEvents.MarketExpired{}, socket), do: {:noreply, refresh(socket)}
  def handle_info(%MarketsEvents.MarketSettled{}, socket), do: {:noreply, refresh(socket)}
  def handle_info(%MarketsEvents.MarketVoided{}, socket), do: {:noreply, refresh(socket)}
  def handle_info(%MarketsEvents.PositionOpened{}, socket), do: {:noreply, refresh(socket)}
  def handle_info(%MarketsEvents.QuoteFilled{}, socket), do: {:noreply, refresh(socket)}
  def handle_info(%MarketsEvents.ResolutionSubmitted{}, socket), do: {:noreply, refresh(socket)}
  def handle_info(%MarketsEvents.ResolutionReversed{}, socket), do: {:noreply, refresh(socket)}

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

  # --- State Assembly ---

  defp subscribe_to_markets_events do
    for event <- [
          MarketsEvents.MarketCreated,
          MarketsEvents.MarketDepositConfirmed,
          MarketsEvents.MarketActivated,
          MarketsEvents.MarketRejected,
          MarketsEvents.MarketExpired,
          MarketsEvents.MarketSettled,
          MarketsEvents.MarketVoided,
          MarketsEvents.PositionOpened,
          MarketsEvents.QuoteFilled,
          MarketsEvents.ResolutionSubmitted,
          MarketsEvents.ResolutionReversed
        ] do
      EventBus.subscribe(event)
    end
  end

  defp load_markets(socket) do
    markets = Facade.list_markets()
    positions_by_market = positions_by_market()

    socket
    |> assign(:all_markets, markets)
    |> assign(:all_markets_count, length(markets))
    |> assign(:status_counts, status_counts(markets))
    |> assign(:positions_by_market, positions_by_market)
    |> assign_filtered()
  end

  defp positions_by_market do
    Facade.list_all_positions()
    |> Enum.group_by(& &1.market_id)
  end

  defp refresh(socket) do
    socket
    |> assign_now()
    |> load_markets()
  end

  defp assign_now(socket), do: assign(socket, :now, DateTime.utc_now())

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval_ms)

  defp assign_filtered(socket) do
    filtered =
      socket.assigns.all_markets
      |> filter_by_status(socket.assigns.status_filter)
      |> filter_by_category(socket.assigns.category_filter)
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})

    new_page =
      Paginator.clamp_page(socket.assigns.page, length(filtered), socket.assigns.per_page)

    socket
    |> assign(:filtered_rows, filtered)
    |> assign(:filtered_count, length(filtered))
    |> assign(:page, new_page)
    |> assign_page_slice()
  end

  defp assign_page_slice(socket) do
    positions_by_market = socket.assigns.positions_by_market

    page_rows =
      socket.assigns.filtered_rows
      |> Paginator.slice(socket.assigns.page, socket.assigns.per_page)
      |> Enum.map(&decorate(&1, positions_by_market))

    assign(socket, :rows, page_rows)
  end

  defp decorate(market, positions_by_market) do
    votes = Facade.list_votes_for_market(market.id)
    positions = Map.get(positions_by_market, market.id, [])

    %{
      market: market,
      vote_summary: vote_summary(votes),
      positions: positions
    }
  end

  defp vote_summary(votes) do
    Enum.reduce(votes, %{up: 0, down: 0}, fn
      %{direction: :up}, acc -> %{acc | up: acc.up + 1}
      %{direction: :down}, acc -> %{acc | down: acc.down + 1}
    end)
  end

  defp status_counts(markets) do
    base = %{all: length(markets)}

    Enum.reduce(markets, base, fn market, acc ->
      key = bucket_for_filter(market.status)
      Map.update(acc, key, 1, &(&1 + 1))
    end)
  end

  # Maps an internal status atom to the user-facing filter bucket
  # it lives in. Reads the semantic categorisation from
  # `Markets.Status` so the bucketing stays consistent with the
  # state machine — no inline atom unions. `:expired` and
  # `:resolving` are not bucketed; they fall through directly so
  # they show up in their own filter counts.
  defp bucket_for_filter(status) do
    if Facade.status_listing_window?(status), do: :pending, else: status
  end

  # --- Filters / Sort ---

  defp filter_by_status(markets, :all), do: markets

  # PENDING is a viewer-facing union bucket that collapses
  # `:awaiting_deposit` + `:pending` into a single public pill.
  # `:expired` and `:resolving` used to share a CLOSED bucket here
  # but are now exposed as distinct filter options per the canonical
  # state outline at /docs/#states. The semantic union memberships
  # live in `Markets.Status`, not here.
  defp filter_by_status(markets, :pending),
    do: Enum.filter(markets, &Facade.status_listing_window?(&1.status))

  defp filter_by_status(markets, status) when is_atom(status) do
    Enum.filter(markets, &(&1.status == status))
  end

  defp filter_by_category(markets, :all), do: markets

  defp filter_by_category(markets, category) when is_atom(category) do
    Enum.filter(markets, &(&1.category == category))
  end

  # --- Param Parsing (event values arrive as strings) ---

  defp parse_status(value) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in @primary_status_filters, do: atom, else: :all
  rescue
    ArgumentError -> :all
  end

  defp parse_status(_), do: :all

  defp parse_category("all"), do: :all

  defp parse_category(value) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if Categories.valid?(atom), do: atom, else: :all
  rescue
    ArgumentError -> :all
  end

  defp parse_category(_), do: :all

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  defp parse_page(value) when is_integer(value) and value >= 1, do: value
  defp parse_page(_), do: 1

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <Helpers.app_header current_handle={@current_handle} />

    <Helpers.app_sub_nav current_handle={@current_handle} current_page={:markets} />

    <main class="bp-root">
      <h1 class="bp-sr-only">{Messages.panel_markets()}</h1>
      <div class="bp-page-wide bp-page-fill">
        <.announcements items={Helpers.announcements()} />
        <.panel title={Messages.panel_markets()}>
          <div class="bp-filter-row">
            <nav aria-label={Messages.aria_filter_markets_by_category()}>
              <ul class="bp-filter-group" role="list">
                <li>
                  <button
                    type="button"
                    phx-click="filter_category"
                    phx-value-category="all"
                    phx-throttle="200"
                    class={"bp-pill #{if @category_filter == :all, do: "active"}"}
                  >
                    {Messages.filter_all()}
                  </button>
                </li>
                <li :for={category <- Categories.all()}>
                  <button
                    type="button"
                    phx-click="filter_category"
                    phx-value-category={category}
                    phx-throttle="200"
                    class={"bp-pill #{if @category_filter == category, do: "active"}"}
                  >
                    {Helpers.category_label(category)}
                  </button>
                </li>
              </ul>
            </nav>

            <div class="bp-filter-group bp-filter-group-right">
              <form id="markets-filter-form" phx-change="filter_status" phx-debounce="200">
                <label for="markets-status-filter" class="bp-sr-only">
                  {Messages.label_filter_markets_by_status()}
                </label>
                <select
                  id="markets-status-filter"
                  name="status"
                  class="bp-filter-select"
                >
                  <option
                    :for={status <- primary_filters()}
                    value={status}
                    selected={@status_filter == status}
                  >
                    {pill_label(status)}
                  </option>
                </select>
              </form>
            </div>
          </div>

          <div class="bp-table-scroll">
            <Helpers.table_empty_state :if={@filtered_count == 0} message={Messages.empty_no_markets()} />

            <table :if={@filtered_count > 0} class="bp-data-table">
              <thead>
                <tr>
                  <th scope="col" class="bp-cell-wide">{Messages.column_meta()}</th>
                  <th scope="col" class="bp-cell-auto">{Messages.column_market()}</th>
                  <th scope="col" class="bp-cell-wide"></th>
                  <th scope="col" class="bp-cell-amount">{Messages.column_pool()}</th>
                  <th scope="col" class="bp-cell-label">{Messages.column_time()}</th>
                </tr>
              </thead>
              <tbody>
                <MarketCard.market_card
                  :for={row <- @rows}
                  market={row.market}
                  vote_summary={row.vote_summary}
                  positions={row.positions}
                  now={@now}
                />
              </tbody>
            </table>
          </div>

          <Paginator.paginator
            page={@page}
            total={@filtered_count}
            per_page={@per_page}
            label={Messages.paginator_label_markets()}
          />
        </.panel>
      </div>

      <Helpers.app_footer health={@health} />
    </main>
    """
  end

  defp primary_filters, do: @primary_status_filters

  defp pill_label(status), do: Messages.status_filter_label(status)
end
