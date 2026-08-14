defmodule PerpWalkAdminWeb.DashboardIntegrationTest do
  @moduledoc """
  Integration tests for `/admin/dashboard` — the venue-stats page.

  After the admin-UI split, this page renders only the four venue
  panels (Markets / Activity / Wallet & Signing / House Income)
  plus the shared chrome (header / sub-nav with the page-switcher
  dropdown / pip footer). System metrics live on `/admin/system`;
  alerts + events live on `/admin/events` — covered by their own
  files in this directory.
  """

  use PerpWalkAdminWeb.IntegrationCase

  import ExUnit.CaptureIO, only: [capture_io: 1]

  alias PerpWalk.Federation.{Console, Signer}
  alias PerpWalk.Federation.Store, as: FederationStore
  alias PerpWalk.Markets.Services.{Trader, Voter}

  setup do
    :ok = FederationStore.clear()
    Signer.set_backend(fn _ -> {:error, :no_backend} end)
    if Signer.halted?(), do: Signer.resume()
    on_exit(fn -> if Signer.halted?(), do: Signer.resume() end)
    :ok
  end

  describe "GET /admin" do
    test "redirects to /admin/dashboard", %{conn: conn} do
      conn = get(conn, "/admin")
      assert redirected_to(conn, 302) == "/admin/dashboard"
    end
  end

  describe "GET /admin/dashboard" do
    test "renders the venue-stat panels and the admin badge", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/dashboard")

      assert html =~ "PERP WALK"
      assert html =~ "Admin - N"

      # Top-row venue panels.
      assert html =~ "MARKETS"
      assert html =~ "ACTIVITY"
      assert html =~ "WALLET &amp; SIGNING"
      assert html =~ "HOUSE INCOME"

      # Bottom-row activity panels (flex-fill to footer).
      assert html =~ "RECENT SETTLEMENTS"
      assert html =~ "TOP ACTIVE MARKETS"

      # Panel-specific rows.
      assert html =~ "Volume (24h)"
      assert html =~ "Trades (24h)"
      assert html =~ "Pool TVL"
      assert html =~ "WAL seq"
      assert html =~ "Signs (24h)"
      assert html =~ "Slashes"
      assert html =~ "Burns"
    end

    test "Recent Settlements shows the empty state when nothing has settled", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/dashboard")
      assert html =~ "No settlements yet"
    end

    test "Top Active Markets shows the empty state when nothing is active", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/dashboard")
      assert html =~ "No active markets"
    end

    test "Top Active Markets populates when a market is activated and traded", %{conn: conn} do
      m_raw = pending_market!([])
      market = activate!(m_raw)
      {:ok, _pos} = Trader.place_position("alice", market.id, :yes, 5)

      {:ok, _view, html} = live(conn, "/admin/dashboard")

      assert html =~ "TOP ACTIVE MARKETS"
      # Empty-state no longer present because the market is in the table.
      refute html =~ "No active markets"
    end

    test "does NOT render system metrics or events — those live on their own pages", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/dashboard")

      # System panel rows → /admin/system
      refute html =~ "Schedulers"
      # Events page panels → /admin/events
      refute html =~ "ACTIVE ALERTS"
      refute html =~ "EVENT STREAM"
    end

    test "page-switcher dropdown lists the other two pages", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/dashboard")

      # Trigger button shows the current page; menu lists targets.
      assert html =~ "DASHBOARD"
      assert html =~ "/admin/system"
      assert html =~ "/admin/events"
    end

    test "stats reflect the current market set", %{conn: conn} do
      m_raw = pending_market!([])
      market = activate!(m_raw)
      {:ok, _pos} = Trader.place_position("alice", market.id, :yes, 5)

      {:ok, _view, html} = live(conn, "/admin/dashboard")

      assert html =~ "MARKETS"
      assert html =~ "Active"
    end
  end

  describe "House Income panel" do
    test "renders all six rows including Spread / Drawn / Available", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/dashboard")

      assert html =~ "HOUSE INCOME"
      assert html =~ "Total"
      assert html =~ "Slashes"
      assert html =~ "Burns"
      assert html =~ "Spread"
      assert html =~ "Drawn"
      assert html =~ "Available"
    end

    test "Available decreases after a successful federation income withdrawal", %{conn: conn} do
      # Seed burned income — 6 unanimous downvotes crosses the Wilson
      # 0.6 lower bound and burns the deposit to federation income.
      market = pending_market!([])

      Enum.each(1..6, fn i ->
        {:ok, _} = Voter.cast_vote("voter-#{i}", market.id, :down)
      end)

      seeded = market.deposit_amount

      {:ok, view, _html} = live(conn, "/admin/dashboard")

      # Push a tick to refresh the snapshot now that income is seeded.
      send(view.pid, :tick)
      html = render(view)
      assert html =~ "HOUSE INCOME"

      # Total earned reflects the burned deposit; nothing drawn yet.
      seeded_xmr = format_xmr_for_html(seeded)
      assert html =~ seeded_xmr

      # Drive a successful federation income withdrawal end-to-end.
      stub_txid = "stub-#{System.unique_integer([:positive])}"
      Signer.set_backend(fn _payout -> {:ok, stub_txid} end)

      withdrawn = div(seeded, 4)
      destination = "4" <> String.duplicate("A", 94)

      capture_io(fn ->
        {:ok, _} = Console.withdraw_federation_income(withdrawn, destination, "op-1")
        :ok = Signer.run_now()
      end)

      # Push a tick — the panel re-renders against the live ledger.
      send(view.pid, :tick)
      html_after = render(view)

      drawn_xmr = format_xmr_for_html(withdrawn)
      available_xmr = format_xmr_for_html(seeded - withdrawn)
      assert html_after =~ drawn_xmr
      assert html_after =~ available_xmr
    end
  end

  defp format_xmr_for_html(piconeros) do
    # Dashboard tiles are summary surfaces — they use the compact
    # rounding form, NOT the exact piconero-precision formatter.
    # Mirror that here so the html-contains assertions match.
    PerpWalkWeb.Live.Helpers.format_xmr_compact(piconeros)
  end
end
