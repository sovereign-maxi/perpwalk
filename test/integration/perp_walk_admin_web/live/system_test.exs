defmodule PerpWalkAdminWeb.SystemIntegrationTest do
  @moduledoc """
  Integration tests for `/admin/system` — the host vitals + venue
  infrastructure page.

  Seven panels across three rows: CPU + Memory + Disk sparklines
  on row 1, Replication + Federation on row 2, Monero + BEAM on
  row 3 (WAL entries + seq live in the BEAM panel). Shares the
  admin chrome (header / sub-nav with the page-switcher dropdown
  / pip footer).
  """

  use PerpWalkAdminWeb.IntegrationCase

  alias PerpWalk.Events.Telemetry, as: TelemetryEvents
  alias PerpWalk.Federation.Store, as: FederationStore
  alias PerpWalk.Telemetry.Health.System, as: HealthSystem

  setup do
    :ok = FederationStore.clear()
    on_exit(fn -> HealthSystem.clear_halt() end)
    :ok
  end

  describe "GET /admin/system" do
    test "renders all seven panels and the admin badge", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/system")

      assert html =~ "PERP WALK"
      assert html =~ "Admin - N"

      # Row 1: three independent vitals sparklines.
      assert html =~ ~s(<h2 class="bp-panel-title">CPU</h2>)
      assert html =~ ~s(<h2 class="bp-panel-title">MEMORY</h2>)
      assert html =~ ~s(<h2 class="bp-panel-title">DISK</h2>)

      # Row 2: Replication + Federation.
      assert html =~ "REPLICATION"
      assert html =~ "FEDERATION"

      # Row 3: Monero + BEAM.
      assert html =~ "MONERO"
      assert html =~ "BEAM"
    end

    test "BEAM panel shows process-tree + WAL stats", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/system")

      assert html =~ "Load"
      assert html =~ "BEAM memory"
      assert html =~ "ETS memory"
      assert html =~ "Processes"
      assert html =~ "Atoms"
      assert html =~ "Schedulers"
      assert html =~ "Run queue"
      assert html =~ "Uptime"
      # WAL stats moved out of the deleted Storage panel into BEAM.
      assert html =~ "WAL entries"
      assert html =~ "WAL seq"
    end

    test "no Storage / System Vitals panels — those collapsed into CPU/Mem/Disk + BEAM", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/system")

      refute html =~ ~s(<h2 class="bp-panel-title">System Vitals</h2>)
      refute html =~ ~s(<h2 class="bp-panel-title">Storage</h2>)
    end

    test "Replication panel surfaces per-peer rows or the empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/system")

      assert html =~ "REPLICATION"
      assert html =~ "Peer" or html =~ "No peers configured"
    end

    test "Federation panel surfaces quorum + signing detail", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/system")

      assert html =~ "Quorum"
      assert html =~ "Designated processor"
      assert html =~ "Last sign"
      assert html =~ "Signs (24h)"
      assert html =~ "In-flight payouts"
    end

    test "Monero panel surfaces wallet + chain rows", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/system")

      assert html =~ "Wallet RPC"
      assert html =~ "Balance"
      assert html =~ "Wallet chain height"
    end

    test "does NOT render venue stats or events — those live on their own pages", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/system")

      refute html =~ "HOUSE INCOME"
      refute html =~ "ACTIVE ALERTS"
      refute html =~ "EVENT STREAM"
    end

    test "page-switcher dropdown lists the other two pages", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/system")

      assert html =~ "SYSTEM"
      assert html =~ "/admin/dashboard"
      assert html =~ "/admin/events"
    end

    test "tick refresh re-renders without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/system")
      send(view.pid, :tick)
      html = render(view)
      assert html =~ "BEAM"
    end

    test "Status pip updates when SystemStatusChanged fires", %{conn: conn} do
      HealthSystem.clear_halt()
      {:ok, view, initial_html} = live(conn, "/admin/system")
      assert initial_html =~ ~s(Status <span class="accent">Healthy</span>)

      :ok = HealthSystem.set_halted("regression: sub-nav Status pip refresh")

      # Delivered directly to skip the PubSub round-trip; the LiveView's
      # handle_info catch-all treats it the same as a real broadcast.
      send(
        view.pid,
        %TelemetryEvents.SystemStatusChanged{status: :halted, timestamp: DateTime.utc_now()}
      )

      html = render(view)

      # Regression guard: the sub-nav stats must live as a socket assign
      # (`:sub_nav_stats`) computed in `refresh_snapshot/1`, not as an
      # inline `Helpers.sub_nav_stats()` call in the template. LiveView's
      # change tracking only diffs assigns; an inline helper call is
      # evaluated but the resulting HTML gets cached under the stable
      # `current_page` key, so the pip stays "Healthy" forever.
      assert html =~ ~s(Status <span class="loss">Halted</span>)
    end
  end
end
