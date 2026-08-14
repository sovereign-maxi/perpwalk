defmodule PerpWalkWeb.MarketLive do
  @moduledoc """
  Per-market detail view at `/markets/:id`. Shows the market's
  identifying meta (description, category, status, expiry,
  creator), AMM state via the OddsChart, the audit-trail trades
  feed, and — when the viewer is logged in and the market is
  active — Buy YES / Buy NO buttons that open a deposit modal
  with a fresh quote.

  Subscribes to per-market events scoped via the EventBus
  per-instance topic so updates only flow for the market
  currently displayed.

  ## Trade modal

  The Trade panel has a contracts stepper and two Buy buttons. The
  stepper drives a live cost preview on each side via
  `Facade.quote_breakdown/3` — no Quote / subaddress is allocated
  until the user clicks Buy. A click creates a Quote with the
  selected contract count and renders a modal with the deposit
  subaddress, QR, and countdown. Cancel / click-away / timer
  expiry dismiss without committing anything. A `QuoteFilled`
  event matching the open quote auto-closes the modal with a
  success flash.

  We deliberately do NOT pre-generate quotes on mount — every
  page view would otherwise burn two wallet subaddresses and
  pollute the WAL with quotes that mostly never fill.
  """

  use PerpWalkWeb, :live_view

  alias PerpWalk.Crypto.Schnorr
  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Identity.Facade, as: IdentityFacade
  alias PerpWalk.Markets.Facade
  alias PerpWalk.Nostr.Facade, as: NostrFacade
  alias PerpWalkWeb.Live.Components.{Badges, Modal, OddsChart}
  alias PerpWalkWeb.Live.Helpers
  alias PerpWalkWeb.Live.RateLimit
  alias PerpWalkWeb.Live.RateLimit.Shared, as: SharedRateLimit
  alias PerpWalkWeb.Messages

  @tick_ms 1_000
  @default_contracts 1
  @max_contracts_typed 100_000

  # Cap on the number of comments rendered in a single market detail
  # view. The Inbox caps at 500 per-market; the LiveView trims
  # further so the rendered list stays scannable. Older comments are
  # still reachable from Nostr; this is purely a render budget.
  @comment_render_cap 200

  # Server-side ceiling on the comment draft assign. Matches the
  # Inbox's per-comment content cap so a draft can never exceed what
  # a submitted comment could carry.
  @max_comment_draft_bytes 5_000

  @per_instance_events [
    MarketsEvents.MarketDepositObserved,
    MarketsEvents.MarketDepositConfirmed,
    MarketsEvents.MarketActivated,
    MarketsEvents.MarketRejected,
    MarketsEvents.MarketExpired,
    MarketsEvents.MarketSettled,
    MarketsEvents.MarketVoided,
    MarketsEvents.PositionOpened,
    MarketsEvents.QuoteFilled,
    MarketsEvents.QuoteDepositObserved,
    MarketsEvents.QuoteUnderpaid,
    MarketsEvents.ResolutionSubmitted,
    MarketsEvents.ResolutionReversed,
    MarketsEvents.DisputeDepositObserved,
    MarketsEvents.DisputeFlagged,
    MarketsEvents.DisputeReReviewTriggered,
    MarketsEvents.DisputesAcknowledged,
    MarketsEvents.CommentReceived
  ]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Facade.get_market(id) do
      {:ok, market} ->
        if connected?(socket) do
          subscribe_per_market(market.id)
          Helpers.subscribe_to_pip_events()
          schedule_tick()
        end

        {:ok,
         socket
         |> assign(:page_title, Messages.page_title_market())
         |> assign(:market_id, market.id)
         |> assign(:active_trade, nil)
         |> assign(:active_dispute, nil)
         |> assign(:contracts, @default_contracts)
         |> assign(:comment_draft, "")
         |> assign(:current_nostr_handle, compute_nostr_handle(socket))
         |> assign(:market_deposit_observed, false)
         |> assign(:health, Helpers.fetch_footer_health())
         |> load_state()}

      {:error, :not_found} ->
        {:ok,
         socket
         |> assign(:page_title, Messages.page_title_market_not_found())
         |> assign(:market_id, id)
         |> assign(:not_found, true)
         |> assign(:health, Helpers.fetch_footer_health())}
    end
  end

  # --- Trade Events ---

  @impl true
  def handle_event("trade:open", %{"side" => side}, socket)
      when side in ["yes", "no"] do
    if trading_open?(socket.assigns) do
      side_atom = String.to_existing_atom(side)

      # Two-step modal: first collect the refund address, then create
      # the quote. Deferring quote creation until step-1 submission
      # means no subaddress is allocated (and no capital commitment
      # is signalled) if the user backs out of the address prompt.
      {:noreply,
       assign(socket, :active_trade, %{
         step: :refund_address,
         side: side_atom,
         refund_address: ""
       })}
    else
      {:noreply, put_flash(socket, :error, trading_closed_message(socket.assigns))}
    end
  end

  def handle_event("trade:refund_address_submit", %{"refund_address" => addr}, socket)
      when is_binary(addr) do
    account_id = socket.assigns[:current_account_id]
    trimmed = String.trim(addr)

    with :ok <- RateLimit.check(:trade_open),
         :ok <- SharedRateLimit.check(account_id, :trade_open),
         %{step: :refund_address, side: side_atom} <- socket.assigns.active_trade do
      case build_quote(socket, side_atom, trimmed) do
        {:ok, quote} ->
          {:noreply,
           assign(socket, :active_trade, %{
             step: :deposit,
             side: side_atom,
             quote: quote,
             refund_address: trimmed
           })}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, trade_error_message(reason))
           |> assign(:active_trade, %{
             step: :refund_address,
             side: side_atom,
             refund_address: trimmed
           })}
      end
    else
      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, Messages.rate_limited(:trade))}

      _mismatch ->
        {:noreply, socket}
    end
  end

  def handle_event("trade:close", _params, socket) do
    {:noreply, assign(socket, :active_trade, nil)}
  end

  def handle_event("contracts:inc", _params, socket) do
    {:noreply, set_contracts(socket, socket.assigns.contracts + 1)}
  end

  def handle_event("contracts:dec", _params, socket) do
    {:noreply, set_contracts(socket, socket.assigns.contracts - 1)}
  end

  def handle_event("contracts:set", %{"contracts" => value}, socket) do
    {:noreply, set_contracts(socket, parse_contracts(value))}
  end

  # --- Listing Vote ---

  def handle_event("vote", %{"direction" => direction}, socket)
      when direction in ["up", "down"] do
    account_id = socket.assigns[:current_account_id]

    with :ok <- SharedRateLimit.check(account_id, :vote),
         :ok <- RateLimit.check(:vote) do
      {:noreply, do_vote(socket, String.to_existing_atom(direction))}
    else
      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, Messages.rate_limited(:vote))}
    end
  end

  def handle_event("dispute:flag", _params, socket) do
    account_id = socket.assigns[:current_account_id]

    with :ok <- SharedRateLimit.check(account_id, :dispute_open),
         :ok <- RateLimit.check(:dispute_open) do
      {:noreply, do_flag_dispute(socket)}
    else
      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, Messages.rate_limited(:dispute))}
    end
  end

  def handle_event("dispute:close", _params, socket) do
    {:noreply, close_active_dispute(socket)}
  end

  def handle_event("resolve", %{"outcome" => outcome}, socket)
      when outcome in ["yes", "no"] do
    account_id = socket.assigns[:current_account_id]

    with :ok <- SharedRateLimit.check(account_id, :resolve_submit),
         :ok <- RateLimit.check(:resolve_submit) do
      {:noreply, do_submit_resolution(socket, String.to_existing_atom(outcome))}
    else
      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, Messages.rate_limited(:resolution))}
    end
  end

  # --- Comments ---

  def handle_event("comment:draft", %{"comment" => %{"content" => content}}, socket)
      when is_binary(content) do
    # Drafts fire per keystroke over the WebSocket. Cap the size so
    # a forged client can't shove unbounded payloads into socket
    # assigns (each keystroke re-diffs the assign tree), and bound
    # the rate so a scripted client can't spin the event loop. A
    # tripped limit just skips the server-side draft update — the
    # user's in-progress input is untouched client-side.
    if byte_size(content) <= @max_comment_draft_bytes and RateLimit.check(:comment_draft) == :ok do
      {:noreply, assign(socket, :comment_draft, content)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("comment:submit", %{"comment" => %{"content" => content}}, socket)
      when is_binary(content) do
    account_id = socket.assigns[:current_account_id]

    # Per-socket bucket trips first (UX-friendly), but the shared
    # account-scoped bucket is the hard cap that survives an
    # attacker rotating Tor circuits to open many sockets under the
    # same account.
    with :ok <- RateLimit.check(:comment_submit),
         :ok <- SharedRateLimit.check(account_id, :comment_submit) do
      {:noreply, do_post_comment(socket, content)}
    else
      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, Messages.rate_limited(:comment))}
    end
  end

  # Catch-all so a forged client frame for an event this LiveView
  # doesn't recognise becomes a silent no-op rather than a process
  # crash that tears down the WebSocket.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp do_post_comment(socket, content) do
    market_id = socket.assigns.market_id
    session_id = socket.assigns[:session_id]
    account_id = socket.assigns[:current_account_id]

    cond do
      is_nil(account_id) ->
        put_flash(socket, :error, Messages.login_required(:comment))

      is_nil(session_id) ->
        put_flash(socket, :error, Messages.comment_session_expired())

      true ->
        with {:ok, seckey} <- IdentityFacade.lookup_nostr_seckey(session_id),
             {:ok, venue_pubkey} <- NostrFacade.venue_pubkey(),
             {:ok, _result} <-
               Facade.publish_comment(seckey, venue_pubkey, market_id, content) do
          socket
          |> assign(:comment_draft, "")
          |> load_comments()
          |> put_flash(:info, Messages.comment_posted())
        else
          {:error, :no_nostr_key} ->
            put_flash(socket, :error, Messages.comment_keyphrase_required())

          {:error, :not_available} ->
            put_flash(socket, :error, Messages.comment_signer_offline())

          {:error, :empty_content} ->
            put_flash(socket, :error, Messages.comment_empty())

          {:error, :content_too_long} ->
            put_flash(socket, :error, Messages.comment_too_long())

          {:error, _reason} ->
            put_flash(socket, :error, Messages.comment_failed())
        end
    end
  end

  defp do_vote(socket, direction) do
    case socket.assigns[:current_account_id] do
      nil ->
        put_flash(socket, :error, Messages.login_required(:vote))

      account_id when is_binary(account_id) ->
        cast_vote(socket, account_id, direction)
    end
  end

  defp cast_vote(socket, account_id, direction) do
    case Facade.cast_vote(account_id, socket.assigns.market_id, direction) do
      {:ok, _market} ->
        socket
        |> put_flash(:info, Messages.voted(direction))
        |> load_state()

      {:error, :creator_cannot_vote} ->
        put_flash(socket, :error, Messages.creator_cannot_vote())

      {:error, :market_not_pending} ->
        put_flash(socket, :error, Messages.voting_closed())

      {:error, :market_not_found} ->
        put_flash(socket, :error, Messages.market_not_found())
    end
  rescue
    PerpWalk.Guards.SystemHaltedError ->
      put_flash(socket, :error, Messages.venue_halted())
  end

  defp do_flag_dispute(socket) do
    case socket.assigns[:current_account_id] do
      nil ->
        put_flash(socket, :error, Messages.login_required(:dispute))

      account_id when is_binary(account_id) ->
        start_dispute(socket, account_id)
    end
  end

  defp start_dispute(socket, account_id) do
    case Facade.start_dispute(account_id, socket.assigns.market_id) do
      {:ok, dispute} ->
        socket
        |> assign(:active_dispute, dispute)
        |> load_state()

      {:error, :market_not_resolving} ->
        put_flash(socket, :error, Messages.market_not_in_dispute_window())

      {:error, :market_not_found} ->
        put_flash(socket, :error, Messages.market_not_found())

      {:error, :creator_cannot_dispute_own_market} ->
        put_flash(socket, :error, Messages.creator_cannot_dispute())

      {:error, :must_have_traded_on_market} ->
        put_flash(socket, :error, Messages.only_traders_can_dispute())

      {:error, {:subaddress_provider_failed, _reason}} ->
        put_flash(socket, :error, Messages.cannot_allocate_address())
    end
  rescue
    PerpWalk.Guards.SystemHaltedError ->
      put_flash(socket, :error, Messages.venue_halted())
  end

  defp do_submit_resolution(socket, outcome) do
    case socket.assigns[:current_account_id] do
      nil ->
        put_flash(socket, :error, Messages.login_required(:resolve))

      account_id when is_binary(account_id) ->
        submit_creator_resolution(socket, account_id, outcome)
    end
  end

  defp submit_creator_resolution(socket, account_id, outcome) do
    case Facade.submit_resolution(account_id, socket.assigns.market_id, outcome) do
      {:ok, _market} ->
        socket
        |> put_flash(:info, Messages.resolution_submitted_long(outcome))
        |> load_state()

      {:error, :not_creator} ->
        put_flash(socket, :error, Messages.only_creator_can_submit_resolution())

      {:error, :invalid_transition} ->
        put_flash(socket, :error, Messages.market_not_awaiting_resolution())

      {:error, :market_not_found} ->
        put_flash(socket, :error, Messages.market_not_found())
    end
  rescue
    PerpWalk.Guards.SystemHaltedError ->
      put_flash(socket, :error, Messages.venue_halted())
  end

  # --- Lifecycle Events ---

  @impl true
  def handle_info(:tick, socket) do
    schedule_tick()

    {:noreply,
     socket
     |> assign(:now, DateTime.utc_now())
     |> close_if_active_quote_expired()}
  end

  def handle_info(%MarketsEvents.QuoteFilled{} = event, socket) do
    socket =
      if Map.get(event, :market_id) == socket.assigns.market_id do
        load_state(socket)
      else
        socket
      end

    {:noreply, close_if_active_quote_filled(socket, event)}
  end

  def handle_info(%MarketsEvents.QuoteDepositObserved{quote_id: quote_id}, socket) do
    {:noreply, mark_active_trade_payment_observed(socket, quote_id)}
  end

  def handle_info(%MarketsEvents.QuoteUnderpaid{} = event, socket) do
    {:noreply, mark_active_trade_underpaid(socket, event)}
  end

  def handle_info(%MarketsEvents.MarketDepositObserved{market_id: mid}, socket) do
    if mid == socket.assigns.market_id do
      {:noreply, assign(socket, :market_deposit_observed, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%MarketsEvents.DisputeDepositObserved{} = event, socket) do
    {:noreply, mark_active_dispute_payment_observed(socket, event)}
  end

  def handle_info(%MarketsEvents.DisputeFlagged{} = event, socket) do
    socket =
      if Map.get(event, :market_id) == socket.assigns.market_id do
        load_state(socket)
      else
        socket
      end

    {:noreply, close_if_active_dispute_funded(socket, event)}
  end

  def handle_info(%MarketsEvents.CommentReceived{market_id: mid}, socket) do
    if mid == socket.assigns.market_id do
      {:noreply, load_comments(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(msg, socket) do
    case Helpers.handle_pip_event(msg, socket) do
      :pass ->
        if is_struct(msg) and Map.get(msg, :market_id) == socket.assigns.market_id do
          {:noreply, load_state(socket)}
        else
          {:noreply, socket}
        end

      handled ->
        handled
    end
  end

  # --- Internal ---

  # Subscribes to the base topic for each event so we receive the
  # broadcasts that publishers emit via EventBus.publish/1 (no
  # per-instance suffix). The catch-all handle_info filters by
  # market_id before triggering a re-render, so cross-market events
  # are still cheap dropped messages — they're not state mutations.
  defp subscribe_per_market(_market_id) do
    for event_module <- @per_instance_events do
      EventBus.subscribe(event_module)
    end
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  # The OddsChart's right edge is clamped to `expiry` so the chart
  # never extends past when trading actually stopped. While the
  # market is `:active`, wall-clock `now` is before expiry and the
  # chart tracks live. The instant the market expires (and through
  # `:resolving` / `:settled` / `:voided` / `:rejected` afterwards),
  # the chart freezes at the expiry timestamp — the trade history
  # IS the market's story, and the story ends at expiry.
  defp chart_now(_market, nil), do: nil

  defp chart_now(%{expiry: %DateTime{} = expiry}, %DateTime{} = now) do
    if DateTime.compare(now, expiry) == :gt, do: expiry, else: now
  end

  defp chart_now(_market, %DateTime{} = now), do: now

  defp build_quote(socket, side, refund_address) do
    account_id = socket.assigns[:current_account_id]
    market_id = socket.assigns.market_id
    contracts = socket.assigns.contracts

    Facade.create_quote(
      account_id,
      market_id,
      side,
      contracts,
      quote_opts() ++ [refund_address: refund_address]
    )
  rescue
    # Covers the race where a peer drops between the trading_open?/1
    # pre-check and the service call.
    PerpWalk.Guards.SystemHaltedError -> {:error, :halted}
  end

  # Translates Facade.create_quote/5 error reasons into user-facing flash
  # messages. The cases that name a specific failure mode (system halt,
  # Monero RPC) are load-bearing for §10 testing — retry won't help when
  # the protocol itself is degraded, and the user needs to know that.
  defp trade_error_message(:halted),
    do: Messages.venue_halted()

  defp trade_error_message({:subaddress_provider_failed, _}),
    do: Messages.deposit_provider_offline()

  defp trade_error_message(:market_not_active),
    do: Messages.market_no_longer_active()

  defp trade_error_message(:market_not_found),
    do: Messages.market_not_found()

  defp trade_error_message(:insufficient_liquidity),
    do: Messages.insufficient_liquidity()

  defp trade_error_message(:creator_cannot_trade_own_market),
    do: Messages.creator_cannot_trade()

  defp trade_error_message(:refund_address_required),
    do: Messages.refund_address_required()

  defp trade_error_message(:refund_address_invalid),
    do: Messages.refund_address_invalid()

  # Catch-all so an unmapped reason from the service layer
  # (`:wal_overloaded` under back-pressure, future error atoms)
  # surfaces as a friendly flash rather than a FunctionClauseError
  # that would crash the LiveView.
  defp trade_error_message(_other), do: Messages.trade_failed_generic()

  # When trading_open?/1 returns false, the cause is either a logged-out
  # viewer, a non-active market, or a halted venue. Surface the specific
  # reason so the user knows whether to log in, wait, or try a different
  # market.
  defp trading_closed_message(assigns) do
    cond do
      is_nil(Map.get(assigns, :current_account_id)) ->
        Messages.login_required(:trade)

      PerpWalk.Guards.halted?() ->
        Messages.venue_halted()

      true ->
        Messages.trading_closed_for_market()
    end
  end

  defp parse_contracts(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> @default_contracts
    end
  end

  defp parse_contracts(value) when is_integer(value), do: value
  defp parse_contracts(_), do: @default_contracts

  # Clamps to [1, max_typed]. Liquidity bounds are enforced server-side
  # at quote creation; the typed cap just stops absurd values from
  # producing 5-figure round-trips on the stepper.
  defp set_contracts(socket, value) do
    clamped = value |> max(1) |> min(@max_contracts_typed)

    socket
    |> assign(:contracts, clamped)
    |> assign_quote_preview()
  end

  defp assign_quote_preview(socket) do
    case socket.assigns[:market] do
      %{pool: pool, unit_size: unit_size} ->
        contracts = socket.assigns.contracts

        assign(socket, :quote_preview, %{
          yes: side_preview(pool, :yes, contracts, unit_size),
          no: side_preview(pool, :no, contracts, unit_size)
        })

      _ ->
        assign(socket, :quote_preview, %{yes: {:error, :market_not_loaded}, no: {:error, :market_not_loaded}})
    end
  end

  defp side_preview(pool, side, contracts, unit_size) do
    case Facade.quote_breakdown(pool, side, Facade.contracts_to_subunits(contracts)) do
      {:ok, %{cost: cost_subunits}} -> {:ok, Facade.subunits_to_piconeros(cost_subunits, unit_size)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp quote_opts do
    case Application.get_env(:perpwalk, :subaddress_provider) do
      nil ->
        []

      fun when is_function(fun, 0) ->
        [subaddress_provider: fun]

      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        [subaddress_provider: fn -> apply(mod, fun, args) end]
    end
  end

  defp close_if_active_quote_expired(%{assigns: %{active_trade: nil}} = socket), do: socket

  # Once the deposit is observed (mempool or pre-confirmation), the
  # quote is structurally locked in — the fill happens at the next
  # confirmation regardless of the clock. Don't kill the modal even
  # if the quote's nominal expiry has technically passed.
  defp close_if_active_quote_expired(%{assigns: %{active_trade: %{payment_observed: true}}} = socket),
    do: socket

  defp close_if_active_quote_expired(%{assigns: %{active_trade: %{quote: quote}}} = socket) do
    if DateTime.compare(socket.assigns.now, quote.expires_at) == :lt do
      socket
    else
      socket
      |> assign(:active_trade, nil)
      |> put_flash(:info, Messages.quote_expired_info())
    end
  end

  # Refund-address entry step has no quote yet, so no expiry to check.
  defp close_if_active_quote_expired(socket), do: socket

  defp close_if_active_quote_filled(%{assigns: %{active_trade: nil}} = socket, _event), do: socket

  defp close_if_active_quote_filled(%{assigns: %{active_trade: %{quote: %{id: id}}}} = socket, %{
         quote_id: id
       }) do
    socket
    |> assign(:active_trade, nil)
    |> put_flash(:success, Messages.position_confirmed())
  end

  defp close_if_active_quote_filled(socket, _event), do: socket

  # Flips `active_trade.payment_observed` to true when the deposit
  # for the open quote is observed (mempool / pre-confirmation).
  # Captures `payment_observed_at` once so the header timer can
  # freeze at the value it had at detection rather than continuing
  # to tick toward an expiry that no longer applies. The modal also
  # uses `payment_observed` to grey out the QR.
  defp mark_active_trade_payment_observed(
         %{assigns: %{active_trade: %{quote: %{id: id}} = trade}} = socket,
         id
       ) do
    trade =
      trade
      |> Map.put(:payment_observed, true)
      |> Map.put_new(:payment_observed_at, DateTime.utc_now())

    assign(socket, :active_trade, trade)
  end

  defp mark_active_trade_payment_observed(socket, _quote_id), do: socket

  # Flips `active_dispute.payment_observed` to true when the deposit
  # for the open dispute stake is observed (mempool / pre-confirmation).
  # The modal uses `payment_observed` to grey out the QR and surface
  # the "payment detected" indicator, matching the trade and liquidity
  # modals. The auto-close path is separate — `DisputeFlagged` (which
  # fires after the deposit is fully confirmed and the dispute
  # committed to the Store) tears the modal down via
  # `close_if_active_dispute_funded/2`.
  defp mark_active_dispute_payment_observed(
         %{assigns: %{active_dispute: %{account_id: aid, market_id: mid} = dispute}} = socket,
         %{account_id: aid, market_id: mid}
       ) do
    assign(socket, :active_dispute, Map.put(dispute, :payment_observed, true))
  end

  defp mark_active_dispute_payment_observed(socket, _event), do: socket

  # Flips `active_trade` into the `:underpaid` step when a QuoteUnderpaid
  # event lands for the currently-open modal. The modal shows the
  # amount received vs expected and confirms the refund is coming to
  # the address the user provided at step 1.
  defp mark_active_trade_underpaid(
         %{assigns: %{active_trade: %{quote: %{id: id}} = trade}} = socket,
         %{quote_id: id} = event
       ) do
    updated =
      trade
      |> Map.put(:step, :underpaid)
      |> Map.put(:underpaid, %{
        amount_paid_piconeros: event.amount_paid_piconeros,
        amount_expected_piconeros: event.amount_expected_piconeros
      })

    assign(socket, :active_trade, updated)
  end

  defp mark_active_trade_underpaid(socket, _event), do: socket

  # Truthy when the viewer is logged in, the market is active, AND
  # the federation has quorum. Gates the actual quote-creation
  # `handle_event("trade:open")`. Takes raw assigns so it works as a
  # HEEX predicate too. The halt check matches the gate in
  # `PerpWalk.Guards.ensure_operational!/0` — disabling the Buy
  # buttons while halted is the user-facing pair of that server-side
  # refusal.
  defp trading_open?(assigns) do
    market_active?(assigns) and not is_nil(Map.get(assigns, :current_account_id)) and
      not viewer_is_creator?(assigns) and PerpWalk.Guards.operational?()
  end

  defp market_active?(assigns) do
    case Map.get(assigns, :market) do
      %{status: :active} -> true
      _ -> false
    end
  end

  # The creator already has economic exposure via the LP seed and the
  # spread share; directional trading would compound a private-info
  # edge into a conflict with their resolution authority. Mirrors the
  # server-side `Trader.ensure_not_creator/2` refusal so the button is
  # never offered for an action the service layer would refuse. The
  # identity check itself lives on `PerpWalk.Markets.Market.creator?/2`
  # alongside Voter and Disputer's wrappers.
  defp viewer_is_creator?(assigns) do
    case Map.get(assigns, :market) do
      %PerpWalk.Markets.Market{} = market ->
        PerpWalk.Markets.Market.creator?(market, Map.get(assigns, :current_account_id))

      _ ->
        false
    end
  end

  defp disabled_reason(assigns) do
    cond do
      is_nil(Map.get(assigns, :current_account_id)) ->
        Messages.login_tooltip(:trade)

      PerpWalk.Guards.halted?() ->
        Messages.venue_halted()

      viewer_is_creator?(assigns) ->
        Messages.creator_cannot_trade_tooltip()

      true ->
        market_status_reason(Map.get(assigns, :market))
    end
  end

  defp market_status_reason(%{status: :active}), do: nil
  defp market_status_reason(%{status: status}), do: Messages.market_status_tooltip(status)
  defp market_status_reason(_), do: Messages.market_status_tooltip(nil)

  defp load_state(socket) do
    market_id = socket.assigns.market_id

    case Facade.get_market(market_id) do
      {:ok, market} ->
        positions = Facade.list_positions_for_market(market_id)
        votes = Facade.list_votes_for_market(market_id)
        now = DateTime.utc_now()
        odds_history = load_odds_history(market_id)

        viewer = socket.assigns[:current_account_id]
        # Show only funded (`:live` and beyond) disputes in the counter.
        # Pending/cancelled records aren't signal — they don't count
        # toward the threshold and the user shouldn't see the number
        # jump just because they opened the flag modal.
        dispute_count = Facade.live_dispute_count(market_id)

        socket
        |> assign(:not_found, false)
        |> assign(:market, market)
        |> assign(:positions, positions)
        |> assign(:viewer_positions, viewer_positions(positions, viewer, market.unit_size))
        |> assign(:dispute_stake, Facade.dispute_stake_for_market(market.deposit_amount))
        |> assign(:volume_24h, volume_24h(positions, now))
        |> assign(:vote_summary, summarize_votes(votes))
        |> assign(:viewer_vote, viewer_vote(votes, viewer))
        |> assign(:dispute_count, dispute_count)
        |> assign(:viewer_flagged, viewer_flagged?(market_id, viewer))
        |> assign(:odds_history, odds_history)
        |> assign(:now, now)
        |> load_comments()
        |> assign_quote_preview()

      {:error, :not_found} ->
        assign(socket, :not_found, true)
    end
  end

  defp load_comments(socket) do
    market_id = socket.assigns.market_id
    viewer_pubkey = viewer_nostr_pubkey(socket)
    viewer_handle = socket.assigns[:current_handle]

    comments =
      market_id
      |> Facade.list_comments_for_market()
      |> Enum.take(@comment_render_cap)
      |> Enum.map(&decorate_comment(&1, viewer_pubkey, viewer_handle))

    assign(socket, :comments, comments)
  end

  # The viewer's own comments display under the account handle (the
  # nav handle) rather than the derived nostr handle, so the user
  # can recognise their own posts in the feed. Other users' comments
  # stay on the nostr-derived name — that preserves the
  # external-observer property that scraping the relay can't link a
  # pubkey to a venue handle without the keyphrase.
  defp viewer_nostr_pubkey(socket) do
    with sid when is_binary(sid) <- socket.assigns[:session_id],
         {:ok, seckey} <- IdentityFacade.lookup_nostr_seckey(sid),
         {:ok, <<_parity, xonly::binary-32>>} <- Schnorr.pubkey_from_privkey(seckey) do
      Base.encode16(xonly, case: :lower)
    else
      _ -> nil
    end
  end

  defp decorate_comment(raw, viewer_pubkey, viewer_handle) do
    is_self = is_binary(viewer_pubkey) and raw.author_pubkey == viewer_pubkey

    handle =
      if is_self and is_binary(viewer_handle),
        do: viewer_handle,
        else: IdentityFacade.nostr_handle_for(raw.author_pubkey)

    %{
      event_id: raw.event_id,
      handle: handle,
      pubkey_short: String.slice(raw.author_pubkey, 0, 8),
      content: raw.content,
      created_at: raw.created_at,
      is_self: is_self
    }
  end

  # Looks up the viewer's per-venue Nostr handle so the composer
  # can display "posting as @handle". Returns nil for logged-out
  # viewers, sessions without a derived seckey, or any crypto error
  # (which is then surfaced as the displayed nil rather than a
  # crash). Pure read against in-memory Sessions.
  defp compute_nostr_handle(socket) do
    with sid when is_binary(sid) <- socket.assigns[:session_id],
         {:ok, seckey} <- IdentityFacade.lookup_nostr_seckey(sid),
         {:ok, <<_parity, xonly::binary-32>>} <- Schnorr.pubkey_from_privkey(seckey) do
      IdentityFacade.nostr_handle_for(Base.encode16(xonly, case: :lower))
    else
      _ -> nil
    end
  end

  defp load_odds_history(market_id) do
    case Facade.odds_history(market_id) do
      {:ok, points} -> points
      {:error, _} -> []
    end
  end

  defp volume_24h(positions, now) do
    cutoff = DateTime.add(now, -86_400, :second)

    positions
    |> Enum.filter(fn p -> DateTime.compare(p.created_at, cutoff) == :gt end)
    |> Enum.reduce(0, fn p, acc -> acc + p.amount_paid end)
  end

  defp summarize_votes(votes) do
    Enum.reduce(votes, %{up: 0, down: 0}, fn
      %{direction: :up}, acc -> %{acc | up: acc.up + 1}
      %{direction: :down}, acc -> %{acc | down: acc.down + 1}
    end)
  end

  defp viewer_vote(_votes, nil), do: nil

  defp viewer_vote(votes, account_id) do
    case Enum.find(votes, fn v -> v.account_id == account_id end) do
      nil -> nil
      %{direction: dir} -> dir
    end
  end

  defp viewer_flagged?(_market_id, nil), do: false
  defp viewer_flagged?(market_id, account_id), do: Facade.has_flagged?(account_id, market_id)

  # Closing the dispute modal without funding cancels the
  # `:awaiting_deposit` dispute so it doesn't linger in the user's
  # portfolio or inflate the dispute counter. Idempotent on already-
  # cancelled records; refused on funded statuses (which the modal
  # can't reach anyway).
  defp close_active_dispute(%{assigns: %{active_dispute: %{account_id: aid, market_id: mid}}} = socket) do
    _ = Facade.cancel_dispute(aid, mid)
    socket |> assign(:active_dispute, nil) |> load_state()
  rescue
    PerpWalk.Guards.SystemHaltedError ->
      socket
      |> assign(:active_dispute, nil)
      |> put_flash(:error, Messages.venue_halted())
  end

  defp close_active_dispute(socket), do: assign(socket, :active_dispute, nil)

  # Auto-closes the dispute modal once the on-chain deposit has been
  # observed and the dispute has transitioned to `:live`. Distinct
  # from `close_active_dispute/1` (the user-initiated cancel path,
  # which calls `Facade.cancel_dispute`) — by the time we see a
  # `DisputeFlagged` for an account+market, the deposit landed and
  # we must NOT cancel; we just clear the modal.
  defp close_if_active_dispute_funded(
         %{assigns: %{active_dispute: %{account_id: aid, market_id: mid}}} = socket,
         %{account_id: aid, market_id: mid}
       ) do
    socket
    |> assign(:active_dispute, nil)
    |> put_flash(:success, Messages.dispute_flagged())
  end

  defp close_if_active_dispute_funded(socket, _event), do: socket

  # Sums the viewer's open + settled contract counts on this market,
  # bucketed by side. Used by the trade panel to show a one-line
  # Aggregates the viewer's per-side holdings into the shape consumed
  # by the YOUR POSITIONS table under the buy buttons:
  #
  #     %{
  #       yes: %{contracts: N, amount_paid: P, payout_if_wins: M},
  #       no:  %{contracts: N, amount_paid: P, payout_if_wins: M}
  #     }
  #
  # `payout_if_wins` is `contracts * unit_size`; `amount_paid` is the
  # sum of the winning side's deposit basis (excludes loser-side
  # positions on the other side).
  defp viewer_positions(_positions, nil, _unit_size),
    do: empty_viewer_positions()

  defp viewer_positions(positions, account_id, unit_size) when is_integer(unit_size) do
    positions
    |> Enum.filter(&(&1.account_id == account_id))
    |> Enum.reduce(empty_viewer_positions(), fn p, acc ->
      side_total = Map.fetch!(acc, p.side)

      Map.put(acc, p.side, %{
        contracts: side_total.contracts + p.contracts,
        amount_paid: side_total.amount_paid + p.amount_paid,
        payout_if_wins: side_total.payout_if_wins + p.contracts * unit_size
      })
    end)
  end

  defp empty_viewer_positions do
    %{
      yes: %{contracts: 0, amount_paid: 0, payout_if_wins: 0},
      no: %{contracts: 0, amount_paid: 0, payout_if_wins: 0}
    }
  end

  defp format_remaining(%DateTime{} = expires_at, %DateTime{} = now) do
    seconds = max(DateTime.diff(expires_at, now, :second), 0)
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}:#{:io_lib.format("~2..0B", [secs])}"
  end

  # --- Render ---

  @impl true
  def render(%{not_found: true} = assigns) do
    ~H"""
    <Helpers.app_header current_handle={@current_handle} current_page={:market_detail} />
    <.sub_nav stats={[]} />

    <main class="bp-root">
      <h1 class="bp-sr-only">{Messages.sr_market_not_found()}</h1>
      <div class="bp-page">
        <.announcements items={Helpers.announcements()} />
        <.panel title={Messages.panel_market_not_found()}>
          <.empty_state message={Messages.empty_no_market_with_id(@market_id)} />
          <p class="bp-back"><a href="/markets">{Messages.link_back_to_markets()}</a></p>
        </.panel>
      </div>

      <Helpers.app_footer health={@health} />
    </main>
    """
  end

  def render(assigns) do
    ~H"""
    <Helpers.app_header current_handle={@current_handle} current_page={:market_detail} />

    <Helpers.app_sub_nav
      current_handle={@current_handle}
      current_page={:market_detail}
      stats={detail_stats(assigns)}
    />

    <main class="bp-root">
      <h1 class="bp-sr-only">{@market.description}</h1>
      <div class="bp-page-wide bp-fill-page">
        <.announcements items={Helpers.announcements()} />

        <div class="bp-grid cols-3-2 bp-fill-page">
          <div class="bp-stack-md bp-fill-col">
            <.panel title={Messages.panel_market()} class="pw-market-panel">
              <div class="pw-market-head">
                <Badges.category_badge category={@market.category} />
                <Badges.state_label market={@market} />
                <p class="pw-market-title">{@market.description}</p>
              </div>

              <div class="pw-market-chart-section">
                <h3 class="pw-market-chart-label">{Messages.market_consensus_label()}</h3>
                <OddsChart.odds_chart
                  points={@odds_history}
                  start_at={@market.activated_at || @market.created_at}
                  end_at={@market.expiry}
                  now={chart_now(@market, @now)}
                />
              </div>

              <div :if={@market.resolution_criterion not in [nil, ""]} class="pw-market-criterion">
                <h3 class="pw-market-criterion-label">{Messages.label_resolution_criterion()}</h3>
                <p class="pw-market-criterion-text">{@market.resolution_criterion}</p>
              </div>
            </.panel>

            <.panel title={Messages.panel_comments()} class="pw-comments-panel">
              <div :if={@current_account_id} class="pw-comment-composer">
                <form id="comment-form" phx-submit="comment:submit" phx-change="comment:draft">
                  <label for="comment-content" class="bp-sr-only">{Messages.sr_comment_content()}</label>
                  <textarea
                    id="comment-content"
                    name="comment[content]"
                    rows="3"
                    maxlength="5000"
                    placeholder={Messages.placeholder_comment()}
                    class="bp-textarea bp-textarea"
                  ><%= @comment_draft %></textarea>
                  <div class="pw-comment-footer">
                    <button type="submit" class="bp-btn bp-btn-primary bp-btn-sm">{Messages.action_post()}</button>
                  </div>
                </form>
              </div>

              <Helpers.table_empty_state :if={@comments == []} message={Messages.empty_no_comments()} />

              <ul :if={@comments != []} class="pw-comment-list" role="list">
                <li :for={comment <- @comments}>
                  <article class="pw-comment">
                    <header class="pw-comment-head">
                      <span class={"pw-comment-handle #{if comment.is_self, do: "pw-comment-handle-self"}"}>
                        @{comment.handle}
                      </span>
                      <span class="pw-comment-pubkey">{comment.pubkey_short}</span>
                      <% comment_created_at = DateTime.from_unix!(comment.created_at) %>
                      <time class="pw-comment-time" datetime={DateTime.to_iso8601(comment_created_at)}>
                        {Helpers.time_since(comment_created_at, @now)}
                      </time>
                    </header>
                    <p class="pw-comment-body">{comment.content}</p>
                  </article>
                </li>
              </ul>
            </.panel>
          </div>

          <div class="bp-stack-md bp-fill-col">
            <.panel title={Messages.panel_stats()}>
              <dl class="pw-stats">
                <div class="pw-stats-row">
                  <dt>{Messages.side_yes()}</dt>
                  <dd class="pw-stats-yes">{elem(Helpers.mid_decimals(@market.pool), 0)}</dd>
                </div>
                <div class="pw-stats-row">
                  <dt>{Messages.side_no()}</dt>
                  <dd class="pw-stats-no">{elem(Helpers.mid_decimals(@market.pool), 1)}</dd>
                </div>
                <div class="pw-stats-row">
                  <dt>{Messages.stat_label_pool()}</dt>
                  <dd class="pw-stats-pool">{Helpers.format_pool_total(@positions, @market.deposit_amount)}</dd>
                </div>
                <div class="pw-stats-row">
                  <dt>{Messages.stat_label_volume_24h()}</dt>
                  <dd>{Helpers.format_xmr_compact(@volume_24h)}</dd>
                </div>
                <div class="pw-stats-row">
                  <dt>{Messages.stat_label_total_trades()}</dt>
                  <dd>{length(@positions)}</dd>
                </div>
                <div class="pw-stats-row">
                  <dt>{Messages.stat_label_expiry()}</dt>
                  <dd>
                    <time datetime={DateTime.to_iso8601(@market.expiry)}>
                      {Helpers.time_until(@market.expiry, @now)}
                    </time>
                  </dd>
                </div>
                <div class="pw-stats-row">
                  <dt>{Messages.stat_label_resolution_deadline()}</dt>
                  <dd>
                    <time datetime={DateTime.to_iso8601(@market.resolution_deadline)}>
                      {Helpers.time_until(@market.resolution_deadline, @now)}
                    </time>
                  </dd>
                </div>
                <div class="pw-stats-row">
                  <dt>{Messages.stat_label_created()}</dt>
                  <dd>
                    <time datetime={DateTime.to_iso8601(@market.created_at)}>
                      {Helpers.time_since(@market.created_at, @now)}
                    </time>
                  </dd>
                </div>
                <div class="pw-stats-row">
                  <dt>{Messages.stat_label_creator()}</dt>
                  <dd>@{IdentityFacade.handle_for(@market.creator_account_id)}</dd>
                </div>
                <div :if={@market.resolved_at} class="pw-stats-row">
                  <dt>{Messages.stat_label_resolved()}</dt>
                  <dd>
                    <time datetime={DateTime.to_iso8601(@market.resolved_at)}>
                      {Helpers.time_since(@market.resolved_at, @now)}
                    </time>
                  </dd>
                </div>
                <div :if={@market.outcome} class="pw-stats-row">
                  <dt>{Messages.stat_label_outcome()}</dt>
                  <dd>{String.upcase(Atom.to_string(@market.outcome))}</dd>
                </div>
              </dl>
            </.panel>

            <.action_panel
              market={@market}
              vote_summary={@vote_summary}
              viewer_vote={@viewer_vote}
              dispute_count={@dispute_count}
              dispute_stake={@dispute_stake}
              viewer_flagged={@viewer_flagged}
              viewer_positions={@viewer_positions}
              current_account_id={@current_account_id}
              contracts={@contracts}
              quote_preview={@quote_preview}
              now={@now}
              assigns={assigns}
            />
          </div>
        </div>
      </div>

      <Helpers.app_footer health={@health} />
    </main>

    <.trade_modal
      :if={@active_trade}
      trade={@active_trade}
      now={@now}
      monero_status={@health.monero}
    />
    <.dispute_modal
      :if={@active_dispute}
      dispute={@active_dispute}
      monero_status={@health.monero}
    />
    """
  end

  # --- Action Panel (contextual: vote / trade / nothing) ---

  attr(:market, :map, required: true)
  attr(:vote_summary, :map, required: true)
  attr(:viewer_vote, :any, required: true)
  attr(:dispute_count, :integer, required: true)
  attr(:dispute_stake, :integer, required: true)
  attr(:viewer_flagged, :boolean, required: true)
  attr(:viewer_positions, :map, required: true)
  attr(:current_account_id, :any, required: true)
  attr(:contracts, :integer, required: true)
  attr(:quote_preview, :map, required: true)
  attr(:now, :any, required: true)
  attr(:assigns, :map, required: true)

  # Creator-only — only the creator needs the liquidity surface; anyone else
  # gets the default `:awaiting_deposit` lead. The panel mirrors the
  # liquidity modal shown in MarketNewLive (same `pw-modal-*`
  # typography) — QR is rendered inline, no buttons. When the Poller
  # detects the deposit and Maker flips the market to `:pending`, the
  # `MarketDepositConfirmed` subscription re-renders this panel away.
  defp action_panel(
         %{market: %{status: :awaiting_deposit, creator_account_id: cid}, current_account_id: cid} =
           assigns
       )
       when not is_nil(cid) do
    ~H"""
    <.panel title={Messages.panel_initial_liquidity()}>
      <div class="bp-panel-body bp-stack">
        <Modal.deposit_block
          subaddress={@market.deposit_subaddress}
          copy_button_id={"market-liquidity-copy-#{@market.id}"}
          copy_aria_label={Messages.aria_copy_market_deposit_address()}
          monero_status={@assigns.health.monero}
          amount_piconeros={@market.deposit_amount}
          show_copy={false}
          payment_observed={@assigns.market_deposit_observed}
        >
          <:lead>
            <p class="bp-lead">
              {Messages.initial_liquidity_lead(Helpers.format_xmr(@market.deposit_amount))}
            </p>
          </:lead>
        </Modal.deposit_block>
      </div>
    </.panel>
    """
  end

  defp action_panel(%{market: %{status: :pending}} = assigns) do
    ~H"""
    <.panel title={Messages.panel_listing_vote()}>
      <div class="pw-vote-panel">
        <p class="bp-lead bp-pad-md">
          {listing_vote_lead(@market, @now)}
        </p>

        <div class="bp-btn-row">
          <button
            type="button"
            class={"bp-btn bp-btn-lg pw-buy-yes #{if @viewer_vote == :up, do: "pw-vote-cast"}"}
            phx-click={if listing_vote_open?(@current_account_id, @market), do: "vote"}
            phx-value-direction="up"
            phx-throttle="1000"
            disabled={not listing_vote_open?(@current_account_id, @market)}
            title={listing_vote_button_title(@current_account_id, @market)}
          >
            {Messages.action_vote_up()} ({@vote_summary.up})
          </button>
          <button
            type="button"
            class={"bp-btn bp-btn-lg pw-buy-no #{if @viewer_vote == :down, do: "pw-vote-cast"}"}
            phx-click={if listing_vote_open?(@current_account_id, @market), do: "vote"}
            phx-value-direction="down"
            phx-throttle="1000"
            disabled={not listing_vote_open?(@current_account_id, @market)}
            title={listing_vote_button_title(@current_account_id, @market)}
          >
            {Messages.action_vote_down()} ({@vote_summary.down})
          </button>
        </div>

        <p
          :if={listing_vote_help_text(@current_account_id, @market, @viewer_vote)}
          class="pw-action-help"
        >
          {listing_vote_help_text(@current_account_id, @market, @viewer_vote)}
        </p>
      </div>
    </.panel>
    """
  end

  defp action_panel(%{market: %{status: :resolving}} = assigns) do
    ~H"""
    <.panel title={Messages.panel_dispute()}>
      <div class="pw-dispute-panel">
        <p class="bp-lead bp-pad-md">
          {Messages.dispute_panel_lead(String.upcase(Atom.to_string(@market.outcome)), Helpers.format_xmr(@dispute_stake))}
        </p>

        <div class="bp-btn-row">
          <button
            type="button"
            class={dispute_btn_class(@viewer_flagged)}
            phx-click={
              if dispute_open?(@current_account_id, @market, @viewer_positions, @viewer_flagged),
                do: "dispute:flag"
            }
            phx-throttle="1000"
            disabled={not dispute_open?(@current_account_id, @market, @viewer_positions, @viewer_flagged)}
            title={
              dispute_button_title(
                @current_account_id,
                @market,
                @viewer_positions,
                @viewer_flagged
              )
            }
          >
            {dispute_btn_label(@viewer_flagged)} ({@dispute_count})
          </button>
        </div>
      </div>
    </.panel>
    """
  end

  defp action_panel(%{market: %{status: :active}} = assigns) do
    ~H"""
    <.panel title={Messages.panel_trade()}>
      <div class="pw-trade-panel">
        <p class="bp-lead bp-pad-md">
          {Messages.trade_panel_lead(Helpers.format_xmr(@market.unit_size))}
        </p>

        <div class="bp-stepper bp-pad-md">
          <label for="trade-contracts" class="bp-label">{Messages.label_contracts()}</label>
          <div class="bp-stepper-controls">
            <button
              type="button"
              class="bp-btn bp-btn-default bp-btn-icon"
              phx-click="contracts:dec"
              phx-throttle="100"
              disabled={@contracts <= 1}
              aria-label={Messages.aria_decrease_contracts()}
            >
              −
            </button>
            <form id="trade-contracts-form" phx-change="contracts:set" phx-submit="contracts:set" autocomplete="off">
              <input
                type="number"
                id="trade-contracts"
                name="contracts"
                class="bp-input bp-stepper-input"
                inputmode="numeric"
                min="1"
                step="1"
                phx-debounce="400"
                value={@contracts}
              />
            </form>
            <button
              type="button"
              class="bp-btn bp-btn-default bp-btn-icon"
              phx-click="contracts:inc"
              phx-throttle="100"
              aria-label={Messages.aria_increase_contracts()}
            >
              +
            </button>
          </div>
        </div>

        <div class="bp-btn-row">
          <button
            type="button"
            class="bp-btn bp-btn-lg bp-cta-btn pw-buy-yes"
            phx-click={if buy_enabled?(@assigns, @quote_preview.yes), do: "trade:open"}
            phx-value-side="yes"
            phx-throttle="1000"
            disabled={not buy_enabled?(@assigns, @quote_preview.yes)}
            title={buy_button_title(@assigns, @quote_preview.yes)}
          >
            <span class="pw-buy-side">{Messages.buy_side_label(:yes, elem(Helpers.mid_decimals(@market.pool), 0))}</span>
            <span class="pw-buy-cost">{buy_cost_label(@quote_preview.yes)}</span>
          </button>
          <button
            type="button"
            class="bp-btn bp-btn-lg bp-cta-btn pw-buy-no"
            phx-click={if buy_enabled?(@assigns, @quote_preview.no), do: "trade:open"}
            phx-value-side="no"
            phx-throttle="1000"
            disabled={not buy_enabled?(@assigns, @quote_preview.no)}
            title={buy_button_title(@assigns, @quote_preview.no)}
          >
            <span class="pw-buy-side">{Messages.buy_side_label(:no, elem(Helpers.mid_decimals(@market.pool), 1))}</span>
            <span class="pw-buy-cost">{buy_cost_label(@quote_preview.no)}</span>
          </button>
        </div>

        <div :if={viewer_holds?(@viewer_positions)} class="pw-trade-positions">
          <table class="bp-mini-table" aria-label={Messages.aria_your_positions_on_market()}>
            <thead>
              <tr>
                <th scope="col">{Messages.column_side()}</th>
                <th scope="col">{Messages.column_contracts()}</th>
                <th scope="col">{Messages.column_cost()}</th>
                <th scope="col">{Messages.column_payout_if_wins()}</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@viewer_positions.yes.contracts > 0}>
                <td class="pw-positions-mini-side bp-color-accent">{Messages.side_yes()}</td>
                <td>{@viewer_positions.yes.contracts}</td>
                <td>{Helpers.format_xmr(@viewer_positions.yes.amount_paid)}</td>
                <td>{Helpers.format_xmr(@viewer_positions.yes.payout_if_wins)}</td>
              </tr>
              <tr :if={@viewer_positions.no.contracts > 0}>
                <td class="pw-positions-mini-side bp-color-grey">{Messages.side_no()}</td>
                <td>{@viewer_positions.no.contracts}</td>
                <td>{Helpers.format_xmr(@viewer_positions.no.amount_paid)}</td>
                <td>{Helpers.format_xmr(@viewer_positions.no.payout_if_wins)}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <p
          :if={buy_help_text(@assigns, @quote_preview.yes) || buy_help_text(@assigns, @quote_preview.no)}
          class="pw-action-help"
        >
          {buy_help_text(@assigns, @quote_preview.yes) || buy_help_text(@assigns, @quote_preview.no)}
        </p>
      </div>
    </.panel>
    """
  end

  defp action_panel(%{market: %{status: :expired}} = assigns) do
    if creator_resolves?(assigns.current_account_id, assigns.market) do
      ~H"""
      <.panel title={Messages.panel_submit_resolution()}>
        <div class="bp-stack bp-pad-md">
          <p class="bp-lead">
            {Messages.creator_resolution_lead(creator_resolution_tail(@market, @now))}
          </p>

          <div class="bp-btn-row">
            <button
              type="button"
              class="bp-btn bp-btn-default bp-btn-lg pw-resolve-btn"
              phx-click="resolve"
              phx-value-outcome="no"
              phx-throttle="1000"
            >
              {Messages.action_resolve_no()}
            </button>
            <button
              type="button"
              class="bp-btn bp-btn-primary bp-btn-lg pw-resolve-btn"
              phx-click="resolve"
              phx-value-outcome="yes"
              phx-throttle="1000"
            >
              {Messages.action_resolve_yes()}
            </button>
          </div>
        </div>
      </.panel>
      """
    else
      ~H"""
      <.panel title={Messages.panel_awaiting_resolution()}>
        <div class="bp-stack bp-pad-md">
          <p class="bp-lead">
            {non_creator_resolution_lead(@market, @now)}
          </p>
        </div>
      </.panel>
      """
    end
  end

  defp action_panel(%{market: %{status: :voided}} = assigns) do
    ~H"""
    <.panel title={Messages.panel_market_closed()}>
      <div class="bp-stack bp-pad-md">
        <p class="bp-lead">
          {Messages.market_voided_lead()}
          <span :if={@current_account_id && viewer_holds?(@viewer_positions)}>
            {Messages.claim_from_portfolio_prefix()} <.link navigate={~p"/portfolio"}>{Messages.link_here()}</.link>.
          </span>
        </p>
      </div>
    </.panel>
    """
  end

  defp action_panel(assigns) do
    assigns = assign(assigns, :status_panel_title, status_panel_title(assigns.market))

    ~H"""
    <.panel title={@status_panel_title}>
      <div class="bp-stack bp-pad-md">
        <p class="bp-lead">
          {closed_market_lead(@market)}
        </p>
      </div>
    </.panel>
    """
  end

  defp status_panel_title(%{status: :awaiting_deposit}), do: Messages.panel_market_pending()
  defp status_panel_title(_), do: Messages.panel_market_closed()

  defp closed_market_lead(%{status: :settled, outcome: outcome}),
    do: Messages.closed_market_settled_lead(String.upcase(Atom.to_string(outcome)))

  defp closed_market_lead(%{status: :rejected}), do: Messages.closed_market_rejected_lead()

  defp closed_market_lead(%{status: :awaiting_deposit}),
    do: Messages.closed_market_awaiting_deposit_lead()

  defp closed_market_lead(_), do: Messages.closed_market_default_lead()

  # Tail of the creator's "Submit Resolution" panel. Switches on
  # whether the resolution deadline has lapsed: pre-deadline asks
  # them to act before the cutoff; post-deadline (in the auto-void
  # grace window) tells them to act now or watch the market void.
  defp creator_resolution_tail(market, now) do
    if DateTime.compare(now, market.resolution_deadline) == :gt do
      Messages.creator_resolution_tail_overdue()
    else
      Messages.creator_resolution_tail_pre_deadline()
    end
  end

  # Non-creator view of the same lifecycle moment. Mirrors the
  # creator branching so the timing copy never reads "up to N ago".
  defp non_creator_resolution_lead(market, now) do
    if DateTime.compare(now, market.resolution_deadline) == :gt do
      Messages.non_creator_resolution_lead_overdue(Helpers.time_until(market.resolution_deadline, now))
    else
      Messages.non_creator_resolution_lead_pre_deadline(Helpers.time_until(market.resolution_deadline, now))
    end
  end

  defp buy_enabled?(assigns, {:ok, _cost}), do: trading_open?(assigns)
  defp buy_enabled?(_assigns, {:error, _}), do: false

  defp buy_disabled_reason(_assigns, {:error, :insufficient_liquidity}),
    do: Messages.insufficient_liquidity_tooltip()

  defp buy_disabled_reason(_assigns, {:error, :invalid_contracts}),
    do: Messages.contracts_must_be_positive()

  defp buy_disabled_reason(assigns, _preview), do: disabled_reason(assigns)

  # Per-ticker conditions (`:insufficient_liquidity`,
  # `:invalid_contracts`) are surfaced as button-`title` tooltips
  # only — the user can clear them by stepping the ticker down, so
  # rendering a persistent visible help line under the panel adds
  # visual noise without adding signal. State-of-the-world conditions
  # (logged-out, halted, market not active, creator-of-own-market) stay
  # in the visible help text via `buy_help_text/2` because the user
  # can't resolve them by tweaking the ticker.
  defp per_ticker_reason?({:error, :insufficient_liquidity}), do: true
  defp per_ticker_reason?({:error, :invalid_contracts}), do: true
  defp per_ticker_reason?(_), do: false

  # Tooltip text for the disabled state. Per-ticker reasons surface
  # here (and only here); state-of-the-world reasons mirror what the
  # visible help text shows so screen readers + hover users get the
  # same answer.
  defp buy_button_title(assigns, preview) do
    cond do
      is_nil(Map.get(assigns, :current_account_id)) ->
        Messages.login_tooltip(:trade)

      per_ticker_reason?(preview) ->
        buy_disabled_reason(assigns, preview)

      buy_enabled?(assigns, preview) ->
        nil

      true ->
        buy_disabled_reason(assigns, preview)
    end
  end

  # Visible help text below the Buy row. Suppressed for logged-out
  # viewers (the "Log in to trade" tooltip on each button is enough),
  # and suppressed for per-ticker reasons (which surface via tooltip
  # only). Everything else — halt, market not active, creator-of-own-
  # market — renders here so the cause is visible at a glance without
  # the user needing to hover.
  defp buy_help_text(assigns, preview) do
    cond do
      is_nil(Map.get(assigns, :current_account_id)) -> nil
      per_ticker_reason?(preview) -> nil
      true -> buy_disabled_reason(assigns, preview)
    end
  end

  defp buy_cost_label({:ok, piconeros}), do: Helpers.format_xmr(piconeros)
  defp buy_cost_label({:error, :insufficient_liquidity}), do: Messages.no_liquidity_short()
  defp buy_cost_label({:error, _}), do: Messages.placeholder_em_dash()

  defp dispute_btn_class(true), do: "bp-btn bp-btn-default bp-btn-lg pw-dispute-cast"
  defp dispute_btn_class(false), do: "bp-btn bp-btn-primary bp-btn-lg"

  defp dispute_btn_label(true), do: Messages.action_disputed_cast()
  defp dispute_btn_label(false), do: Messages.action_dispute()

  defp viewer_holds?(%{yes: %{contracts: 0}, no: %{contracts: 0}}), do: false
  defp viewer_holds?(_), do: true

  defp creator_resolves?(nil, _market), do: false

  defp creator_resolves?(account_id, %{creator_account_id: creator})
       when account_id == creator,
       do: true

  defp creator_resolves?(_account_id, _market), do: false

  # --- Listing Vote Helpers ---

  defp listing_vote_open?(nil, _market), do: false
  defp listing_vote_open?(_account_id, %{status: status}) when status != :pending, do: false

  defp listing_vote_open?(account_id, %{creator_account_id: creator}) when account_id == creator,
    do: false

  defp listing_vote_open?(_account_id, _market), do: true

  defp listing_vote_disabled_reason(nil, _market, _vote), do: Messages.login_tooltip(:vote)

  defp listing_vote_disabled_reason(account_id, %{creator_account_id: creator}, _vote)
       when account_id == creator,
       do: Messages.created_this_market_tooltip()

  defp listing_vote_disabled_reason(_account_id, %{status: status}, _vote) when status != :pending,
    do: Messages.voting_closed_tooltip()

  defp listing_vote_disabled_reason(_account_id, _market, _vote), do: nil

  # The creator and logged-out cases surface as `title=` chrome on the
  # vote buttons instead of a visible help line — both reasons are
  # self-evident to the viewer (you already know whether you made the
  # market or are logged in) and clutter the panel for everyone else.
  defp listing_vote_creator?(account_id, %{creator_account_id: creator})
       when not is_nil(account_id) and account_id == creator,
       do: true

  defp listing_vote_creator?(_account_id, _market), do: false

  defp listing_vote_help_text(account_id, market, viewer_vote) do
    cond do
      is_nil(account_id) -> nil
      listing_vote_creator?(account_id, market) -> nil
      true -> listing_vote_disabled_reason(account_id, market, viewer_vote)
    end
  end

  defp listing_vote_button_title(account_id, market) do
    cond do
      is_nil(account_id) -> Messages.login_tooltip(:vote)
      listing_vote_creator?(account_id, market) -> Messages.created_this_market_tooltip()
      true -> nil
    end
  end

  # --- Dispute Helpers ---

  # Disputes are restricted to non-creator traders on the market.
  # The creator can't dispute their own market (would be a self-slash
  # at best, sock-puppet inflation of the re-review threshold at
  # worst — same shape as the listing-vote self-vote refusal).
  # Non-traders can't dispute because dispute is the trader's
  # recourse against a wrong-outcome resolution; a viewer with no
  # position has no skin in the game and no economic standing to
  # challenge. The backend enforces both checks; the UI mirrors them
  # so the button surface matches what the server will accept.
  defp dispute_open?(nil, _market, _positions, _viewer_flagged), do: false

  defp dispute_open?(account_id, %{creator_account_id: creator}, _positions, _viewer_flagged)
       when account_id == creator,
       do: false

  defp dispute_open?(_account_id, _market, _positions, true), do: false

  defp dispute_open?(_account_id, _market, positions, false),
    do: viewer_holds?(positions)

  defp dispute_disabled_reason(nil, _market, _positions, _flagged),
    do: Messages.login_tooltip(:dispute)

  defp dispute_disabled_reason(account_id, %{creator_account_id: creator}, _positions, _flagged)
       when account_id == creator,
       do: Messages.creator_cannot_dispute_tooltip()

  defp dispute_disabled_reason(_account_id, _market, positions, flagged) do
    cond do
      not viewer_holds?(positions) -> Messages.only_traders_can_dispute_tooltip()
      flagged -> Messages.already_disputed_tooltip()
      true -> nil
    end
  end

  # Tooltip text for the dispute button. Always renders the reason
  # whenever the button is disabled — login-required and creator-of-
  # own-market included. Same shape as `buy_button_title/2` and
  # `listing_vote_button_title/2`: tooltip is the universal surface,
  # visible help text below is the optional auxiliary.
  defp dispute_button_title(account_id, market, positions, flagged) do
    if dispute_open?(account_id, market, positions, flagged) do
      nil
    else
      dispute_disabled_reason(account_id, market, positions, flagged)
    end
  end

  defp listing_vote_lead(%{status: :pending} = market, %DateTime{} = now) do
    expires_at = pending_window_end(market)

    if DateTime.compare(expires_at, now) == :lt do
      Messages.listing_window_closed()
    else
      Messages.listing_vote_lead_open(Helpers.time_until(expires_at, now))
    end
  end

  defp listing_vote_lead(_market, _now), do: ""

  defp pending_window_end(%{created_at: created_at}) do
    DateTime.add(created_at, 86_400, :second)
  end

  attr(:trade, :map, required: true)
  attr(:now, :any, required: true)
  attr(:monero_status, :atom, default: :ok)

  defp trade_modal(%{trade: %{step: :refund_address}} = assigns) do
    ~H"""
    <Modal.modal
      title={Messages.modal_title_refund_address(@trade.side)}
      title_id="trade-modal-title"
      click_away="trade:close"
      side_class={"pw-trade-modal-#{@trade.side}"}
    >
      <form id="trade-refund-address-form" phx-submit="trade:refund_address_submit" class="bp-stack-md">
        <p class="bp-lead">{Messages.refund_address_lead()}</p>

        <div class="bp-field">
          <label for="trade-refund-address" class="bp-label">{Messages.label_refund_address()}</label>
          <input
            type="text"
            id="trade-refund-address"
            name="refund_address"
            class="bp-input"
            required
            autocomplete="off"
            spellcheck="false"
            placeholder={Messages.field_destination_placeholder()}
            value={@trade.refund_address}
          />
        </div>

        <div class="bp-btn-row">
          <button type="button" class="bp-btn bp-btn-default" phx-click="trade:close">
            {Messages.action_close()}
          </button>
          <button type="submit" class="bp-btn bp-btn-primary">{Messages.action_next()}</button>
        </div>
      </form>
    </Modal.modal>
    """
  end

  defp trade_modal(%{trade: %{step: :underpaid}} = assigns) do
    ~H"""
    <Modal.modal
      title={Messages.modal_title_underpaid()}
      title_id="trade-modal-title"
      click_away="trade:close"
      side_class={"pw-trade-modal-#{@trade.side}"}
    >
      <div class="bp-stack-md">
        <div class="bp-color-warn bp-callout" role="alert">
          <strong>{Messages.underpaid_headline()}</strong>
        </div>

        <div class="bp-box bp-stack-md">
          <div class="pw-claim-confirm-row">
            <span class="bp-label">{Messages.underpaid_label_sent()}</span>
            <span class="pw-claim-confirm-value pw-claim-confirm-amount">
              {Helpers.format_xmr(@trade.underpaid.amount_paid_piconeros)}
            </span>
          </div>
          <div class="pw-claim-confirm-row">
            <span class="bp-label">{Messages.underpaid_label_required()}</span>
            <span class="pw-claim-confirm-value pw-claim-confirm-amount">
              {Helpers.format_xmr(@trade.underpaid.amount_expected_piconeros)}
            </span>
          </div>
          <div class="pw-claim-confirm-row">
            <span class="bp-label">{Messages.underpaid_label_shortfall()}</span>
            <span class="pw-claim-confirm-value pw-claim-confirm-amount">
              {Helpers.format_xmr(
                @trade.underpaid.amount_expected_piconeros -
                  @trade.underpaid.amount_paid_piconeros
              )}
            </span>
          </div>
          <div class="pw-claim-confirm-row">
            <span class="bp-label">{Messages.underpaid_label_refunding_to()}</span>
            <code
              class="pw-claim-confirm-value pw-claim-confirm-address"
              title={@trade.refund_address}
            >
              {Helpers.short_address(@trade.refund_address)}
            </code>
          </div>
        </div>

        <div class="bp-btn-row">
          <button type="button" class="bp-btn bp-btn-default" phx-click="trade:close">
            {Messages.action_close()}
          </button>
        </div>
      </div>
    </Modal.modal>
    """
  end

  defp trade_modal(assigns) do
    ~H"""
    <Modal.modal
      title={Messages.modal_title_buy_side(@trade.side)}
      title_id="trade-modal-title"
      click_away="trade:close"
      side_class={"pw-trade-modal-#{@trade.side}"}
    >
      <:header_action>
        <span
          class={"pw-trade-modal-timer pw-trade-modal-timer-#{@trade.side}"}
          aria-label={
            if Map.get(@trade, :payment_observed, false),
              do: Messages.aria_quote_locked_at(),
              else: Messages.aria_quote_expires_in()
          }
        >
          {format_remaining(@trade.quote.expires_at, Map.get(@trade, :payment_observed_at) || @now)}
        </span>
      </:header_action>

      <Modal.deposit_block
        subaddress={@trade.quote.subaddress}
        copy_button_id={"copy-#{@trade.quote.id}"}
        copy_aria_label={Messages.aria_copy_side_deposit_address(@trade.side)}
        monero_status={@monero_status}
        amount_piconeros={@trade.quote.amount_paid_piconeros}
        show_copy={false}
        payment_observed={Map.get(@trade, :payment_observed, false)}
      >
        <:lead>
          <p class="bp-lead">
            {Messages.trade_deposit_lead(Helpers.format_xmr(@trade.quote.amount_paid_piconeros))}
          </p>
        </:lead>
      </Modal.deposit_block>

      <div class="bp-btn-row">
        <button type="button" class="bp-btn bp-btn-default" phx-click="trade:close">
          {if Map.get(@trade, :payment_observed, false), do: Messages.action_hide(), else: Messages.action_close()}
        </button>
      </div>
    </Modal.modal>
    """
  end

  attr(:dispute, :map, required: true)
  attr(:monero_status, :atom, default: :ok)

  defp dispute_modal(assigns) do
    ~H"""
    <Modal.modal title={Messages.modal_title_dispute()} title_id="dispute-modal-title" click_away="dispute:close">
      <Modal.deposit_block
        subaddress={@dispute.deposit_subaddress}
        copy_button_id={"dispute-copy-#{@dispute.account_id}"}
        copy_aria_label={Messages.aria_copy_dispute_deposit_address()}
        monero_status={@monero_status}
        amount_piconeros={@dispute.stake_amount_piconeros}
        show_copy={false}
        payment_observed={Map.get(@dispute, :payment_observed, false)}
      >
        <:lead>
          <p class="bp-lead">
            {Messages.dispute_deposit_lead(Helpers.format_xmr(@dispute.stake_amount_piconeros))}
          </p>
        </:lead>
      </Modal.deposit_block>

      <div class="bp-btn-row">
        <button type="button" class="bp-btn bp-btn-default" phx-click="dispute:close">
          {if Map.get(@dispute, :payment_observed, false), do: Messages.action_hide(), else: Messages.action_close()}
        </button>
      </div>
    </Modal.modal>
    """
  end

  defp detail_stats(%{market: market, positions: positions} = assigns) do
    {yes, no} = Helpers.mid_decimals(market.pool)

    [
      %{label: Messages.side_yes(), value: yes, class: "bp-color-accent"},
      %{label: Messages.side_no(), value: no, class: "bp-color-grey"},
      %{
        label: Messages.stat_label_pool(),
        value: Helpers.format_pool_total(positions, market.deposit_amount),
        class: "accent",
        right: true
      }
    ]
    |> append_outcome(assigns)
  end

  defp append_outcome(stats, %{market: %{outcome: outcome}}) when outcome in [:yes, :no, :void] do
    stats ++ [%{label: Messages.stat_label_outcome(), value: outcome |> Atom.to_string() |> String.upcase()}]
  end

  defp append_outcome(stats, _), do: stats
end
