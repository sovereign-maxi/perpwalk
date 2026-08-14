defmodule PerpWalkWeb.PortfolioLive do
  @moduledoc """
  Personal position list at `/portfolio`.

  Shows every Position the current account holds — open trades,
  settled winners, settled losers, refunded, and paid-out — with
  a Claim button on rows that are eligible for federation payout
  (`:settled_winner` and `:refunded`). Anonymous users hitting
  this URL get bounced to `/auth/login`.

  The Claim button opens a modal that takes a Monero destination
  address and calls `Markets.Facade.claim_payout/2`. The page
  subscribes to the federation payout lifecycle events
  (submitted, failed, rule-check-failed, operator-override) so a
  row's claim state tracks the payout live — from "Queued" through
  "needs review" holds to "Submitted: <txid>" the moment the
  federation signs and broadcasts on-chain.
  """

  use PerpWalkWeb, :live_view

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Federation.Facade, as: FederationFacade
  alias PerpWalk.Federation.Payout
  alias PerpWalk.Markets.{Dispute, Facade, Market}
  alias PerpWalk.Monero.Address
  alias PerpWalkWeb.Live.Components.{Badges, Modal, Paginator}
  alias PerpWalkWeb.Live.Helpers
  alias PerpWalkWeb.Live.RateLimit
  alias PerpWalkWeb.Live.RateLimit.Shared, as: SharedRateLimit
  alias PerpWalkWeb.Messages

  @per_page 25

  @position_event_topics [
    MarketsEvents.PositionOpened,
    MarketsEvents.PositionPaidOut,
    MarketsEvents.QuoteFilled,
    MarketsEvents.MarketSettled,
    MarketsEvents.MarketVoided,
    MarketsEvents.DisputeFlagged,
    MarketsEvents.DisputeResolved
  ]

  # RuleCheckFailed / OperatorOverride cover the :awaiting_operator
  # transitions — without them the "needs review" pill (and its
  # clearance) only appears after a manual reload.
  @federation_event_topics [
    FederationEvents.PayoutRequested,
    FederationEvents.PayoutSubmitted,
    FederationEvents.PayoutFailed,
    FederationEvents.RuleCheckFailed,
    FederationEvents.OperatorOverride
  ]

  # Cadence for the periodic `:tick` that keeps relative-time labels
  # ("3d ago", "4h 32m", etc.) fresh between event-driven re-renders.
  # Mirrors `markets_live.ex` and `market_live.ex`.
  @tick_interval_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns[:current_account_id] do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, Messages.login_required(:portfolio))
         |> redirect(to: ~p"/auth/login")}

      _account_id ->
        if connected?(socket) do
          subscribe_to_events()
          Helpers.subscribe_to_pip_events()
          schedule_tick()
        end

        {:ok,
         socket
         |> assign(:page_title, Messages.page_title_portfolio())
         |> assign(:claiming, nil)
         |> assign(:claim_step, :entry)
         |> assign(:claim_destination, "")
         |> assign(:resolving_market_id, nil)
         |> assign(:page, 1)
         |> assign(:dispute_page, 1)
         |> assign(:market_page, 1)
         |> assign(:per_page, @per_page)
         |> assign(:health, Helpers.fetch_footer_health())
         |> load_state()}
    end
  end

  @impl true
  def handle_event("dispute_claim:open", %{"market-id" => market_id}, socket) do
    case RateLimit.check(:dispute_claim_open) do
      :ok ->
        {:noreply,
         socket
         |> assign(:claiming, {:dispute, market_id})
         |> assign(:claim_step, :entry)
         |> assign(:claim_destination, "")}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, Messages.rate_limited(:claim))}
    end
  end

  def handle_event("resolve:open", %{"market-id" => market_id}, socket) do
    {:noreply, assign(socket, :resolving_market_id, market_id)}
  end

  def handle_event("resolve:cancel", _params, socket) do
    {:noreply, assign(socket, :resolving_market_id, nil)}
  end

  def handle_event("resolve:submit", %{"outcome" => outcome}, socket)
      when outcome in ["yes", "no"] do
    account_id = socket.assigns[:current_account_id]

    with :ok <- SharedRateLimit.check(account_id, :resolve_submit),
         :ok <- RateLimit.check(:resolve_submit) do
      do_submit_resolution(socket, outcome)
    else
      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, Messages.rate_limited(:resolution))}
    end
  end

  def handle_event("resolve:submit", _params, socket) do
    {:noreply, put_flash(socket, :error, Messages.invalid_outcome())}
  end

  def handle_event("paginate", %{"page" => page}, socket) do
    page = parse_page(page)

    new_page =
      Paginator.clamp_page(page, length(socket.assigns.all_rows), socket.assigns.per_page)

    {:noreply, socket |> assign(:page, new_page) |> assign_positions_slice()}
  end

  def handle_event("paginate:disputes", %{"page" => page}, socket) do
    page = parse_page(page)

    new_page =
      Paginator.clamp_page(page, length(socket.assigns.all_dispute_rows), socket.assigns.per_page)

    {:noreply, socket |> assign(:dispute_page, new_page) |> assign_disputes_slice()}
  end

  def handle_event("paginate:markets", %{"page" => page}, socket) do
    page = parse_page(page)

    new_page =
      Paginator.clamp_page(page, length(socket.assigns.all_market_rows), socket.assigns.per_page)

    {:noreply, socket |> assign(:market_page, new_page) |> assign_markets_slice()}
  end

  @impl true
  def handle_event("claim:open", %{"position-id" => position_id}, socket) do
    case RateLimit.check(:claim_open) do
      :ok ->
        {:noreply,
         socket
         |> assign(:claiming, {:position, position_id})
         |> assign(:claim_step, :entry)
         |> assign(:claim_destination, "")}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, Messages.rate_limited(:claim))}
    end
  end

  def handle_event("creator_lp_claim:open", %{"market-id" => market_id}, socket) do
    case RateLimit.check(:claim_open) do
      :ok ->
        {:noreply,
         socket
         |> assign(:claiming, {:creator_lp, market_id})
         |> assign(:claim_step, :entry)
         |> assign(:claim_destination, "")}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, Messages.rate_limited(:claim))}
    end
  end

  def handle_event("claim:cancel", _params, socket) do
    {:noreply, close_claim(socket)}
  end

  def handle_event(
        "claim:review",
        %{"claim" => %{"destination" => destination}},
        socket
      ) do
    trimmed = String.trim(destination) |> strip_monero_uri()

    cond do
      trimmed == "" ->
        {:noreply, put_flash(socket, :error, Messages.destination_required())}

      String.length(trimmed) > Address.max_input_length() ->
        {:noreply, put_flash(socket, :error, Messages.destination_too_long())}

      not Address.valid?(trimmed) ->
        {:noreply,
         socket
         |> assign(:claim_destination, trimmed)
         |> put_flash(:error, Messages.destination_invalid_detail())}

      true ->
        {:noreply,
         socket
         |> assign(:claim_destination, trimmed)
         |> assign(:claim_step, :confirm)}
    end
  end

  def handle_event("claim:back", _params, socket) do
    {:noreply, assign(socket, :claim_step, :entry)}
  end

  def handle_event("claim:submit", _params, socket) do
    account_id = socket.assigns.current_account_id
    target = socket.assigns.claiming
    destination = socket.assigns.claim_destination
    kind = claim_rate_limit_kind(target)

    # Shared (account-scoped) check first — it's the hard ceiling
    # that survives WebSocket reconnects. Per-socket check after
    # for the friendly "slow down" UX inside one session. Dispute
    # claims have their own bucket so a flurry of dispute claim
    # attempts doesn't starve out a parallel position-claim flow
    # for the same account.
    with :ok <- SharedRateLimit.check(account_id, kind),
         :ok <- RateLimit.check(kind) do
      if target == nil or not Address.valid?(destination) do
        {:noreply, put_flash(socket, :error, Messages.invalid_claim_state())}
      else
        do_claim(socket, target, destination)
      end
    else
      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, Messages.rate_limited(:claim))}
    end
  end

  # Catch-all so a forged client frame for an event this LiveView
  # doesn't recognise becomes a silent no-op rather than a process
  # crash that tears down the WebSocket.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp claim_rate_limit_kind({:dispute, _}), do: :dispute_claim_submit
  defp claim_rate_limit_kind(_), do: :claim_submit

  defp do_submit_resolution(socket, outcome) do
    market_id = socket.assigns.resolving_market_id
    account_id = socket.assigns.current_account_id

    if market_id == nil do
      {:noreply, put_flash(socket, :error, Messages.no_market_selected_for_resolution())}
    else
      case Facade.submit_resolution(account_id, market_id, String.to_existing_atom(outcome)) do
        {:ok, _market} ->
          {:noreply,
           socket
           |> assign(:resolving_market_id, nil)
           |> put_flash(:success, Messages.resolution_submitted_short())
           |> load_state()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, resolve_error_message(reason))}
      end
    end
  rescue
    PerpWalk.Guards.SystemHaltedError ->
      {:noreply, put_flash(socket, :error, Messages.venue_halted())}
  end

  defp do_claim(socket, {:position, position_id}, destination) do
    case Facade.claim_payout(position_id, socket.assigns.current_account_id, destination) do
      {:ok, _request} ->
        {:noreply,
         socket
         |> close_claim()
         |> put_flash(:success, Messages.claim_submitted())
         |> load_state()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, claim_error_message(reason))}
    end
  rescue
    PerpWalk.Guards.SystemHaltedError ->
      {:noreply, put_flash(socket, :error, Messages.venue_halted())}
  end

  defp do_claim(socket, {:dispute, market_id}, destination) do
    account_id = socket.assigns.current_account_id

    case Facade.claim_dispute_refund(account_id, market_id, destination) do
      {:ok, _request} ->
        {:noreply,
         socket
         |> close_claim()
         |> put_flash(:success, Messages.claim_submitted())
         |> load_state()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, claim_error_message(reason))}
    end
  rescue
    PerpWalk.Guards.SystemHaltedError ->
      {:noreply, put_flash(socket, :error, Messages.venue_halted())}
  end

  defp do_claim(socket, {:creator_lp, market_id}, destination) do
    account_id = socket.assigns.current_account_id

    case Facade.claim_creator_lp_return(account_id, market_id, destination) do
      {:ok, _request} ->
        {:noreply,
         socket
         |> close_claim()
         |> put_flash(:success, Messages.claim_submitted())
         |> load_state()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, claim_error_message(reason))}
    end
  rescue
    PerpWalk.Guards.SystemHaltedError ->
      {:noreply, put_flash(socket, :error, Messages.venue_halted())}
  end

  defp close_claim(socket) do
    socket
    |> assign(:claiming, nil)
    |> assign(:claim_step, :entry)
    |> assign(:claim_destination, "")
  end

  # Wallet apps sometimes copy as `monero:4abc...?tx_amount=X`. Strip the
  # URI prefix and any query string so the bare address gets validated.
  defp strip_monero_uri("monero:" <> rest), do: rest |> String.split("?", parts: 2) |> hd()
  defp strip_monero_uri(other), do: other

  @impl true
  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  # Account-scoped events: only re-render when the event is for the
  # viewer. Foreign-account events become explicit no-ops so the
  # `load_state` call doesn't fire — closing both the cost amplifier
  # ("every payout fires a re-render in every live portfolio") and
  # the timing oracle ("response latency reveals some other user
  # just claimed"). The MarketsEvents structs carry `:account_id`
  # directly; the federation PayoutRequested struct also carries it.
  def handle_info(%{account_id: aid} = msg, %{assigns: %{current_account_id: aid}} = socket)
      when is_binary(aid) do
    case Helpers.handle_pip_event(msg, socket) do
      :pass -> {:noreply, load_state(socket)}
      handled -> handled
    end
  end

  def handle_info(%{account_id: other}, socket) when is_binary(other) do
    {:noreply, socket}
  end

  # PayoutFailed carries only `request_id` — resolve to the owning
  # account via Store lookup and flash the current viewer if the
  # failure is theirs. The row itself falls back to the CLAIM button
  # via `payable?/1` because the position is still `:settled_winner` /
  # `:refunded` (only the payout row transitions to `:failed`).
  def handle_info(%FederationEvents.PayoutFailed{request_id: request_id}, socket) do
    if own_payout?(request_id, socket) do
      {:noreply,
       socket
       |> put_flash(:error, Messages.claim_failed_generic())
       |> load_state()}
    else
      {:noreply, socket}
    end
  end

  # Events without an `:account_id` field: market-wide (MarketSettled,
  # MarketVoided) or carry only a `position_id` / `request_id` that
  # would need a Store lookup to scope. Keep the existing reload —
  # the per-user filtering happens at `load_state` time anyway, and
  # the re-render cost is bounded by the position count of THIS
  # viewer. Not a timing oracle for THESE events because they don't
  # carry per-recipient info that would change the response shape.
  def handle_info(msg, socket) do
    case Helpers.handle_pip_event(msg, socket) do
      :pass -> {:noreply, load_state(socket)}
      handled -> handled
    end
  end

  defp own_payout?(request_id, socket) when is_binary(request_id) do
    aid = socket.assigns[:current_account_id]

    with true <- is_binary(aid),
         {:ok, %Payout{account_id: ^aid}} <- FederationFacade.get_request(request_id) do
      true
    else
      _ -> false
    end
  end

  # --- Internal ---

  defp subscribe_to_events do
    for module <- @position_event_topics ++ @federation_event_topics do
      EventBus.subscribe(module)
    end
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval_ms)

  defp load_state(socket) do
    account_id = socket.assigns.current_account_id
    per_page = socket.assigns.per_page

    # One payout-request scan per render, grouped for O(1) per-row
    # lookups — previously every dispute and market row ran its own
    # full list_requests() scan, so render cost was rows × table.
    payouts_by_pair = group_requests_by_account_market()

    all_rows =
      account_id
      |> Facade.list_positions_for_account()
      |> Enum.map(&decorate/1)
      |> Enum.sort_by(& &1.position.created_at, {:desc, DateTime})

    # Drop pending (`:awaiting_deposit`) and cancelled disputes —
    # they're either mid-modal or the user dismissed without funding.
    # The user only wants to see disputes they actually staked on.
    all_dispute_rows =
      account_id
      |> Facade.list_disputes_for_account()
      |> Enum.reject(&(&1.status in [:awaiting_deposit, :cancelled]))
      |> Enum.map(&decorate_dispute(&1, payouts_by_pair))
      |> Enum.sort_by(& &1.dispute.created_at, {:desc, DateTime})

    all_market_rows =
      account_id
      |> Facade.list_markets_for_creator()
      |> Enum.map(&decorate_market(&1, payouts_by_pair))
      |> Enum.sort_by(& &1.market.created_at, {:desc, DateTime})

    socket
    |> assign(:all_rows, all_rows)
    |> assign(:total_rows, length(all_rows))
    |> assign(:all_dispute_rows, all_dispute_rows)
    |> assign(:total_dispute_rows, length(all_dispute_rows))
    |> assign(:all_market_rows, all_market_rows)
    |> assign(:total_market_rows, length(all_market_rows))
    |> assign(:page, Paginator.clamp_page(socket.assigns.page, length(all_rows), per_page))
    |> assign(
      :dispute_page,
      Paginator.clamp_page(socket.assigns.dispute_page, length(all_dispute_rows), per_page)
    )
    |> assign(
      :market_page,
      Paginator.clamp_page(socket.assigns.market_page, length(all_market_rows), per_page)
    )
    |> assign(:now, DateTime.utc_now())
    |> assign_positions_slice()
    |> assign_disputes_slice()
    |> assign_markets_slice()
  end

  defp assign_positions_slice(socket) do
    rows = Paginator.slice(socket.assigns.all_rows, socket.assigns.page, socket.assigns.per_page)
    assign(socket, :rows, rows)
  end

  defp assign_disputes_slice(socket) do
    rows =
      Paginator.slice(socket.assigns.all_dispute_rows, socket.assigns.dispute_page, socket.assigns.per_page)

    assign(socket, :dispute_rows, rows)
  end

  defp assign_markets_slice(socket) do
    rows =
      Paginator.slice(socket.assigns.all_market_rows, socket.assigns.market_page, socket.assigns.per_page)

    assign(socket, :market_rows, rows)
  end

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  defp parse_page(value) when is_integer(value) and value >= 1, do: value
  defp parse_page(_), do: 1

  defp decorate(position) do
    market =
      case Facade.get_market(position.market_id) do
        {:ok, m} -> m
        _ -> nil
      end

    %{position: position, market: market, payout: latest_payout(position.id)}
  end

  defp decorate_dispute(%Dispute{} = dispute, payouts_by_pair) do
    market =
      case Facade.get_market(dispute.market_id) do
        {:ok, m} -> m
        _ -> nil
      end

    %{dispute: dispute, market: market, payout: latest_dispute_payout(dispute, payouts_by_pair)}
  end

  defp decorate_market(%Market{} = market, payouts_by_pair) do
    %{market: market, payout: latest_creator_lp_payout(market, payouts_by_pair)}
  end

  defp latest_payout(position_id) do
    case FederationFacade.list_requests_for_position(position_id) do
      [] ->
        nil

      requests ->
        Enum.max_by(requests, & &1.created_at, DateTime)
    end
  end

  defp group_requests_by_account_market do
    Enum.group_by(FederationFacade.list_requests(), fn req ->
      {req.account_id, req.market_id}
    end)
  end

  defp latest_dispute_payout(%Dispute{account_id: account_id, market_id: market_id}, payouts_by_pair) do
    payouts_by_pair
    |> Map.get({account_id, market_id}, [])
    |> Enum.filter(&Payout.dispute_refund?/1)
    |> case do
      [] -> nil
      reqs -> Enum.max_by(reqs, & &1.created_at, DateTime)
    end
  end

  defp latest_creator_lp_payout(%Market{id: market_id, creator_account_id: creator}, payouts_by_pair) do
    payouts_by_pair
    |> Map.get({creator, market_id}, [])
    |> Enum.filter(&Payout.creator_lp_return?/1)
    |> case do
      [] -> nil
      reqs -> Enum.max_by(reqs, & &1.created_at, DateTime)
    end
  end

  defp claim_error_message(:position_not_found), do: Messages.position_not_found()
  defp claim_error_message(:market_not_found), do: Messages.market_not_found()
  defp claim_error_message(:not_payable), do: Messages.position_not_payable()
  defp claim_error_message(:dispute_not_found), do: Messages.dispute_not_found()
  defp claim_error_message(:not_refundable), do: Messages.dispute_not_refundable()
  defp claim_error_message(:refund_already_pending), do: Messages.refund_already_pending()
  defp claim_error_message(:payout_already_pending), do: Messages.payout_already_pending()
  defp claim_error_message(:not_owner), do: Messages.dispute_not_owner()
  defp claim_error_message(:invalid_destination), do: Messages.destination_invalid()
  defp claim_error_message(:not_creator), do: Messages.only_creator_for_lp_return()
  defp claim_error_message(:market_not_returnable), do: Messages.market_not_lp_returnable()
  defp claim_error_message(:lp_return_already_pending), do: Messages.lp_return_pending()
  defp claim_error_message(:already_paid_out), do: Messages.lp_already_returned()
  defp claim_error_message(reason) when is_atom(reason), do: Messages.claim_failed(reason)
  defp claim_error_message(_), do: Messages.claim_failed_generic()

  defp resolve_error_message(:market_not_found), do: Messages.market_not_found()
  defp resolve_error_message(:not_creator), do: Messages.only_creator_can_resolve()
  defp resolve_error_message(:invalid_transition), do: Messages.market_no_longer_resolvable()
  defp resolve_error_message(:invalid_outcome_for_creator), do: Messages.invalid_outcome_for_creator()

  defp resolve_error_message(reason) when is_atom(reason), do: Messages.resolution_failed(reason)

  defp payable?(%{status: :settled_winner}), do: true
  defp payable?(%{status: :refunded}), do: true
  defp payable?(_), do: false

  defp payout_amount(%{position: pos, market: %{unit_size: unit}}) do
    Facade.position_payout(pos, unit)
  end

  defp payout_amount(_), do: 0

  defp short_txid(nil), do: ""

  defp short_txid(txid) when is_binary(txid) and byte_size(txid) > 16 do
    "#{String.slice(txid, 0, 8)}…#{String.slice(txid, -8, 8)}"
  end

  defp short_txid(txid), do: txid

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <Helpers.app_header current_handle={@current_handle} current_page={:portfolio} />
    <Helpers.app_sub_nav current_handle={@current_handle} current_page={:portfolio} />

    <main class="bp-root">
      <h1 class="bp-sr-only">{Messages.sr_portfolio()}</h1>
      <div class="bp-page-wide bp-fill-page">
        <.announcements items={Helpers.announcements()} />

        <div class="bp-grid cols-2 bp-fill-page">
          <.panel title={Messages.panel_my_markets()}>
            <div class="bp-table-scroll">
              <Helpers.table_empty_state :if={@total_market_rows == 0} message={Messages.empty_no_markets()} />

              <table :if={@total_market_rows > 0} class="bp-data-table">
                <thead>
                  <tr>
                    <th scope="col" class="bp-cell-auto">{Messages.column_market()}</th>
                    <th scope="col" class="bp-cell-label">{Messages.column_status()}</th>
                    <th scope="col" class="bp-cell-wide">{Messages.column_action_txid()}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- @market_rows}>
                    <td class="bp-cell-auto" title={row.market.description}>
                      <a href={"/markets/#{row.market.id}"} class="bp-cell-link">{row.market.description}</a>
                    </td>
                    <td class="bp-cell-label">
                      <span class={"bp-pill #{market_status_variant(row.market.status)}"}>
                        {Helpers.state_label(row.market) |> elem(0) |> String.downcase()}
                      </span>
                    </td>
                    <td class="bp-cell-wide">
                      <.market_action_cell row={row} />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <Paginator.paginator
              page={@market_page}
              total={@total_market_rows}
              per_page={@per_page}
              event="paginate:markets"
              label={Messages.paginator_label_my_markets()}
            />
          </.panel>

          <.panel title={Messages.panel_my_disputes()}>
            <div class="bp-table-scroll">
              <Helpers.table_empty_state :if={@total_dispute_rows == 0} message={Messages.empty_no_disputes()} />

              <table :if={@total_dispute_rows > 0} class="bp-data-table">
                <thead>
                  <tr>
                    <th scope="col" class="bp-cell-auto">{Messages.column_market()}</th>
                    <th scope="col" class="bp-cell-amount">{Messages.column_stake()}</th>
                    <th scope="col" class="bp-cell-amount">{Messages.column_refund()}</th>
                    <th scope="col" class="bp-cell-wide">{Messages.column_action_txid()}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- @dispute_rows}>
                    <td class="bp-cell-auto" title={row.market && row.market.description}>
                      <a :if={row.market} href={"/markets/#{row.market.id}"} class="bp-cell-link">
                        {row.market.description}
                      </a>
                      <span :if={!row.market} class="bp-empty-cell">—</span>
                    </td>
                    <td class="bp-cell-amount">
                      {Helpers.format_xmr(row.dispute.stake_amount_piconeros)}
                    </td>
                    <td class="bp-cell-amount">
                      <%= if Dispute.refund_amount_piconeros(row.dispute) > 0 do %>
                        {Helpers.format_xmr(Dispute.refund_amount_piconeros(row.dispute))}
                      <% else %>
                        <span class="bp-empty-cell">—</span>
                      <% end %>
                    </td>
                    <td class="bp-cell-wide">
                      <.dispute_action_cell row={row} />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <Paginator.paginator
              page={@dispute_page}
              total={@total_dispute_rows}
              per_page={@per_page}
              event="paginate:disputes"
              label={Messages.paginator_label_my_disputes()}
            />
          </.panel>
        </div>

        <.panel title={Messages.panel_my_positions()} class="bp-fill-page">
          <div class="bp-table-scroll">
            <Helpers.table_empty_state :if={@total_rows == 0} message={Messages.empty_no_positions()} />

            <table :if={@total_rows > 0} class="bp-data-table">
              <thead>
                <tr>
                  <th scope="col" class="bp-cell-auto">{Messages.column_market()}</th>
                  <th scope="col" class="bp-cell-num">{Messages.column_side()}</th>
                  <th scope="col" class="bp-cell-num">{Messages.column_contracts()}</th>
                  <th scope="col" class="bp-cell-amount">{Messages.column_paid()}</th>
                  <th scope="col" class="bp-cell-label">{Messages.column_status()}</th>
                  <th scope="col" class="bp-cell-wide">{Messages.column_action_txid()}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @rows}>
                  <td class="bp-cell-auto" title={row.market && row.market.description}>
                    <a :if={row.market} href={"/markets/#{row.market.id}"} class="bp-cell-link">
                      {row.market.description}
                    </a>
                    <span :if={!row.market} class="bp-empty-cell">—</span>
                  </td>
                  <td class="bp-cell-num">
                    <Badges.side_pill side={row.position.side} />
                  </td>
                  <td class="bp-cell-num">{row.position.contracts}</td>
                  <td class="bp-cell-amount">
                    {Helpers.format_xmr(row.position.amount_paid)}
                  </td>
                  <td class="bp-cell-label">
                    <Badges.position_status_pill status={row.position.status} />
                  </td>
                  <td class="bp-cell-wide">
                    <.action_cell row={row} />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <Paginator.paginator
            page={@page}
            total={@total_rows}
            per_page={@per_page}
            label={Messages.paginator_label_my_positions()}
          />
        </.panel>
      </div>

      <Helpers.app_footer health={@health} />
    </main>

    <.claim_modal
      :if={@claiming}
      row={find_target_row(@all_rows, @all_dispute_rows, @all_market_rows, @claiming)}
      step={@claim_step}
      destination={@claim_destination}
      claiming={@claiming}
    />

    <.resolve_modal
      :if={@resolving_market_id}
      market={find_market(@market_rows, @resolving_market_id)}
    />
    """
  end

  attr(:row, :map, required: true)

  defp market_action_cell(assigns) do
    ~H"""
    <.payout_status_chrome payout={@row.payout}>
      <%= cond do %>
        <% @row.market.status == :expired -> %>
          <button
            type="button"
            class="bp-btn bp-btn-sm bp-btn-primary"
            phx-click="resolve:open"
            phx-value-market-id={@row.market.id}
            phx-throttle="500"
          >
            {Messages.action_resolve()}
          </button>
        <% lp_returnable?(@row.market) -> %>
          <button
            type="button"
            class="bp-btn bp-btn-sm bp-btn-primary"
            phx-click="creator_lp_claim:open"
            phx-value-market-id={@row.market.id}
            phx-throttle="500"
          >
            {Messages.action_claim()}
          </button>
        <% @row.market.creator_lp_paid_out_at && @row.payout -> %>
          <.payout_status_cell payout={@row.payout} label={Messages.payout_status_paid_out()} />
        <% @row.market.creator_lp_paid_out_at -> %>
          <span class="bp-label">{Messages.payout_status_paid_out()}</span>
        <% true -> %>
          <span class="bp-empty-cell">—</span>
      <% end %>
    </.payout_status_chrome>
    """
  end

  # Markets where the creator can claim their liquidity return.
  # Settled markets pay out `pool.<winner> × unit_size`; voided
  # markets refund the full deposit.
  defp lp_returnable?(%{status: status, creator_lp_paid_out_at: nil})
       when status in [:settled, :voided],
       do: true

  defp lp_returnable?(_), do: false

  defp market_status_variant(:active), do: "active"
  defp market_status_variant(:expired), do: "warning"
  defp market_status_variant(:resolving), do: "warning"
  defp market_status_variant(:settled), do: "active"
  defp market_status_variant(:rejected), do: "critical"
  defp market_status_variant(:voided), do: "muted"
  defp market_status_variant(_), do: "muted"

  attr(:row, :map, required: true)

  defp dispute_action_cell(assigns) do
    ~H"""
    <.payout_status_chrome payout={@row.payout}>
      <%= cond do %>
        <% @row.dispute.status in [:refunded_full, :refunded_partial] -> %>
          <.payout_status_cell payout={@row.payout} label={Messages.payout_status_paid_out()} />
        <% refundable?(@row.dispute) -> %>
          <button
            type="button"
            class="bp-btn bp-btn-sm bp-btn-primary"
            phx-click="dispute_claim:open"
            phx-value-market-id={@row.dispute.market_id}
            phx-throttle="500"
          >
            {Messages.action_claim()}
          </button>
        <% true -> %>
          <span class="bp-empty-cell">—</span>
      <% end %>
    </.payout_status_chrome>
    """
  end

  defp refundable?(%Dispute{status: :resolved_for}), do: true
  defp refundable?(%Dispute{status: :resolved_against}), do: true
  defp refundable?(_), do: false

  attr(:row, :map, required: true)

  defp action_cell(assigns) do
    ~H"""
    <.payout_status_chrome payout={@row.payout}>
      <%= cond do %>
        <% @row.position.status == :paid_out -> %>
          <.payout_status_cell payout={@row.payout} label={Messages.payout_status_paid_out()} />
        <% payable?(@row.position) -> %>
          <button
            type="button"
            class="bp-btn bp-btn-sm bp-btn-primary"
            phx-click="claim:open"
            phx-value-position-id={@row.position.id}
            phx-throttle="500"
          >
            {Messages.action_claim()}
          </button>
        <% true -> %>
          <span class="bp-empty-cell">—</span>
      <% end %>
    </.payout_status_chrome>
    """
  end

  attr(:payout, :any, required: true)
  slot(:inner_block, required: true)

  # In-flight payout states are identical for position payouts and
  # dispute refunds, so they share this chrome. Callers pass the
  # post-in-flight terminal action (claim button, paid-out label,
  # or an em-dash) as the inner block.
  #
  # `:paid_out` is handled here rather than in the inner block so
  # the render survives a transient cross-domain replication lag:
  # Federation.Store's `:payout_requested` (:paid_out) entry can
  # apply on a follower before Markets.Store's `:position_paid_out`
  # entry does (separate Replicator cursors), and without this the
  # follower's LiveView briefly renders the CLAIM button after the
  # `PayoutSubmitted` event triggers a reload while
  # `payable?(position)` is still true.
  defp payout_status_chrome(assigns) do
    ~H"""
    <%= cond do %>
      <% @payout && @payout.status in [:submitted, :paid_out] -> %>
        <.payout_status_cell payout={@payout} label={Messages.payout_status_submitted()} />
      <% @payout && @payout.status in [:pending, :rules_passed, :signing] -> %>
        <span class="bp-pill muted">{Messages.payout_status_queued()}</span>
      <% @payout && @payout.status == :awaiting_operator -> %>
        <span
          class="bp-pill critical"
          title={Messages.payout_needs_review_tooltip()}
        >
          {Messages.payout_status_needs_review()}
        </span>
      <% @payout && @payout.status == :settlement_unknown -> %>
        <span
          class="bp-pill warning"
          title={Messages.payout_under_review_tooltip()}
        >
          {Messages.payout_status_under_review()}
        </span>
      <% true -> %>
        {render_slot(@inner_block)}
    <% end %>
    """
  end

  attr(:payout, :map, required: true)
  attr(:label, :string, required: true)

  # Renders just the txid in the ACTION column. The status badge in
  # the STATUS column already communicates :paid_out / :submitted,
  # so the action column doesn't need to repeat it — only the txid
  # is meaningful here (link target, copy reference). `label` is
  # retained as the tooltip and the empty-state fallback so callers
  # can still distinguish "paid out, no txid" from "submitted, no
  # txid" if a payout has lost its txid for any reason.
  defp payout_status_cell(assigns) do
    ~H"""
    <span title={@payout.payout_txid || @label}>
      <%= if @payout.payout_txid do %>
        <span class="bp-mono bp-color-dim">{short_txid(@payout.payout_txid)}</span>
      <% else %>
        <span class="bp-empty-cell">—</span>
      <% end %>
    </span>
    """
  end

  attr(:row, :any, required: true)
  attr(:step, :atom, required: true)
  attr(:destination, :string, required: true)
  attr(:claiming, :any, required: true)

  defp claim_modal(%{step: :entry} = assigns) do
    ~H"""
    <Modal.modal
      title={Messages.modal_title_claim()}
      title_id="claim-modal-title"
      click_away="claim:cancel"
    >
      <form id="claim-review-form" phx-submit="claim:review" phx-throttle="500">
        <div class="bp-field">
          <label for="claim-destination" class="bp-label">{Messages.field_destination_label()}</label>
          <input
            id="claim-destination"
            type="text"
            name="claim[destination]"
            class="bp-input"
            placeholder={Messages.field_destination_placeholder()}
            value={@destination}
            autocomplete="off"
            spellcheck="false"
            phx-debounce="300"
            required
          />
        </div>

        <div class="bp-btn-row">
          <button type="button" class="bp-btn bp-btn-default" phx-click="claim:cancel">
            {Messages.action_cancel()}
          </button>
          <button type="submit" class="bp-btn bp-btn-primary" phx-disable-with={Messages.busy_reviewing()}>
            {Messages.action_review()}
          </button>
        </div>
      </form>
    </Modal.modal>
    """
  end

  defp claim_modal(%{step: :confirm} = assigns) do
    ~H"""
    <Modal.modal
      title={Messages.modal_title_confirm()}
      title_id="claim-confirm-title"
      click_away="claim:cancel"
    >
      <div class="bp-color-warn bp-callout">
        <strong>{Messages.warning_irreversible_lead()}</strong> {Messages.warning_irreversible_body()}
      </div>

      <div :if={@row} class="bp-box bp-stack-md">
        <div class="pw-claim-confirm-row">
          <span class="bp-label">{Messages.confirm_label_amount()}</span>
          <span class="pw-claim-confirm-value pw-claim-confirm-amount">
            {Helpers.format_xmr(target_amount(@row, @claiming))}
          </span>
        </div>
        <div class="pw-claim-confirm-row">
          <span class="bp-label">{Messages.confirm_label_destination()}</span>
          <code class="pw-claim-confirm-value pw-claim-confirm-address" title={@destination}>
            {Helpers.short_address(@destination)}
          </code>
        </div>
        <div class="pw-claim-confirm-row">
          <span class="bp-label">{Messages.confirm_label_market()}</span>
          <span class="pw-claim-confirm-value">
            {@row.market && @row.market.description}
          </span>
        </div>
      </div>

      <form id="claim-submit-form" phx-submit="claim:submit" phx-throttle="1000">
        <div class="bp-btn-row">
          <button
            type="button"
            class="bp-btn bp-btn-default"
            phx-click="claim:back"
            phx-throttle="250"
          >
            {Messages.action_back()}
          </button>
          <button
            type="submit"
            class="bp-btn bp-btn-primary"
            phx-disable-with={Messages.busy_submitting()}
          >
            {Messages.action_confirm_and_send()}
          </button>
        </div>
      </form>
    </Modal.modal>
    """
  end

  defp find_target_row(rows, _disputes, _markets, {:position, position_id}),
    do: Enum.find(rows, fn r -> r.position.id == position_id end)

  defp find_target_row(_rows, disputes, _markets, {:dispute, market_id}),
    do: Enum.find(disputes, fn r -> r.dispute.market_id == market_id end)

  defp find_target_row(_rows, _disputes, markets, {:creator_lp, market_id}),
    do: Enum.find(markets, fn r -> r.market.id == market_id end)

  defp find_target_row(_rows, _disputes, _markets, _), do: nil

  defp find_market(market_rows, market_id) do
    case Enum.find(market_rows, fn row -> row.market.id == market_id end) do
      %{market: market} -> market
      _ -> nil
    end
  end

  defp target_amount(row, {:dispute, _}),
    do: Dispute.refund_amount_piconeros(row.dispute)

  defp target_amount(row, {:creator_lp, _}),
    do: Facade.creator_lp_return_amount(row.market)

  defp target_amount(row, _), do: payout_amount(row)

  attr(:market, :any, required: true)

  defp resolve_modal(assigns) do
    ~H"""
    <Modal.modal
      title={Messages.modal_title_resolve()}
      title_id="resolve-modal-title"
      click_away="resolve:cancel"
    >
      <p :if={@market} class="bp-lead">
        <em>{@market.description}</em>
      </p>
      <p :if={@market} class="bp-help">
        {@market.resolution_criterion}
      </p>

      <div class="bp-color-warn bp-callout">
        <strong>{Messages.warning_resolve_honestly_lead()}</strong> {Messages.warning_resolve_honestly_body()}
      </div>

      <div class="bp-btn-row bp-btn-row-wrap">
        <button
          type="button"
          class="bp-btn bp-btn-default"
          phx-click="resolve:cancel"
          phx-throttle="250"
        >
          {Messages.action_cancel()}
        </button>
        <button
          type="button"
          class="bp-btn bp-btn-default"
          phx-click="resolve:submit"
          phx-value-outcome="no"
          phx-throttle="500"
        >
          {Messages.action_outcome_no()}
        </button>
        <button
          type="button"
          class="bp-btn bp-btn-primary"
          phx-click="resolve:submit"
          phx-value-outcome="yes"
          phx-throttle="500"
        >
          {Messages.action_outcome_yes()}
        </button>
      </div>
    </Modal.modal>
    """
  end
end
