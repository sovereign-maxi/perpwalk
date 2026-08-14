defmodule PerpWalkWeb.MarketLiveIntegrationTest do
  @moduledoc "Integration tests for the per-market detail view."

  use PerpWalkWeb.IntegrationCase

  alias PerpWalk.Identity.Facade, as: IdentityFacade
  alias PerpWalk.Markets.Services.{Maker, Trader}

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})}
  end

  describe "event throttling" do
    test "vote buttons carry phx-throttle to prevent double-cast", %{conn: conn} do
      market = pending_market!([])

      # Authenticate as a non-creator so the vote button is enabled.
      {:ok, %{account_id: voter_id}} = IdentityFacade.register()
      conn = log_in_account(conn, voter_id)

      {:ok, _view, html} = live(conn, "/markets/#{market.id}")

      assert html =~ ~s(phx-click="vote")
      assert html =~ ~s(phx-throttle="1000")
    end

    test "trade buttons on an active market carry phx-throttle", %{conn: conn} do
      market = pending_market!([]) |> activate!()

      {:ok, %{account_id: trader_id}} = IdentityFacade.register()
      conn = log_in_account(conn, trader_id)

      {:ok, _view, html} = live(conn, "/markets/#{market.id}")

      # Buy YES / Buy NO allocate a Monero subaddress on click — a
      # double-fire would burn extra subaddresses and pollute the WAL.
      assert html =~ ~s(phx-click="trade:open")
      assert html =~ ~s(phx-throttle="1000")
    end
  end

  describe "GET /markets/:id" do
    test "renders not-found state when market does not exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/markets/missing-id")

      assert html =~ "MARKET NOT FOUND"
      assert html =~ "missing-id"
    end

    test "renders market details for a valid id", %{conn: conn} do
      market = pending_market!([])

      {:ok, _view, html} = live(conn, "/markets/#{market.id}")

      assert html =~ market.description
      # Fresh pending market has no trades, so the OddsChart renders
      # the SVG frame with a flat horizontal line at 50% YES. This
      # keeps the panel at full height (no layout collapse) while
      # the Stats panel handles the textual current-odds question.
      # The full time-series render path is exercised by the trade
      # tests elsewhere in this suite.
      assert html =~ "pw-odds-chart-svg"
      # Comments panel replaced the trades panel — the audit trail
      # now lives only in the operator console + WAL, not the
      # public detail view.
      assert html =~ "COMMENTS"
    end

    test "shows AMM-derived YES/NO percentages on the detail view", %{conn: conn} do
      m = pending_market!([])

      {:ok, _view, html} = live(conn, "/markets/#{m.id}")

      # Initial 100/100 pool yields 0.50 each side (XMR-native, unitless)
      assert html =~ "0.50"
    end

    test "creator can view their own :awaiting_deposit market (renders liquidity panel)",
         %{conn: conn} do
      # Mirrors the flow that follows MarketNewLive's "Done" click:
      # the creator just proposed a market and lands on /markets/:id
      # before the deposit has been confirmed. The detail page must
      # render the Initial Liquidity action panel without raising.
      {:ok, %{account_id: creator_id}} = IdentityFacade.register()
      conn = log_in_account(conn, creator_id)

      {:ok, raw} =
        Maker.create_market(PerpWalk.TestHelpers.MarketsHelpers.market_opts(creator_account_id: creator_id))

      {:ok, _view, html} = live(conn, "/markets/#{raw.id}")

      assert html =~ "INITIAL LIQUIDITY"
      assert html =~ raw.deposit_subaddress
    end

    test "renders the empty comments state for a fresh market", %{conn: conn} do
      m = pending_market!([])

      {:ok, _view, html} = live(conn, "/markets/#{m.id}")

      assert html =~ "NO COMMENTS YET"
    end

    test "hides the composer entirely when logged out", %{conn: conn} do
      m = pending_market!([])

      {:ok, _view, html} = live(conn, "/markets/#{m.id}")

      # Composer absent, no visible login prompt — the disabled state
      # is implicit and the panel stays clean.
      refute html =~ "phx-submit=\"comment:submit\""
      refute html =~ "Log in</a> to post a comment"
    end

    test "an oversized comment draft never reaches the socket assign", %{conn: conn} do
      {:ok, %{account_id: account_id}} = IdentityFacade.register()
      conn = log_in_account(conn, account_id)
      m = pending_market!([])

      {:ok, view, _html} = live(conn, "/markets/#{m.id}")

      big = String.duplicate("x", 5_001)
      html = render_hook(view, "comment:draft", %{"comment" => %{"content" => big}})
      refute html =~ big

      html = render_hook(view, "comment:draft", %{"comment" => %{"content" => "sane draft"}})
      assert html =~ "sane draft"
    end

    test "stats still reflect open positions after dropping the trades feed", %{conn: conn} do
      m_raw = pending_market!([])
      market = activate!(m_raw)

      {:ok, _pos} = Trader.place_position("alice", market.id, :yes, 5)

      {:ok, _view, html} = live(conn, "/markets/#{market.id}")

      # The Stats panel still reads from positions; only the audit
      # feed UI is gone. "Total trades" count proves the data path
      # is intact.
      assert html =~ "Total trades"
      assert html =~ ">1</dd>"
    end
  end

  describe "Trade modal" do
    setup do
      stub_provider = fn ->
        idx = System.unique_integer([:positive])
        {:ok, %{address: "stub_addr_#{idx}_" <> String.duplicate("a", 80), address_index: idx}}
      end

      Application.put_env(:perpwalk, :subaddress_provider, stub_provider)

      on_exit(fn ->
        Application.delete_env(:perpwalk, :subaddress_provider)
      end)

      {:ok, %{display_key: _kp, account_id: account_id}} = IdentityFacade.register()

      logged_in =
        Phoenix.ConnTest.build_conn()
        |> log_in_account(account_id)

      logged_out = Phoenix.ConnTest.build_conn()

      {:ok, account_id: account_id, logged_in: logged_in, logged_out: logged_out}
    end

    test "logged-out user sees the Trade panel with DISABLED Buy buttons", %{logged_out: conn} do
      m_raw = pending_market!([])
      market = activate!(m_raw)

      {:ok, _view, html} = live(conn, "/markets/#{market.id}")

      assert html =~ "bp-btn-row"
      assert html =~ "Buy YES"
      assert html =~ "Buy NO"
      # Both buttons rendered with `disabled` and no phx-click; the
      # "Log in to trade" cue surfaces as a button title= tooltip
      # rather than a visible help line.
      assert html =~ "disabled"
      refute html =~ ~s(phx-click="trade:open")
      assert html =~ ~s(title="Log in to trade")
    end

    test "pending market shows Listing Vote panel instead of Trade", %{logged_in: conn} do
      market = pending_market!([])

      {:ok, _view, html} = live(conn, "/markets/#{market.id}")

      assert html =~ "LISTING VOTE"
      assert html =~ "Vote up"
      assert html =~ "Vote down"
      refute html =~ "Buy YES"
    end

    test "logged-in user on an active market sees Buy YES / Buy NO buttons", %{logged_in: conn} do
      m_raw = pending_market!([])
      market = activate!(m_raw)

      {:ok, _view, html} = live(conn, "/markets/#{market.id}")

      assert html =~ "bp-btn-row"
      assert html =~ "Buy YES"
      assert html =~ "Buy NO"
      assert html =~ ~s(phx-value-side="yes")
      assert html =~ ~s(phx-value-side="no")
      # Modal does NOT render until the user clicks.
      refute html =~ "bp-modal-overlay"
      refute html =~ "stub_addr_"
    end

    test "no quotes are pre-generated on mount", %{logged_in: conn, account_id: account_id} do
      m_raw = pending_market!([])
      market = activate!(m_raw)

      {:ok, _view, _html} = live(conn, "/markets/#{market.id}")

      assert PerpWalk.Markets.Facade.list_quotes_for_account(account_id) == []
    end

    test "clicking Buy YES opens the two-step modal, advances to deposit after refund submit",
         %{logged_in: conn, account_id: account_id} do
      m_raw = pending_market!([])
      market = activate!(m_raw)

      {:ok, view, _html} = live(conn, "/markets/#{market.id}")

      # Step 1: click Buy YES → refund-address form (no quote yet).
      step1_html =
        view
        |> element(~s(button[phx-click="trade:open"][phx-value-side="yes"]))
        |> render_click()

      assert step1_html =~ "bp-modal-overlay"
      assert step1_html =~ "REFUND ADDRESS"
      assert step1_html =~ ~s(name="refund_address")
      assert PerpWalk.Markets.Facade.list_quotes_for_account(account_id) == []

      # Step 2: submit refund address → quote created + deposit modal.
      step2_html =
        view
        |> form(~s(form[phx-submit="trade:refund_address_submit"]),
          refund_address: refund_address_stub()
        )
        |> render_submit()

      assert step2_html =~ "Buy YES"
      assert step2_html =~ "stub_addr_"
      assert step2_html =~ "pw-trade-modal-timer-yes"
      assert step2_html =~ ~r/\d+:\d{2}/
      assert [_quote] = PerpWalk.Markets.Facade.list_quotes_for_account(account_id)
    end

    test "Cancel button closes the modal", %{logged_in: conn} do
      m_raw = pending_market!([])
      market = activate!(m_raw)

      {:ok, view, _html} = live(conn, "/markets/#{market.id}")

      view
      |> element(~s(button[phx-click="trade:open"][phx-value-side="yes"]))
      |> render_click()

      html =
        view
        |> element(~s(.bp-btn-row button[phx-click="trade:close"]))
        |> render_click()

      refute html =~ "bp-modal-overlay"
    end

    test "renders a single QR <svg> in the modal", %{logged_in: conn} do
      m_raw = pending_market!([])
      market = activate!(m_raw)

      {:ok, view, _html} = live(conn, "/markets/#{market.id}")

      _ =
        view
        |> element(~s(button[phx-click="trade:open"][phx-value-side="no"]))
        |> render_click()

      html =
        view
        |> form(~s(form[phx-submit="trade:refund_address_submit"]),
          refund_address: refund_address_stub()
        )
        |> render_submit()

      assert html =~ "bp-modal-qr"
      # The page has two SVGs: the OddsChart (always rendered, with
      # a flat line at 50% for an untraded market) and the modal's
      # QR. The single-QR guarantee this test is named for is about
      # the modal contributing exactly one QR wrapper, not the page
      # having exactly one SVG total.
      qr_wrapper_count =
        html
        |> String.split(~r{class="bp-modal-qr[^"]*"})
        |> length()
        |> Kernel.-(1)

      assert qr_wrapper_count == 1
    end

    test "stepper increments contracts and the cost preview tracks it", %{logged_in: conn} do
      m_raw = pending_market!([])
      market = activate!(m_raw)

      {:ok, view, html} = live(conn, "/markets/#{market.id}")

      # Default is 1 contract at 50/50. Fair cost is ~0.5 unit-sizes
      # plus the 1.5% spread. On the test config (centinero
      # unit_size, 100×100-contract pool) the AMM produces 5_100_000_000
      # piconeros = 0.0051 XMR exact. The cost label MUST render the
      # exact value via `format_xmr/1` so the on-screen amount matches
      # the QR's subaddress amount byte-for-byte (the rounding-to-
      # "0.005 XMR" bug this test now guards against was the precise
      # case the operator surfaced for 99 contracts at a different
      # pool size).
      assert html =~ ~s(name="contracts")
      assert html =~ ~s(value="1")
      assert html =~ "0.0051 XMR"

      html =
        view
        |> element(~s(button[phx-click="contracts:inc"]))
        |> render_click()

      assert html =~ ~s(value="2")
    end

    test "minus button is disabled at the floor of 1 contract", %{logged_in: conn} do
      m_raw = pending_market!([])
      market = activate!(m_raw)

      {:ok, _view, html} = live(conn, "/markets/#{market.id}")

      assert html =~ ~r/phx-click="contracts:dec"[^>]*disabled/
    end

    test "buying with the stepper at N creates a quote for N contracts", %{
      logged_in: conn,
      account_id: account_id
    } do
      m_raw = pending_market!([])
      market = activate!(m_raw)

      {:ok, view, _html} = live(conn, "/markets/#{market.id}")

      # Inc twice → contracts = 3.
      _ = view |> element(~s(button[phx-click="contracts:inc"])) |> render_click()
      _ = view |> element(~s(button[phx-click="contracts:inc"])) |> render_click()

      _ =
        view
        |> element(~s(button[phx-click="trade:open"][phx-value-side="yes"]))
        |> render_click()

      # Two-step: step 1 form submit creates the quote.
      _ =
        view
        |> form(~s(form[phx-submit="trade:refund_address_submit"]),
          refund_address: refund_address_stub()
        )
        |> render_submit()

      assert [%{contracts: 3, side: :yes}] =
               PerpWalk.Markets.Facade.list_quotes_for_account(account_id)
    end

    test "buy button shows 'no liquidity' and is disabled past the pool side", %{
      logged_in: conn
    } do
      m_raw = pending_market!([])
      market = activate!(m_raw)

      {:ok, view, _html} = live(conn, "/markets/#{market.id}")

      # Test config has initial_pool_contracts = 100, so 100 contracts
      # tips both sides into insufficient_liquidity.
      html =
        view
        |> form(~s(form[phx-change="contracts:set"]), %{"contracts" => "100"})
        |> render_change()

      # The cost label flips to "NO LIQUIDITY" (short uppercase form
      # centralised in `PerpWalkWeb.Messages.no_liquidity_short/0`)
      # and the click handler is stripped from both buttons (disabled
      # state).
      assert html =~ "NO LIQUIDITY"
      refute html =~ ~s(phx-click="trade:open")

      # The "Insufficient liquidity on this side" message surfaces ONLY
      # as a button-`title` tooltip — per-ticker conditions don't
      # render in the visible `pw-action-help` line because the user
      # can clear them by stepping the ticker down. Persistent visible
      # help is reserved for state-of-the-world reasons (logged-out,
      # halted, market not active, creator-of-own-market).
      assert html =~ ~s(title="Insufficient liquidity on this side")
      refute html =~ ~s(class="pw-action-help")
    end

    test "creator on their own active market sees Buy YES / Buy NO disabled with the creator tooltip",
         %{conn: conn} do
      # Mirrors the server-side `Trader.ensure_not_creator/2` refusal.
      # The button stays rendered (the panel still has work to do for
      # the creator — they see prices, pool state, their LP exposure)
      # but `phx-click="trade:open"` is stripped and the disabled-state
      # tooltip explains why.
      {:ok, %{account_id: creator_id}} = IdentityFacade.register()
      conn = log_in_account(conn, creator_id)

      m_raw = pending_market!(creator_account_id: creator_id)
      market = activate!(m_raw)

      {:ok, _view, html} = live(conn, "/markets/#{market.id}")

      assert html =~ "Buy YES"
      assert html =~ "Buy NO"
      # Click handler is omitted — `buy_enabled?/2` returned false.
      refute html =~ ~s(phx-click="trade:open")
      # The "you created this market" tooltip surfaces via the
      # `buy_disabled_reason/2` → `viewer_is_creator?/1` path.
      assert html =~ "You created this market"
    end
  end

  describe "Listing vote panel" do
    alias PerpWalk.Markets.Facade, as: MarketsFacade

    setup do
      {:ok, %{account_id: viewer_id}} = IdentityFacade.register()
      {:ok, %{account_id: creator_id}} = IdentityFacade.register()

      logged_in =
        Phoenix.ConnTest.build_conn()
        |> log_in_account(viewer_id)

      logged_out = Phoenix.ConnTest.build_conn()

      {:ok, viewer_id: viewer_id, creator_id: creator_id, logged_in: logged_in, logged_out: logged_out}
    end

    test "logged-out viewer sees disabled Vote up / Vote down", %{logged_out: conn} do
      market = pending_market!([])

      {:ok, _view, html} = live(conn, "/markets/#{market.id}")

      assert html =~ "LISTING VOTE"
      assert html =~ "Vote up"
      assert html =~ "Vote down"
      assert html =~ "disabled"
      # The "Log in to vote" cue lives on the vote-button title=
      # tooltip; the disabled state itself is the visible signal.
      assert html =~ ~s(title="Log in to vote")
    end

    test "logged-in non-creator can vote up", %{logged_in: conn, viewer_id: viewer_id} do
      market = pending_market!([])

      {:ok, view, _html} = live(conn, "/markets/#{market.id}")

      html =
        view
        |> element(~s(button[phx-click="vote"][phx-value-direction="up"]))
        |> render_click()

      assert html =~ "Voted up"
      assert MarketsFacade.has_voted?(viewer_id, market.id)
    end

    test "creator cannot vote on their own market", %{
      creator_id: creator_id
    } do
      market = pending_market!(creator_account_id: creator_id)

      conn =
        Phoenix.ConnTest.build_conn()
        |> log_in_account(creator_id)

      {:ok, _view, html} = live(conn, "/markets/#{market.id}")

      assert html =~ "Vote up"
      assert html =~ "disabled"
      assert html =~ "You created this market"
    end

    test "second vote flips direction", %{logged_in: conn, viewer_id: viewer_id} do
      market = pending_market!([])
      {:ok, _} = MarketsFacade.cast_vote(viewer_id, market.id, :up)

      {:ok, view, _html} = live(conn, "/markets/#{market.id}")

      html =
        view
        |> element(~s(button[phx-click="vote"][phx-value-direction="down"]))
        |> render_click()

      assert html =~ "Voted down"

      assert {:ok, %{direction: :down}} =
               PerpWalk.Markets.Store.get_vote(viewer_id, market.id)
    end

    test "vote count in button label updates after a vote", %{logged_in: conn} do
      market = pending_market!([])

      {:ok, view, html} = live(conn, "/markets/#{market.id}")

      assert html =~ "Vote up (0)"

      html =
        view
        |> element(~s(button[phx-click="vote"][phx-value-direction="up"]))
        |> render_click()

      assert html =~ "Vote up (1)"
    end

    test "active market shows TRADE panel, not LISTING VOTE", %{logged_in: conn} do
      m_raw = pending_market!([])
      market = activate!(m_raw)

      {:ok, _view, html} = live(conn, "/markets/#{market.id}")

      refute html =~ "LISTING VOTE"
      assert html =~ "Buy YES"
    end

    test "criterion text renders under the chart", %{logged_in: conn} do
      {:ok, market} =
        Maker.create_market(market_opts(resolution_criterion: "Resolves YES if X happens by Y. Verified by source Z."))

      {:ok, _view, html} = live(conn, "/markets/#{market.id}")

      assert html =~ "RESOLUTION CRITERION"
      assert html =~ "Resolves YES if X happens by Y"
    end
  end

  describe "Dispute panel" do
    alias PerpWalk.Markets.Facade, as: MarketsFacade
    alias PerpWalk.Markets.Services.{Disputer, Resolver, Trader}

    setup do
      {:ok, %{account_id: viewer_id}} = IdentityFacade.register()

      logged_in =
        Phoenix.ConnTest.build_conn()
        |> log_in_account(viewer_id)

      logged_out = Phoenix.ConnTest.build_conn()

      {:ok, viewer_id: viewer_id, logged_in: logged_in, logged_out: logged_out}
    end

    # Seeds 1-contract YES positions for each listed trader during
    # the :active window before transitioning to :resolving — the
    # Disputer requires the disputer to have traded on the market.
    defp resolving_market!(opts \\ []) do
      market = pending_market!([])
      {:ok, _} = Resolver.activate(market.id)
      traders = Keyword.get(opts, :traders, [])
      Enum.each(traders, &({:ok, _} = Trader.place_position(&1, market.id, :yes, 1)))
      {:ok, _} = Resolver.expire(market.id)
      {:ok, m} = Resolver.submit_resolution(market.id, :yes)
      m
    end

    test ":resolving market shows Dispute panel, not Listing Vote or Trade",
         %{logged_in: conn, viewer_id: viewer_id} do
      m = resolving_market!(traders: [viewer_id])

      {:ok, _view, html} = live(conn, "/markets/#{m.id}")

      assert html =~ "Dispute"
      assert html =~ "Dispute (0)"
      refute html =~ "LISTING VOTE"
      refute html =~ "Buy YES"
    end

    test "logged-out viewer sees disabled Dispute button", %{logged_out: conn} do
      m = resolving_market!()

      {:ok, _view, html} = live(conn, "/markets/#{m.id}")

      assert html =~ "Dispute"
      assert html =~ "disabled"
      assert html =~ "Log in to dispute"
    end

    test "logged-in trader can open a dispute",
         %{logged_in: conn, viewer_id: viewer_id} do
      m = resolving_market!(traders: [viewer_id])

      {:ok, view, _html} = live(conn, "/markets/#{m.id}")

      html =
        view
        |> element(~s(button[phx-click="dispute:flag"]))
        |> render_click()

      # Click opens the deposit modal — actual dispute lands as
      # :awaiting_deposit until the user pays the stake.
      assert html =~ "Dispute"
      assert html =~ "register your dispute"
      assert MarketsFacade.has_flagged?(viewer_id, m.id)
    end

    test "creator cannot dispute their own market — button disabled",
         %{logged_in: conn, viewer_id: viewer_id} do
      # Build a market where the logged-in viewer is the creator.
      raw = pending_market!(creator_account_id: viewer_id)
      {:ok, _} = Resolver.activate(raw.id)
      {:ok, _} = Resolver.expire(raw.id)
      {:ok, m} = Resolver.submit_resolution(raw.id, :yes)

      {:ok, _view, html} = live(conn, "/markets/#{m.id}")

      assert html =~ "disabled"
      assert html =~ "You created this market"
    end

    test "viewer who did not trade cannot dispute — button disabled",
         %{logged_in: conn} do
      # Viewer is not the creator and has no positions on this market.
      m = resolving_market!()

      {:ok, _view, html} = live(conn, "/markets/#{m.id}")

      assert html =~ "disabled"
      assert html =~ "Only traders on this market can dispute"
    end

    test "second click after dispute is disabled",
         %{logged_in: conn, viewer_id: viewer_id} do
      m = resolving_market!(traders: [viewer_id])
      {:ok, _} = Disputer.start_dispute(viewer_id, m.id)

      {:ok, _view, html} = live(conn, "/markets/#{m.id}")

      assert html =~ "Disputed"
      assert html =~ "disabled"
      assert html =~ "You already disputed this market"
    end

    test "dispute count in button label reflects funded disputes only",
         %{logged_in: conn, viewer_id: viewer_id} do
      # Counter shows `live_dispute_count` — only deposits that have
      # confirmed on-chain count, so unfunded `:awaiting_deposit`
      # records (mid-modal, dismissed without paying) don't inflate
      # the displayed number.
      m = resolving_market!(traders: [viewer_id, "voter-1", "voter-2"])
      {:ok, _} = Disputer.start_dispute("voter-1", m.id)
      {:ok, _} = Disputer.confirm_deposit("voter-1", m.id)
      {:ok, _} = Disputer.start_dispute("voter-2", m.id)
      {:ok, _} = Disputer.confirm_deposit("voter-2", m.id)

      {:ok, view, html} = live(conn, "/markets/#{m.id}")

      assert html =~ "Dispute (2)"

      # Clicking dispute creates an :awaiting_deposit record for the
      # viewer — counter stays at 2 until the deposit confirms.
      # Critical regression check: previously this jumped to (3)
      # because dispute_count counted every status, misleading users
      # into thinking the threshold had moved.
      html =
        view
        |> element(~s(button[phx-click="dispute:flag"]))
        |> render_click()

      assert html =~ "Disputed (2)"
      refute html =~ "Disputed (3)"
    end

    test ":pending market does not show Dispute panel", %{logged_in: conn} do
      market = pending_market!([])

      {:ok, _view, html} = live(conn, "/markets/#{market.id}")

      refute html =~ ~s(phx-click="dispute:flag")
    end
  end

  describe "Resolution panel — creator on :expired markets" do
    alias PerpWalk.Markets.Services.Resolver

    setup do
      {:ok, %{account_id: creator_id}} = IdentityFacade.register()
      {:ok, %{account_id: stranger_id}} = IdentityFacade.register()

      market =
        pending_market!(creator_account_id: creator_id, description: "Resolve me")
        |> activate!()

      {:ok, _expired} = Resolver.expire(market.id)

      logged_in_creator =
        Phoenix.ConnTest.build_conn() |> log_in_account(creator_id)

      logged_in_stranger =
        Phoenix.ConnTest.build_conn() |> log_in_account(stranger_id)

      logged_out = Phoenix.ConnTest.build_conn()

      {:ok,
       market: market,
       creator_id: creator_id,
       stranger_id: stranger_id,
       creator_conn: logged_in_creator,
       stranger_conn: logged_in_stranger,
       logged_out_conn: logged_out}
    end

    test "creator sees the Submit Resolution panel on an :expired market", %{
      market: market,
      creator_conn: conn
    } do
      {:ok, _view, html} = live(conn, "/markets/#{market.id}")

      assert html =~ "SUBMIT RESOLUTION"
      assert html =~ "Resolve YES"
      assert html =~ "Resolve NO"
      # :void is operator-only — creators can't dodge disputes by voiding.
      refute html =~ "phx-value-outcome=\"void\""
    end

    test "non-creator does not see the Submit Resolution panel", %{
      market: market,
      stranger_conn: conn
    } do
      {:ok, _view, html} = live(conn, "/markets/#{market.id}")

      refute html =~ "Submit Resolution"
      refute html =~ "Resolve YES"
    end

    test "logged-out viewer does not see the panel either", %{
      market: market,
      logged_out_conn: conn
    } do
      {:ok, _view, html} = live(conn, "/markets/#{market.id}")
      refute html =~ "Submit Resolution"
    end

    test "creator can click Resolve YES and the market transitions to :resolving", %{
      market: market,
      creator_conn: conn
    } do
      {:ok, view, _html} = live(conn, "/markets/#{market.id}")

      html =
        view
        |> element(~s(button[phx-click="resolve"][phx-value-outcome="yes"]))
        |> render_click()

      assert html =~ "Resolution submitted as YES"

      {:ok, refreshed} = PerpWalk.Markets.Facade.get_market(market.id)
      assert refreshed.status == :resolving
      assert refreshed.outcome == :yes
    end

    test "panel does NOT appear on :pending or :active markets", %{
      creator_conn: conn,
      creator_id: creator_id
    } do
      pending = pending_market!(creator_account_id: creator_id)
      {:ok, _view, html_pending} = live(conn, "/markets/#{pending.id}")
      refute html_pending =~ "Submit Resolution"

      active = pending_market!(creator_account_id: creator_id) |> activate!()
      {:ok, _view, html_active} = live(conn, "/markets/#{active.id}")
      refute html_active =~ "Submit Resolution"
    end
  end
end
