defmodule PerpWalkWeb.MarketNewLiveIntegrationTest do
  @moduledoc "Integration tests for the public MarketNewLive proposal flow."

  use PerpWalkWeb.IntegrationCase

  alias PerpWalk.Identity.Facade, as: Identity
  alias PerpWalk.Markets.Facade, as: Markets

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})}
  end

  describe "GET /markets/new" do
    test "redirects to login when unauthenticated", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/auth/login"}}} = live(conn, "/markets/new")
    end

    test "renders the proposal form when authenticated", %{conn: conn} do
      {:ok, %{account_id: account_id}} = Identity.register()
      conn = log_in_account(conn, account_id)

      {:ok, _view, html} = live(conn, "/markets/new")

      assert html =~ "PROPOSE MARKET"
      assert html =~ "QUESTION"
      assert html =~ "RESOLUTION CRITERION"
      assert html =~ "CATEGORY"
      assert html =~ "BETTING CLOSES"
      assert html =~ "MARKET DEPOSIT (XMR)"
      assert html =~ "deposit_xmr"
      refute html =~ "RESOLUTION DEADLINE"
      refute html =~ "resolution_deadline"
    end

    test "shows the propose-market link in the nav when authenticated", %{conn: conn} do
      {:ok, %{account_id: account_id}} = Identity.register()
      conn = log_in_account(conn, account_id)

      {:ok, _view, html} = live(conn, "/markets")

      assert html =~ ~s(href="/markets/new")
      assert html =~ "Propose"
    end

    test "hides the propose-market link when unauthenticated", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/markets")
      refute html =~ ~s(href="/markets/new")
    end
  end

  describe "POST /markets/new (form submit)" do
    setup %{conn: conn} do
      {:ok, %{account_id: account_id}} = Identity.register()
      conn = log_in_account(conn, account_id)
      {:ok, conn: conn, account_id: account_id}
    end

    test "creates a market on valid input, shows the liquidity modal, then redirects on close",
         %{conn: conn, account_id: aid} do
      {:ok, view, _html} = live(conn, "/markets/new")

      expiry = future_local(86_400 * 5)

      params = %{
        "market" => %{
          "description" => "Will the SEC chair resign before 2027-01-01?",
          "resolution_criterion" =>
            "Resolves YES if a primary source confirms the event has occurred before the closing time.",
          "category" => "politics",
          "expires_at" => expiry
        }
      }

      # Submitting the form now opens the liquidity modal instead of
      # navigating away immediately. The market is persisted as
      # `:awaiting_deposit` with the deposit subaddress + amount
      # rendered in the modal; closing the modal triggers the
      # detail-page navigation.
      html = render_submit(form(view, "form[phx-submit=\"create\"]", params))

      assert html =~ "INITIAL LIQUIDITY"
      assert html =~ "1.0 XMR"
      assert html =~ "phx-click=\"liquidity:close\""

      [market] = Markets.list_markets()
      assert market.description == "Will the SEC chair resign before 2027-01-01?"
      assert market.resolution_criterion =~ "primary source confirms"
      assert market.category == :politics
      assert market.creator_account_id == aid
      assert market.status == :awaiting_deposit
      assert is_binary(market.deposit_subaddress)
      assert market.deposit_amount == 1_000_000_000_000
      # Resolution deadline is derived = expiry + 24h fixed window
      assert DateTime.diff(market.resolution_deadline, market.expiry, :second) == 86_400

      # Clicking Done closes the modal and navigates to the detail page.
      assert {:error, {:live_redirect, %{to: redirect_to}}} =
               render_click(view, "liquidity:close")

      assert redirect_to == "/markets/#{market.id}"
    end

    test "auto-closes the liquidity modal and navigates when the deposit confirms",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/markets/new")

      params = %{
        "market" => %{
          "description" => "Will the SEC chair resign before 2027-01-01?",
          "resolution_criterion" =>
            "Resolves YES if a primary source confirms the event has occurred before the closing time.",
          "category" => "politics",
          "expires_at" => future_local(86_400 * 5)
        }
      }

      render_submit(form(view, "form[phx-submit=\"create\"]", params))
      [market] = Markets.list_markets()

      # Simulate the Poller confirming the creator's deposit. The
      # MarketDepositConfirmed event is what transitions the market
      # to `:pending`; the open MarketNewLive should navigate to the
      # detail page rather than leaving the modal in place.
      send(
        view.pid,
        %PerpWalk.Events.Markets.MarketDepositConfirmed{
          market_id: market.id,
          deposit_subaddress_index: 0,
          timestamp: DateTime.utc_now()
        }
      )

      assert_redirect(view, "/markets/#{market.id}")
    end

    test "rejects when resolution criterion is too short", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/markets/new")

      params = %{
        "market" => %{
          "description" => "Will the criterion validation reject short text here?",
          "resolution_criterion" => "too short",
          "category" => "politics",
          "expires_at" => future_local(86_400 * 5)
        }
      }

      html = render_submit(form(view, "form[phx-submit=\"create\"]", params))

      assert html =~ "Resolution criterion must be at least 30 characters"
      assert Markets.list_markets() == []
    end

    test "rejects when description is too short", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/markets/new")

      params = %{
        "market" => %{
          "description" => "Too short",
          "resolution_criterion" =>
            "Resolves YES if a primary source confirms the event has occurred before the closing time.",
          "category" => "politics",
          "expires_at" => future_local(86_400 * 5)
        }
      }

      html = render_submit(form(view, "form[phx-submit=\"create\"]", params))

      assert html =~ "Question must be at least 12 characters"
      assert Markets.list_markets() == []
    end

    test "rejects when expiry is in the past", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/markets/new")

      past = DateTime.add(DateTime.utc_now(), -86_400, :second) |> format_local()

      params = %{
        "market" => %{
          "description" => "Will this fail because expiry is past?",
          "resolution_criterion" =>
            "Resolves YES if a primary source confirms the event has occurred before the closing time.",
          "category" => "politics",
          "expires_at" => past
        }
      }

      html = render_submit(form(view, "form[phx-submit=\"create\"]", params))

      assert html =~ "Closing time must be in the future"
      assert Markets.list_markets() == []
    end
  end

  # --- helpers ---

  defp future_local(seconds_ahead) do
    DateTime.utc_now() |> DateTime.add(seconds_ahead, :second) |> format_local()
  end

  defp format_local(%DateTime{} = dt) do
    dt |> DateTime.to_iso8601() |> String.slice(0, 16)
  end
end
