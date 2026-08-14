defmodule PerpWalkAdminWeb.Live.Events do
  @moduledoc """
  Events page — alerts + event stream, two-column.

  Each panel carries its own filter row inside the panel chrome:

    * Domain pills — `ALL · Markets · Federation · Reserves · Telemetry · Identity`
    * Severity dropdown — `ALL · Info · Warning · Critical · Emergency`

  Filter state is independent per panel — operator can focus the
  Active Alerts column on Critical while watching ALL severities
  in Event Stream, which is the common incident-investigation
  posture. Both panels share the same chrome (sub-nav with the
  page-switcher dropdown / pip footer) with the other admin pages.

  The operator typically leaves this page open during a session
  so the event stream is always visible. `clear_events` empties
  the local stream without affecting any other consumer.
  """

  use PerpWalkAdminWeb, :live_view

  alias PerpWalk.Events.Display
  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Events.Reserves, as: ReservesEvents
  alias PerpWalk.Events.Telemetry, as: TelemetryEvents
  alias PerpWalk.Telemetry.Facade, as: TelemetryFacade
  alias PerpWalkAdminWeb.Live.Helpers
  alias PerpWalkAdminWeb.Messages

  @event_stream_cap 50
  @tick_interval_ms 5_000

  @event_subscriptions [
    MarketsEvents.MarketCreated,
    MarketsEvents.MarketActivated,
    MarketsEvents.MarketRejected,
    MarketsEvents.MarketExpired,
    MarketsEvents.MarketSettled,
    MarketsEvents.MarketVoided,
    MarketsEvents.PositionOpened,
    MarketsEvents.PositionCancelled,
    MarketsEvents.ResolutionSubmitted,
    MarketsEvents.ResolutionReversed,
    MarketsEvents.DepositBurned,
    MarketsEvents.DisputeResolved,
    FederationEvents.PayoutRequested,
    FederationEvents.PayoutSubmitted,
    FederationEvents.PayoutFailed,
    FederationEvents.PeerLost,
    FederationEvents.PeerJoined,
    FederationEvents.QuorumLost,
    FederationEvents.QuorumRestored,
    ReservesEvents.ProofGenerated,
    ReservesEvents.ReserveDeficit,
    ReservesEvents.ReserveCriticalDeficit,
    ReservesEvents.ReserveRecovered,
    TelemetryEvents.SystemStatusChanged,
    TelemetryEvents.AlertFired,
    TelemetryEvents.AlertResolved,
    TelemetryEvents.TorDown,
    TelemetryEvents.TorDegraded,
    TelemetryEvents.TorRecovered
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Enum.each(@event_subscriptions, &EventBus.subscribe/1)
      Process.send_after(self(), :tick, @tick_interval_ms)
    end

    {:ok,
     socket
     |> assign(:page_title, Messages.page_title_admin())
     |> assign(:node_label, Helpers.node_label())
     |> assign(:event_stream, [])
     |> assign(:alerts_domain, "ALL")
     |> assign(:alerts_severity, "ALL")
     |> assign(:stream_domain, "ALL")
     |> assign(:stream_severity, "ALL")
     |> assign(:active_alerts, TelemetryFacade.active_alerts())
     |> refresh_chrome()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_interval_ms)

    {:noreply,
     socket
     |> assign(:active_alerts, TelemetryFacade.active_alerts())
     |> refresh_chrome()}
  end

  def handle_info(event, socket) when is_struct(event) do
    entry = format_event(event)

    stream =
      [entry | socket.assigns.event_stream]
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.sort_key, :desc)
      |> Enum.take(@event_stream_cap)

    {:noreply,
     socket
     |> assign(:event_stream, stream)
     |> assign(:active_alerts, TelemetryFacade.active_alerts())
     |> refresh_chrome()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Re-computes the sub-nav ambient stats + footer pip strip and
  # stores them as socket assigns so LiveView's change tracking
  # picks up transitions (e.g. `SystemStatusChanged`). Reading from
  # helpers inline in the template doesn't; only assigns are tracked.
  defp refresh_chrome(socket) do
    socket
    |> assign(:sub_nav_stats, Helpers.sub_nav_stats())
    |> assign(:footer_pips, Helpers.footer_pips())
  end

  @impl true
  def handle_event("clear_events", _params, socket) do
    {:noreply, assign(socket, :event_stream, [])}
  end

  def handle_event("filter_alerts_domain", %{"domain" => value}, socket) do
    {:noreply, assign(socket, :alerts_domain, normalise(value, Messages.domain_options()))}
  end

  def handle_event("filter_alerts_severity", %{"severity" => value}, socket) do
    {:noreply, assign(socket, :alerts_severity, normalise(value, Messages.severity_options()))}
  end

  def handle_event("filter_stream_domain", %{"domain" => value}, socket) do
    {:noreply, assign(socket, :stream_domain, normalise(value, Messages.domain_options()))}
  end

  def handle_event("filter_stream_severity", %{"severity" => value}, socket) do
    {:noreply, assign(socket, :stream_severity, normalise(value, Messages.severity_options()))}
  end

  defp normalise(value, options) when is_binary(value) do
    if value in options, do: value, else: "ALL"
  end

  defp normalise(_, _), do: "ALL"

  # --- Filtering ---

  defp filter_alerts(alerts, domain_filter, severity_filter) do
    Enum.filter(alerts, fn alert ->
      alert_domain_match?(alert, domain_filter) and
        alert_severity_match?(alert, severity_filter)
    end)
  end

  defp alert_domain_match?(_, "ALL"), do: true

  defp alert_domain_match?(%{domain: domain}, filter) when is_binary(domain) do
    String.downcase(domain) == String.downcase(filter)
  end

  defp alert_domain_match?(_, _), do: false

  defp alert_severity_match?(_, "ALL"), do: true

  defp alert_severity_match?(%{severity: severity}, filter) when is_atom(severity) do
    Atom.to_string(severity) == String.downcase(filter)
  end

  defp alert_severity_match?(_, _), do: false

  defp filter_stream(events, domain_filter, severity_filter) do
    Enum.filter(events, fn entry ->
      stream_domain_match?(entry, domain_filter) and
        stream_severity_match?(entry, severity_filter)
    end)
  end

  defp stream_domain_match?(_, "ALL"), do: true

  defp stream_domain_match?(%{domain: domain}, filter) do
    String.downcase(to_string(domain)) == String.downcase(filter)
  end

  defp stream_severity_match?(_, "ALL"), do: true

  defp stream_severity_match?(%{severity: severity}, filter) do
    # Event-stream severities are stored as the css-class form
    # (`ok | warning | critical`) — `:info` events render with `ok`.
    # Map the filter back into that vocabulary before comparing.
    severity == severity_css_class_for_filter(filter)
  end

  defp severity_css_class_for_filter("Info"), do: "ok"
  defp severity_css_class_for_filter("Warning"), do: "warning"
  defp severity_css_class_for_filter("Critical"), do: "critical"
  defp severity_css_class_for_filter("Emergency"), do: "critical"
  defp severity_css_class_for_filter(_), do: nil

  # --- Event Formatting ---

  defp format_event(event) do
    ts = Map.get(event, :timestamp) || DateTime.utc_now()

    %{
      id: System.unique_integer([:positive, :monotonic]),
      sort_key: DateTime.to_unix(ts, :microsecond),
      time: Calendar.strftime(ts, "%H:%M:%S"),
      domain: Display.domain(event),
      severity: severity_class(Display.severity(event)),
      label: Display.label(event),
      detail: Display.detail(event)
    }
  rescue
    Protocol.UndefinedError -> nil
  end

  defp severity_class(:info), do: "ok"
  defp severity_class(:warning), do: "warning"
  defp severity_class(:critical), do: "critical"
  defp severity_class(:emergency), do: "critical"

  defp humanise(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp humanise(name), do: to_string(name)

  defp format_alert_time(%DateTime{} = ts), do: Calendar.strftime(ts, "%H:%M:%S")
  defp format_alert_time(_), do: Messages.dash()

  # --- Render ---

  @impl true
  def render(assigns) do
    filtered_alerts = filter_alerts(assigns.active_alerts, assigns.alerts_domain, assigns.alerts_severity)
    filtered_stream = filter_stream(assigns.event_stream, assigns.stream_domain, assigns.stream_severity)

    assigns =
      assigns
      |> assign(:filtered_alerts, filtered_alerts)
      |> assign(:filtered_stream, filtered_stream)
      |> assign(:domain_options, Messages.domain_options())
      |> assign(:severity_options, Messages.severity_options())

    ~H"""
    <Helpers.admin_header node_label={@node_label} />
    <Helpers.admin_sub_nav current_page={:events} stats={@sub_nav_stats} />

    <main class="bp-root">
      <div class="bp-page-wide bp-admin-page">
        <.grid cols="2">
          <.panel title={Messages.panel_active_alerts()}>
            <div class="bp-filter-row">
              <nav aria-label={Messages.aria_filter_alerts_domain()}>
                <ul class="bp-filter-group" role="list">
                  <li :for={option <- @domain_options}>
                    <button
                      type="button"
                      phx-click="filter_alerts_domain"
                      phx-value-domain={option}
                      phx-throttle="200"
                      class={"bp-pill #{if @alerts_domain == option, do: "active"}"}
                    >
                      {String.upcase(option)}
                    </button>
                  </li>
                </ul>
              </nav>

              <div class="bp-filter-group bp-filter-group-right">
                <form id="alerts-severity-filter-form" phx-change="filter_alerts_severity" phx-debounce="200">
                  <label for="alerts-severity-filter" class="bp-sr-only">
                    {Messages.aria_filter_alerts_severity()}
                  </label>
                  <select id="alerts-severity-filter" name="severity" class="bp-filter-select">
                    <option :for={option <- @severity_options} value={option} selected={@alerts_severity == option}>
                      {String.upcase(option)}
                    </option>
                  </select>
                </form>
              </div>
            </div>

            <.panel_scroll>
              <ol class="bp-event-feed" role="log" aria-label={Messages.aria_active_alerts_log()}>
                <li :if={@filtered_alerts == []} class="bp-empty-state">
                  {Messages.empty_no_alerts()}
                </li>
                <li :for={alert <- @filtered_alerts} class="bp-event-row" id={"alert-#{alert.name}"}>
                  <span class={"bp-event-icon #{severity_class(alert.severity)}"} aria-hidden="true">
                    {String.upcase(to_string(alert.severity))}
                  </span>
                  <span class="bp-event-detail">
                    {humanise(alert.name)}
                    <span :if={alert.reason} class="bp-color-dim">({alert.reason})</span>
                  </span>
                  <span class="bp-event-time">{format_alert_time(alert.fired_at)}</span>
                </li>
              </ol>
            </.panel_scroll>
          </.panel>

          <.panel title={Messages.panel_event_stream()}>
            <:header_action>
              <a href="#" phx-click="clear_events" class="bp-panel-meta pw-panel-action">{Messages.action_clear()}</a>
            </:header_action>
            <div class="bp-filter-row">
              <nav aria-label={Messages.aria_filter_stream_domain()}>
                <ul class="bp-filter-group" role="list">
                  <li :for={option <- @domain_options}>
                    <button
                      type="button"
                      phx-click="filter_stream_domain"
                      phx-value-domain={option}
                      phx-throttle="200"
                      class={"bp-pill #{if @stream_domain == option, do: "active"}"}
                    >
                      {String.upcase(option)}
                    </button>
                  </li>
                </ul>
              </nav>

              <div class="bp-filter-group bp-filter-group-right">
                <form id="stream-severity-filter-form" phx-change="filter_stream_severity" phx-debounce="200">
                  <label for="stream-severity-filter" class="bp-sr-only">
                    {Messages.aria_filter_stream_severity()}
                  </label>
                  <select id="stream-severity-filter" name="severity" class="bp-filter-select">
                    <option :for={option <- @severity_options} value={option} selected={@stream_severity == option}>
                      {String.upcase(option)}
                    </option>
                  </select>
                </form>
              </div>
            </div>

            <.panel_scroll>
              <ol class="bp-event-feed" role="log" aria-label={Messages.aria_event_stream_log()}>
                <li :if={@filtered_stream == []} class="bp-empty-state">
                  {Messages.empty_no_events()}
                </li>
                <li :for={entry <- @filtered_stream} class="bp-event-row" id={"event-#{entry.id}"}>
                  <span class={"bp-event-icon #{entry.severity}"} aria-hidden="true">{String.upcase(entry.domain)}</span>
                  <span class="bp-event-detail">
                    {entry.label}
                    <span :if={entry.detail != ""} class="bp-color-dim">({entry.detail})</span>
                  </span>
                  <span class="bp-event-time">{entry.time}</span>
                </li>
              </ol>
            </.panel_scroll>
          </.panel>
        </.grid>
      </div>

      <Helpers.admin_footer pips={@footer_pips} />
    </main>
    """
  end
end
