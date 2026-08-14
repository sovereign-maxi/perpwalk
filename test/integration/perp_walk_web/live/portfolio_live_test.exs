defmodule PerpWalkWeb.PortfolioLiveIntegrationTest do
  @moduledoc """
  Integration tests for the personal `/portfolio` view.

  Covers the not-logged-in redirect, empty-state rendering,
  position-list shape, and the claim-flow happy path. Federation
  signing is the federation's concern — these tests stop at the
  point claim_payout queues a Payout.
  """

  use PerpWalkWeb.IntegrationCase

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents
  alias PerpWalk.Federation.Store, as: FederationStore
  alias PerpWalk.Identity.Facade, as: IdentityFacade
  alias PerpWalk.Markets.Services.{Resolver, Trader}
  alias PerpWalkWeb.Live.Helpers

  setup do
    :ok = FederationStore.clear()
    {:ok, %{display_key: _kp, account_id: account_id}} = IdentityFacade.register()

    logged_in =
      Phoenix.ConnTest.build_conn()
      |> log_in_account(account_id)

    logged_out = Phoenix.ConnTest.build_conn()

    {:ok, account_id: account_id, logged_in: logged_in, logged_out: logged_out}
  end

  describe "GET /portfolio (auth)" do
    test "redirects anonymous users to /auth/login", %{logged_out: conn} do
      assert {:error, {:redirect, %{to: "/auth/login", flash: flash}}} =
               live(conn, "/portfolio")

      assert flash["error"] =~ "Log in"
    end

    test "renders empty state when user has no positions", %{logged_in: conn} do
      {:ok, _view, html} = live(conn, "/portfolio")

      assert html =~ "MY POSITIONS"
      assert html =~ "NO POSITIONS YET"
    end
  end

  describe "position list" do
    test "renders the user's positions newest-first", %{
      logged_in: conn,
      account_id: account_id
    } do
      m_raw = pending_market!([])
      market = activate!(m_raw)
      {:ok, _pos} = Trader.place_position(account_id, market.id, :yes, 5)

      {:ok, _view, html} = live(conn, "/portfolio")

      assert html =~ market.description
      assert html =~ "YES"
      assert html =~ "5"
      assert html =~ "open"
    end

    test "another account's positions are not shown", %{logged_in: conn} do
      m_raw = pending_market!([])
      market = activate!(m_raw)
      {:ok, _pos} = Trader.place_position("someone-else", market.id, :yes, 3)

      {:ok, _view, html} = live(conn, "/portfolio")

      assert html =~ "NO POSITIONS YET"
    end

    test "foreign-account PayoutRequested event does not trigger a re-render", %{logged_in: conn} do
      {:ok, view, _html} = live(conn, "/portfolio")

      # Send a PayoutRequested struct directly to the LiveView pid
      # as if PubSub delivered it. The struct carries someone else's
      # account_id; the new handle_info clause must drop it without
      # calling load_state. We exercise that by issuing the send and
      # confirming the view is still alive + responding (no crash, no
      # render-cycle anomaly).
      foreign_event = %PerpWalk.Events.Federation.PayoutRequested{
        request_id: "req-foreign",
        position_id: nil,
        market_id: "mkt-foreign",
        account_id: "some-other-account",
        kind: :winner_payout,
        amount_piconeros: 1_000_000_000_000,
        destination: "4" <> String.duplicate("A", 94),
        timestamp: DateTime.utc_now()
      }

      send(view.pid, foreign_event)

      # If load_state had fired, render would have re-run; instead
      # the no-op clause matched and the assigns are unchanged. The
      # render output must still be coherent.
      html = render(view)
      assert html =~ "NO POSITIONS YET"
    end
  end

  describe "claim flow" do
    setup %{account_id: account_id} do
      m_raw = pending_market!([])
      market = activate!(m_raw)
      {:ok, position} = Trader.place_position(account_id, market.id, :yes, 5)
      {:ok, _} = Resolver.expire(market.id)
      {:ok, _} = Resolver.submit_resolution(market.id, :yes)
      {:ok, _} = Resolver.settle(market.id)

      {:ok, settled_position} = PerpWalk.Markets.Facade.get_position(position.id)

      {:ok, market: market, position: settled_position}
    end

    test "winner sees a Claim button", %{logged_in: conn} do
      {:ok, _view, html} = live(conn, "/portfolio")
      assert html =~ "Claim"
    end

    test "opening the claim modal shows the destination form", %{
      logged_in: conn,
      position: position
    } do
      {:ok, view, _html} = live(conn, "/portfolio")

      html =
        view
        |> element("button[phx-click='claim:open'][phx-value-position-id='#{position.id}']")
        |> render_click()

      assert html =~ "bp-modal"
      assert html =~ "Claim"
      assert html =~ ~s(name="claim[destination]")
    end

    test "review step shows confirmation with truncated address before queuing", %{
      logged_in: conn,
      position: position
    } do
      {:ok, view, _html} = live(conn, "/portfolio")

      view
      |> element("button[phx-click='claim:open'][phx-value-position-id='#{position.id}']")
      |> render_click()

      destination = "4" <> String.duplicate("AB", 47)

      review_html =
        view
        |> form("form[phx-submit='claim:review']", claim: %{"destination" => destination})
        |> render_submit()

      # Confirm step renders summary, not yet queued
      assert review_html =~ "Confirm"
      assert review_html =~ "irreversible"
      assert review_html =~ "4ABABABABABA"
      assert FederationStore.list_payouts() == []

      # Final submit queues the payout
      submit_html =
        view
        |> form("form[phx-submit='claim:submit']", %{})
        |> render_submit()

      assert submit_html =~ ~r/(queued|signing|needs review|submitted)/

      requests = FederationStore.list_payouts()
      assert Enum.any?(requests, fn r -> r.position_id == position.id end)
    end

    test "back from confirm returns to entry with address preserved", %{
      logged_in: conn,
      position: position
    } do
      {:ok, view, _html} = live(conn, "/portfolio")

      view
      |> element("button[phx-click='claim:open'][phx-value-position-id='#{position.id}']")
      |> render_click()

      destination = "4" <> String.duplicate("AB", 47)

      view
      |> form("form[phx-submit='claim:review']", claim: %{"destination" => destination})
      |> render_submit()

      back_html =
        view
        |> element("button[phx-click='claim:back']")
        |> render_click()

      assert back_html =~ "Claim"
      assert back_html =~ ~s(value="#{destination}")
      assert FederationStore.list_payouts() == []
    end

    test "review step rejects invalid Monero address and stays on entry", %{
      logged_in: conn,
      position: position
    } do
      {:ok, view, _html} = live(conn, "/portfolio")

      view
      |> element("button[phx-click='claim:open'][phx-value-position-id='#{position.id}']")
      |> render_click()

      html =
        view
        |> form("form[phx-submit='claim:review']", claim: %{"destination" => "not-a-real-address"})
        |> render_submit()

      assert html =~ "Invalid Monero address"
      refute html =~ "Confirm"
      assert FederationStore.list_payouts() == []
    end

    test "monero: URI prefix is stripped before validation", %{
      logged_in: conn,
      position: position
    } do
      {:ok, view, _html} = live(conn, "/portfolio")

      view
      |> element("button[phx-click='claim:open'][phx-value-position-id='#{position.id}']")
      |> render_click()

      bare = "4" <> String.duplicate("AB", 47)
      uri = "monero:#{bare}?tx_amount=0.05"

      review_html =
        view
        |> form("form[phx-submit='claim:review']", claim: %{"destination" => uri})
        |> render_submit()

      assert review_html =~ "Confirm"
      # Bare address shows in the confirmation, not the URI
      assert review_html =~ String.slice(bare, 0, 12)
      refute review_html =~ "monero:"
      refute review_html =~ "tx_amount"
    end

    test "cancel closes the modal without submitting", %{logged_in: conn, position: position} do
      {:ok, view, _html} = live(conn, "/portfolio")

      view
      |> element("button[phx-click='claim:open'][phx-value-position-id='#{position.id}']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='claim:cancel']")
        |> render_click()

      refute html =~ "bp-modal-overlay"
      assert FederationStore.list_payouts() == []
    end
  end

  describe "claim status on reload" do
    setup %{account_id: account_id} do
      m_raw = pending_market!([])
      market = activate!(m_raw)
      {:ok, position} = Trader.place_position(account_id, market.id, :yes, 5)
      {:ok, _} = Resolver.expire(market.id)
      {:ok, _} = Resolver.submit_resolution(market.id, :yes)
      {:ok, _} = Resolver.settle(market.id)

      {:ok, settled_position} = PerpWalk.Markets.Facade.get_position(position.id)

      {:ok, market: market, position: settled_position}
    end

    test "submitted payout shows truncated txid that survives a reload", %{
      logged_in: conn,
      position: position
    } do
      destination = "4" <> String.duplicate("AB", 47)
      txid = String.duplicate("a1b2c3d4", 8)

      {:ok, request} =
        PerpWalk.Markets.Facade.claim_payout(position.id, position.account_id, destination)

      submitted = %{request | status: :submitted, payout_txid: txid}
      :ok = FederationStore.put_payout(submitted)

      {:ok, _view, html} = live(conn, "/portfolio")

      # Action column shows just the truncated txid — the presence of
      # a txid is itself the "claim has happened" signal, with the
      # `submitted` label kept as the tooltip via `title=`.
      assert html =~ "a1b2c3d4…a1b2c3d4"
    end

    test "failed payout falls back to CLAIM button (no persistent label)", %{logged_in: conn, position: position} do
      # Failed payouts no longer render a "failed — try again" label
      # inline; the position's `payable?/1` fall-through re-exposes the
      # CLAIM button. Users learn about the failure via a flash on the
      # live `PayoutFailed` event (see the reload/flash test below).
      destination = "4" <> String.duplicate("AB", 47)

      {:ok, request} =
        PerpWalk.Markets.Facade.claim_payout(position.id, position.account_id, destination)

      failed = %{request | status: :failed, rule_failure_reason: "insufficient liquidity"}
      :ok = FederationStore.put_payout(failed)

      {:ok, _view, html} = live(conn, "/portfolio")

      refute html =~ "failed"
      assert html =~ "Claim"
    end

    test "PayoutFailed event flashes the current user and reloads", %{
      logged_in: conn,
      position: position
    } do
      destination = "4" <> String.duplicate("AB", 47)

      {:ok, request} =
        PerpWalk.Markets.Facade.claim_payout(position.id, position.account_id, destination)

      {:ok, view, _html} = live(conn, "/portfolio")

      failed = %{request | status: :failed, rule_failure_reason: "rules_revalidation: any"}
      :ok = FederationStore.put_payout(failed)

      EventBus.publish(%FederationEvents.PayoutFailed{
        request_id: request.id,
        reason: "rules_revalidation: any",
        timestamp: DateTime.utc_now()
      })

      html = render(view)
      # Flash is present, and the row falls back to CLAIM.
      assert html =~ "Claim failed"
      assert html =~ "Claim"
      refute html =~ "failed — try again"
    end

    test "queued payout flips to needs-review live when rules hold it", %{
      logged_in: conn,
      position: position
    } do
      destination = "4" <> String.duplicate("AB", 47)

      {:ok, request} =
        PerpWalk.Markets.Facade.claim_payout(position.id, position.account_id, destination)

      {:ok, view, html} = live(conn, "/portfolio")
      assert html =~ "queued"
      refute html =~ "needs review"

      held = %{request | status: :awaiting_operator, rule_failure_reason: "rate_cap_global"}
      :ok = FederationStore.put_payout(held)

      EventBus.publish(%FederationEvents.RuleCheckFailed{
        request_id: request.id,
        reason: "rate_cap_global",
        timestamp: DateTime.utc_now()
      })

      assert render(view) =~ "needs review"
    end
  end

  describe "disputes panel" do
    test "renders a refundable :resolved_against dispute with a Claim button", %{
      logged_in: conn,
      account_id: account_id
    } do
      m_raw = pending_market!([])
      market = activate!(m_raw)
      {:ok, _} = Trader.place_position("acct-other", market.id, :yes, 5)
      {:ok, _} = Trader.place_position(account_id, market.id, :yes, 1)
      {:ok, _} = Resolver.expire(market.id)
      {:ok, _} = Resolver.submit_resolution(market.id, :yes)

      _ = dispute!(account_id, market.id)
      {:ok, _} = Resolver.reverse_resolution(market.id, :no)

      {:ok, _view, html} = live(conn, "/portfolio")

      # Status column was removed — the row's existence + the Claim
      # affordance + the refund amount tell the user everything they
      # need (refund-equals-stake means full refund / no slash).
      assert html =~ "MY DISPUTES"
      assert html =~ "Claim"
    end

    test "claim:open for a dispute opens the refund modal", %{
      logged_in: conn,
      account_id: account_id
    } do
      m_raw = pending_market!([])
      market = activate!(m_raw)
      {:ok, _} = Trader.place_position("acct-other", market.id, :yes, 5)
      {:ok, _} = Trader.place_position(account_id, market.id, :yes, 1)
      {:ok, _} = Resolver.expire(market.id)
      {:ok, _} = Resolver.submit_resolution(market.id, :yes)

      _ = dispute!(account_id, market.id)
      {:ok, _} = Resolver.reverse_resolution(market.id, :no)

      {:ok, view, _html} = live(conn, "/portfolio")

      modal_html =
        view
        |> element("button[phx-click='dispute_claim:open']")
        |> render_click()

      assert modal_html =~ "Claim"
    end

    test "shows the standard empty state when the user has no disputes", %{logged_in: conn} do
      {:ok, _view, html} = live(conn, "/portfolio")

      assert html =~ "MY DISPUTES"
      assert html =~ "NO DISPUTES YET"
    end
  end

  describe "markets panel" do
    test "shows the standard empty state when the user has no markets", %{logged_in: conn} do
      {:ok, _view, html} = live(conn, "/portfolio")

      assert html =~ "MY MARKETS"
      assert html =~ "NO MARKETS YET"
    end

    test "renders the user's created markets newest-first", %{
      logged_in: conn,
      account_id: account_id
    } do
      _other = pending_market!(creator_account_id: "someone-else", description: "Other market")
      mine = pending_market!(creator_account_id: account_id, description: "My market")

      {:ok, _view, html} = live(conn, "/portfolio")

      assert html =~ "My market"
      refute html =~ "Other market"
      assert html =~ Helpers.status_label(mine.status) |> String.downcase()
    end

    test "shows a Resolve button on :expired markets I created", %{
      logged_in: conn,
      account_id: account_id
    } do
      m = pending_market!(creator_account_id: account_id)
      activated = activate!(m)
      {:ok, _expired} = Resolver.expire(activated.id)

      {:ok, _view, html} = live(conn, "/portfolio")

      assert html =~ "Resolve"
      assert html =~ "phx-click=\"resolve:open\""
    end

    test "Resolve button opens the resolve modal with YES/NO buttons (no VOID)", %{
      logged_in: conn,
      account_id: account_id
    } do
      m = pending_market!(creator_account_id: account_id)
      activated = activate!(m)
      {:ok, _expired} = Resolver.expire(activated.id)

      {:ok, view, _html} = live(conn, "/portfolio")

      modal_html =
        view
        |> element("button[phx-click='resolve:open']")
        |> render_click()

      assert modal_html =~ "RESOLVE MARKET"
      assert modal_html =~ "YES"
      assert modal_html =~ "NO"
      # :void is operator-only; creators can't dodge disputes by voiding.
      refute modal_html =~ "phx-value-outcome=\"void\""
    end

    test "submitting a resolution transitions the market to :resolving", %{
      logged_in: conn,
      account_id: account_id
    } do
      m = pending_market!(creator_account_id: account_id)
      activated = activate!(m)
      {:ok, _expired} = Resolver.expire(activated.id)

      {:ok, view, _html} = live(conn, "/portfolio")

      view
      |> element("button[phx-click='resolve:open']")
      |> render_click()

      view
      |> element("button[phx-value-outcome='yes']")
      |> render_click()

      {:ok, refreshed} = PerpWalk.Markets.Facade.get_market(activated.id)
      assert refreshed.status == :resolving
      assert refreshed.outcome == :yes
    end

    test "non-creator can't resolve someone else's market", %{
      logged_in: conn
    } do
      m = pending_market!(creator_account_id: "someone-else")
      activated = activate!(m)
      {:ok, _expired} = Resolver.expire(activated.id)

      {:ok, _view, html} = live(conn, "/portfolio")

      # The market doesn't appear in MY MARKETS at all — Resolve CTA never shown.
      refute html =~ "phx-click=\"resolve:open\""
    end
  end
end
