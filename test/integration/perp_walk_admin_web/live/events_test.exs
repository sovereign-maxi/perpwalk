defmodule PerpWalkAdminWeb.EventsIntegrationTest do
  @moduledoc """
  Integration tests for `/admin/events` — the alerts + event stream
  page, two-column layout.

  Subscribes to the union of markets / federation / reserves /
  telemetry events at mount, captures the last 50 incoming events,
  and re-fetches the active-alert set on every domain event +
  `:tick`. Shares the admin chrome (header / sub-nav with the
  page-switcher dropdown / pip footer) with the other two admin
  pages.
  """

  use PerpWalkAdminWeb.IntegrationCase

  alias PerpWalk.Events.Telemetry, as: TelemetryEvents
  alias PerpWalk.Federation.Store, as: FederationStore
  alias PerpWalk.Markets.Services.Trader
  alias PerpWalk.Monero.Orphans
  alias PerpWalk.Telemetry.Alerts.Manager
  alias PerpWalk.Telemetry.Health.Cache
  alias PerpWalk.Telemetry.Health.System, as: HealthSystem

  setup do
    :ok = FederationStore.clear()

    # The alerts Manager is an app-lifetime singleton: an alert fired
    # by an earlier test (a replicator batch rejection, a bootstrap
    # address mismatch, orphan rows left in the DETS table) stays
    # visible for its sticky window and would leak into the "empty
    # states" assertions below. Clear the alert-feeding inputs, then
    # flush rule states by forcing eval cycles — each cycle is one
    # consecutive-OK step (firing → resolving → resolved), and five
    # covers the deepest resolve_after in the ruleset.
    # :sys.get_state is the mailbox barrier: it returns only after
    # the eval completed.
    Cache.clear(:bootstrap_address_mismatch)
    Cache.clear(:replication_batch_rejected)
    Cache.clear_replicator_ticks()
    Orphans.clear()

    manager = Process.whereis(Manager)

    for _ <- 1..5 do
      send(manager, :evaluate)
      _ = :sys.get_state(manager)
    end

    on_exit(fn -> HealthSystem.clear_halt() end)
    :ok
  end

  describe "GET /admin/events" do
    test "renders Active Alerts + Event Stream panels and the admin badge", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/events")

      assert html =~ "PERP WALK"
      assert html =~ "Admin - N"

      # Two panels — alerts + event stream.
      assert html =~ "ACTIVE ALERTS"
      assert html =~ "EVENT STREAM"

      # Each panel carries its own filter row + severity dropdown.
      assert html =~ "alerts-severity-filter"
      assert html =~ "stream-severity-filter"
      assert html =~ "bp-filter-select"
      assert html =~ "MARKETS"
      assert html =~ "FEDERATION"
    end

    test "no top filter strip and no Resolved Alerts panel — those are gone", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/events")
      refute html =~ "Event Filters"
      refute html =~ "Resolved Alerts"
    end

    test "stream domain filter narrows the event stream independently of alerts", %{conn: conn} do
      # Mount first so the LiveView's event subscription is in place,
      # then drive a Markets event through — subscribe-then-publish
      # is the only ordering that puts the event on the LiveView's
      # mailbox.
      {:ok, view, _html} = live(conn, "/admin/events")

      m_raw = pending_market!([])
      market = activate!(m_raw)
      {:ok, _pos} = Trader.place_position("alice", market.id, :yes, 5)

      # `render/1` flushes pending handle_info messages first so the
      # event is captured before the assertion runs.
      html = render(view)
      refute html =~ "No events yet"

      # Filter the stream to Federation — Markets event drops out.
      view
      |> element("[phx-click='filter_stream_domain'][phx-value-domain='Federation']")
      |> render_click()

      html_filtered = render(view)
      assert html_filtered =~ "No events yet"

      # Reset Domain to ALL → the seeded event is visible again.
      view
      |> element("[phx-click='filter_stream_domain'][phx-value-domain='ALL']")
      |> render_click()

      html_reset = render(view)
      refute html_reset =~ "No events yet"
    end

    test "shows the empty states initially", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/events")

      assert html =~ "No alerts yet"
      assert html =~ "No events yet"
    end

    test "does NOT render venue stats or system metrics — those live on their own pages", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/events")

      refute html =~ "HOUSE INCOME"
      refute html =~ "Resources"
    end

    test "page-switcher dropdown lists the other two pages", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/events")

      assert html =~ "EVENTS"
      assert html =~ "/admin/dashboard"
      assert html =~ "/admin/system"
    end

    test "Event Stream populates when a domain event fires", %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/events")
      assert html =~ "No events yet"

      # Drive a real domain event through the EventBus so the
      # subscription path lights up — placing a position publishes
      # `Markets.Events.PositionOpened`.
      m_raw = pending_market!([])
      market = activate!(m_raw)
      {:ok, _pos} = Trader.place_position("alice", market.id, :yes, 5)

      # The position write is async w.r.t. the LiveView's mailbox;
      # `render/1` flushes pending handle_info messages.
      html_after = render(view)

      refute html_after =~ "No events yet"
    end

    test "Status pip updates when SystemStatusChanged fires", %{conn: conn} do
      HealthSystem.clear_halt()
      {:ok, view, initial_html} = live(conn, "/admin/events")
      assert initial_html =~ ~s(Status <span class="accent">Healthy</span>)

      :ok = HealthSystem.set_halted("regression: sub-nav Status pip refresh")

      send(
        view.pid,
        %TelemetryEvents.SystemStatusChanged{status: :halted, timestamp: DateTime.utc_now()}
      )

      html = render(view)

      # Regression guard: `refresh_chrome/1` must re-assign `:sub_nav_stats`
      # on every subscribed event, otherwise the Status pip stays stale
      # until the next 5 s tick. Inline `Helpers.sub_nav_stats()` in the
      # template is NOT enough — LiveView caches component output under
      # its stable `current_page` attr.
      assert html =~ ~s(Status <span class="loss">Halted</span>)
    end

    test "clear_events empties the stream", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/events")

      # Seed an event.
      m_raw = pending_market!([])
      market = activate!(m_raw)
      {:ok, _pos} = Trader.place_position("alice", market.id, :yes, 5)
      html = render(view)
      refute html =~ "No events yet"

      # Click CLEAR — phx-click handler empties the assign.
      view |> element("a", "CLEAR") |> render_click()
      html_after = render(view)
      assert html_after =~ "No events yet"
    end
  end
end
