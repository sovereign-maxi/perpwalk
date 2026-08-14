defmodule PerpWalkWeb.MarketsLiveIntegrationTest do
  @moduledoc "Integration tests for the public MarketsLive browse view."

  use PerpWalkWeb.IntegrationCase

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.Services.Maker

  describe "GET /markets" do
    test "renders empty state when no markets exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/markets")

      assert html =~ "MARKETS"
      assert html =~ "NO MARKETS YET"
    end

    test "renders a market row when a market exists", %{conn: conn} do
      market = pending_market!([])

      {:ok, _view, html} = live(conn, "/markets")

      assert html =~ market.description
      assert html =~ "POLITICS"
    end

    test "status filter limits which markets show", %{conn: conn} do
      pending = pending_market!([])
      active_raw = pending_market!(description: "Active market description")
      _active = activate!(active_raw)

      {:ok, view, _html} = live(conn, "/markets")

      html =
        view
        |> form("form[phx-change=filter_status]", %{"status" => "active"})
        |> render_change()

      assert html =~ "Active market description"
      refute html =~ pending.description
    end

    test "category filter limits which markets show", %{conn: conn} do
      politics = pending_market!(category: :politics)

      {:ok, crypto} =
        Maker.create_market(market_opts(category: :crypto, description: "Crypto market"))

      {:ok, view, _html} = live(conn, "/markets")

      html =
        view
        |> element("button[phx-value-category=crypto]")
        |> render_click()

      assert html =~ crypto.description
      refute html =~ politics.description
    end

    test "live-updates when MarketCreated fires", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/markets")

      {:ok, market} =
        Maker.create_market(market_opts(description: "Created mid-session"))

      EventBus.publish(%MarketsEvents.MarketCreated{
        market_id: market.id,
        description: market.description,
        category: market.category,
        creator_account_id: market.creator_account_id,
        timestamp: DateTime.utc_now()
      })

      assert render(view) =~ "Created mid-session"
    end
  end

  describe "pagination" do
    test "shows the paginator bar with totals", %{conn: conn} do
      _ = pending_market!(description: "First")
      _ = pending_market!(description: "Second")
      _ = pending_market!(description: "Third")

      {:ok, _view, html} = live(conn, "/markets")

      assert html =~ "PAGE 1 / 1"
      assert html =~ "1–3"
      assert html =~ "of"
    end

    test "second page shows different rows", %{conn: conn} do
      # 26 markets → page 1 has 25, page 2 has 1
      markets =
        for i <- 1..26 do
          pending_market!(description: "Market #{String.pad_leading(Integer.to_string(i), 3, "0")}")
        end

      {:ok, view, html} = live(conn, "/markets")

      assert html =~ "PAGE 1 / 2"
      # First 25 by descending created_at — last-created shows first
      first_market = List.last(markets)
      assert html =~ first_market.description

      # Click NEXT
      page_2 = view |> element("button[phx-value-page='2']") |> render_click()

      assert page_2 =~ "PAGE 2 / 2"
      # The very first market (oldest) should now be on page 2
      oldest = List.first(markets)
      assert page_2 =~ oldest.description
    end

    test "filter change resets to page 1", %{conn: conn} do
      # 30 politics markets so page 2 exists
      for i <- 1..30 do
        pending_market!(description: "Politics #{i}", category: :politics)
      end

      {:ok, view, _html} = live(conn, "/markets")

      # Jump to page 2
      page_2 = view |> element("button[phx-value-page='2']") |> render_click()
      assert page_2 =~ "PAGE 2 / 2"

      # Switch category → should reset to page 1
      reset = view |> element("button[phx-value-category=crypto]") |> render_click()
      assert reset =~ "PAGE 1 / 1"
    end
  end

  describe "status counts" do
    test "displays per-status counts in the sub-nav pills", %{conn: conn} do
      _pending = pending_market!([])
      m2 = pending_market!(description: "second")
      _active = activate!(m2)

      {:ok, _view, html} = live(conn, "/markets")

      # Two markets total — 1 pending, 1 active.
      assert html =~ "ALL"
      assert html =~ "ACTIVE"
      assert html =~ "PENDING"
    end
  end

  describe "vote tally on a pending market" do
    alias PerpWalk.Identity.Facade, as: IdentityFacade

    setup do
      {:ok, %{display_key: keyphrase, account_id: account_id}} = IdentityFacade.register()

      logged_in =
        Phoenix.ConnTest.build_conn()
        |> PerpWalkWeb.TestHelpers.AuthHelpers.log_in_account(account_id)

      logged_out = Phoenix.ConnTest.build_conn()

      {:ok, keyphrase: keyphrase, account_id: account_id, logged_in: logged_in, logged_out: logged_out}
    end

    test "tally renders as static spans on the list page (no inline buttons)", %{logged_out: conn} do
      _market = pending_market!([])

      {:ok, _view, html} = live(conn, "/markets")

      refute html =~ ~s(phx-click="vote")
      assert html =~ "▲"
      assert html =~ "▼"
    end

    test "logged-in users also see static spans — voting requires clicking through to detail", %{logged_in: conn} do
      _market = pending_market!([])

      {:ok, _view, html} = live(conn, "/markets")

      refute html =~ ~s(phx-click="vote")
      assert html =~ "▲"
      assert html =~ "▼"
    end
  end

  describe "GET /" do
    test "serves the markets browse view (same as /markets)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "MARKETS"
      # Leaderboard is no longer rendered on the markets page — it
      # lives at /leaderboard now.
      refute html =~ "NO RANKINGS YET"
    end
  end
end
