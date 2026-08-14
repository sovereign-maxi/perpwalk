defmodule PerpWalkAdminWeb.Live.Dashboard do
  @moduledoc """
  Dashboard page — venue stats at a glance.

  Top row (4-col): the venue panels.

    * **Markets** — active / pending / awaiting resolution / in
      dispute window / total
    * **Activity** — 24 h volume, 24 h trade count, pool TVL
    * **Wallet & Signing** — wallet status, balance, unlocked,
      address, current WAL seq, 24 h signing count + last sign time
    * **House Income** — total / slashes / burns / spread / drawn / available

  Bottom row (2-col, flex-fills down to the footer):

    * **Top Active Markets** — active markets by 24 h volume
    * **Recent Settlements** — settled markets, most recent first

  Both bottom tables use the standard data-table + paginator
  pattern from `/markets`.

  Polls every 5 s; subscribes to the relevant Markets / Federation
  / Reserves event set so the relevant numbers refresh on the
  underlying state change instead of waiting for the next tick.
  Destructive ops stay in `iex --remsh`.
  """

  use PerpWalkAdminWeb, :live_view

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Events.Reserves, as: ReservesEvents
  alias PerpWalk.Events.Telemetry, as: TelemetryEvents
  alias PerpWalk.Federation.Facade, as: FederationFacade
  alias PerpWalk.Federation.Store, as: FederationStore
  alias PerpWalk.Markets.Facade
  alias PerpWalk.Markets.Store, as: MarketsStore
  alias PerpWalk.Monero.Facade, as: MoneroFacade
  alias PerpWalkAdminWeb.Live.Helpers
  alias PerpWalkAdminWeb.Messages
  alias PerpWalkWeb.Live.Components.Paginator
  alias PerpWalkWeb.Live.Helpers, as: WebHelpers

  @tick_interval_ms 5_000

  @per_page 25

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
    # Halt-transition events drive the status label in the sub-nav
    # stats bar. Without this the label lags by up to @tick_interval_ms
    # (5s) after a halt clear because refresh only lands on tick.
    TelemetryEvents.SystemStatusChanged
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
     |> assign(:per_page, @per_page)
     |> assign(:top_active_page, 1)
     |> assign(:settlements_page, 1)
     |> refresh_snapshot()}
  end

  @impl true
  def handle_event("paginate:top_active", %{"page" => page}, socket) do
    page = Paginator.clamp_page(parse_page(page), socket.assigns.top_active_count, @per_page)
    {:noreply, socket |> assign(:top_active_page, page) |> assign_table_slices()}
  end

  def handle_event("paginate:settlements", %{"page" => page}, socket) do
    page = Paginator.clamp_page(parse_page(page), socket.assigns.settlements_count, @per_page)
    {:noreply, socket |> assign(:settlements_page, page) |> assign_table_slices()}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  defp parse_page(value) when is_integer(value) and value >= 1, do: value
  defp parse_page(_), do: 1

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_interval_ms)
    {:noreply, refresh_snapshot(socket)}
  end

  def handle_info(event, socket) when is_struct(event) do
    {:noreply, refresh_snapshot(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh_snapshot(socket) do
    markets = safe(fn -> Facade.list_markets() end, [])
    status_counts = count_by_status(markets)
    backlog_count = Enum.count(markets, &Facade.status_awaiting_operator_action?(&1.status))

    {volume_24h, positions_24h} = activity_24h(markets)
    tvl = total_tvl(markets)

    income = safe(fn -> Facade.federation_ledger() end, empty_income())
    drawn = safe(fn -> FederationFacade.federation_income_drawn() end, 0)
    available = max(0, income.total_piconeros - drawn)

    pending_count =
      Map.get(status_counts, :pending, 0) +
        Map.get(status_counts, :awaiting_deposit, 0)

    wallet = wallet_snapshot()
    wal = safe(fn -> MarketsStore.wal_info() end, %{entry_count: 0, last_seq: 0})
    signing = safe(fn -> FederationStore.signing_stats() end, %{signs_window: 0, last_sign_at: nil})

    recent_settlements = recent_settlements(markets)
    top_active = top_active_markets(markets)

    socket
    |> assign(:sub_nav_stats, Helpers.sub_nav_stats())
    |> assign(:footer_pips, Helpers.footer_pips())
    |> assign(:total_markets, length(markets))
    |> assign(:active_markets, Map.get(status_counts, :active, 0))
    |> assign(:pending_markets, pending_count)
    |> assign(:expired_markets, Map.get(status_counts, :expired, 0))
    |> assign(:resolving_markets, Map.get(status_counts, :resolving, 0))
    |> assign(:backlog_count, backlog_count)
    |> assign(:tvl_xmr, WebHelpers.format_xmr_compact(tvl))
    |> assign(:volume_24h_xmr, WebHelpers.format_xmr_compact(volume_24h))
    |> assign(:positions_24h, positions_24h)
    |> assign(:income_total_xmr, WebHelpers.format_xmr_compact(income.total_piconeros))
    |> assign(:income_slashed_xmr, WebHelpers.format_xmr_compact(income.slashed_piconeros))
    |> assign(:income_burned_xmr, WebHelpers.format_xmr_compact(income.burned_piconeros))
    |> assign(:income_spread_xmr, WebHelpers.format_xmr_compact(income.federation_spread_piconeros))
    |> assign(:income_drawn_xmr, WebHelpers.format_xmr_compact(drawn))
    |> assign(:income_available_xmr, WebHelpers.format_xmr_compact(available))
    |> assign(:wallet_status, wallet.status)
    |> assign(:wallet_balance, WebHelpers.format_xmr_compact(wallet.balance))
    |> assign(:wallet_unlocked, WebHelpers.format_xmr_compact(wallet.unlocked))
    |> assign(:wallet_address_short, wallet.address_short)
    |> assign(:wal_seq, wal.last_seq)
    |> assign(:signs_24h, signing.signs_window)
    |> assign(:last_sign_label, format_relative(signing.last_sign_at))
    |> assign(:settlements_all, recent_settlements)
    |> assign(:top_active_all, top_active)
    |> assign_table_slices()
  end

  defp assign_table_slices(socket) do
    top_all = socket.assigns.top_active_all
    settled_all = socket.assigns.settlements_all

    top_page = Paginator.clamp_page(socket.assigns.top_active_page, length(top_all), @per_page)

    settlements_page =
      Paginator.clamp_page(socket.assigns.settlements_page, length(settled_all), @per_page)

    socket
    |> assign(:top_active_page, top_page)
    |> assign(:top_active_count, length(top_all))
    |> assign(:top_active_rows, Paginator.slice(top_all, top_page, @per_page))
    |> assign(:settlements_page, settlements_page)
    |> assign(:settlements_count, length(settled_all))
    |> assign(:settlements_rows, Paginator.slice(settled_all, settlements_page, @per_page))
  end

  # --- Recent Settlements ---

  defp recent_settlements(_markets) do
    :settled
    |> Facade.list_markets_by_status()
    |> Enum.reject(&is_nil(&1.resolved_at))
    |> Enum.sort_by(& &1.resolved_at, {:desc, DateTime})
    |> Enum.map(fn m ->
      %{
        id: m.id,
        question: m.description,
        outcome: m.outcome,
        outcome_class: outcome_class(m.outcome),
        volume_xmr:
          m.id
          |> safe_positions()
          |> Enum.reduce(0, fn p, acc -> acc + p.amount_paid end)
          |> WebHelpers.format_xmr_compact(),
        resolved_label: format_relative(m.resolved_at)
      }
    end)
  end

  defp outcome_class(:yes), do: "accent"
  defp outcome_class(:no), do: "muted"
  defp outcome_class(:void), do: "warning"
  defp outcome_class(_), do: "muted"

  # --- Top Active Markets ---

  defp top_active_markets(_markets) do
    active = Facade.list_markets_by_status(:active)
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -86_400, :second)

    active
    |> Enum.map(fn m ->
      positions = safe_positions(m.id)

      recent_positions =
        Enum.filter(positions, fn p -> DateTime.compare(p.created_at, cutoff) == :gt end)

      vol_24h = Enum.reduce(recent_positions, 0, fn p, acc -> acc + p.amount_paid end)
      pool = Enum.reduce(positions, 0, fn p, acc -> acc + p.amount_paid end)

      %{
        id: m.id,
        question: m.description,
        pool_xmr: WebHelpers.format_xmr_compact(pool),
        trades_24h: length(recent_positions),
        volume_24h_xmr: WebHelpers.format_xmr_compact(vol_24h),
        time_to_close: format_time_until(m.expiry, now),
        vol_24h_sort: vol_24h
      }
    end)
    |> Enum.sort_by(& &1.vol_24h_sort, :desc)
  end

  defp format_time_until(nil, _now), do: Messages.time_until(nil)

  defp format_time_until(%DateTime{} = expiry, %DateTime{} = now) do
    Messages.time_until(DateTime.diff(expiry, now, :second))
  end

  # --- Wallet, Format, Support Helpers ---

  defp wallet_snapshot do
    status =
      case safe(fn -> MoneroFacade.health_check() end, {:error, :unknown}) do
        :ok -> Messages.wallet_status_open()
        _ -> Messages.wallet_status_unreachable()
      end

    {balance, unlocked} =
      case safe(fn -> MoneroFacade.balance() end, {:error, :unknown}) do
        {:ok, %{balance: b, unlocked_balance: u}} -> {b, u}
        _ -> {0, 0}
      end

    address_short =
      case safe(fn -> MoneroFacade.address() end, {:error, :unknown}) do
        {:ok, addr} when is_binary(addr) and byte_size(addr) > 16 ->
          String.slice(addr, 0, 8) <> "…" <> String.slice(addr, -8, 8)

        _ ->
          Messages.dash()
      end

    %{status: status, balance: balance, unlocked: unlocked, address_short: address_short}
  end

  defp format_relative(nil), do: Messages.never()

  defp format_relative(%DateTime{} = ts) do
    DateTime.utc_now()
    |> DateTime.diff(ts, :second)
    |> Messages.relative_time()
  end

  defp empty_income do
    %{
      total_piconeros: 0,
      slashed_piconeros: 0,
      burned_piconeros: 0,
      spread_total_piconeros: 0,
      federation_spread_piconeros: 0,
      creator_spread_piconeros: 0,
      slash_count: 0,
      burn_count: 0,
      settled_market_count: 0
    }
  end

  defp count_by_status(markets) do
    Enum.reduce(markets, %{}, fn m, acc ->
      Map.update(acc, m.status, 1, &(&1 + 1))
    end)
  end

  defp activity_24h(markets) do
    cutoff = DateTime.add(DateTime.utc_now(), -86_400, :second)

    Enum.reduce(markets, {0, 0}, fn market, {vol_acc, count_acc} ->
      market.id
      |> safe_positions()
      |> Enum.filter(fn p -> DateTime.compare(p.created_at, cutoff) == :gt end)
      |> Enum.reduce({vol_acc, count_acc}, fn p, {v, c} -> {v + p.amount_paid, c + 1} end)
    end)
  end

  defp total_tvl(markets) do
    in_flight_markets = Enum.filter(markets, &Facade.status_in_flight?(&1.status))
    in_flight_ids = MapSet.new(in_flight_markets, & &1.id)

    wagered =
      Facade.list_all_positions()
      |> Enum.filter(&MapSet.member?(in_flight_ids, &1.market_id))
      |> WebHelpers.pool_wagered_piconeros()

    deposits = Enum.reduce(in_flight_markets, 0, fn m, acc -> acc + m.deposit_amount end)

    live_dispute_stakes =
      Facade.list_disputes_by_status(:live)
      |> Enum.filter(&MapSet.member?(in_flight_ids, &1.market_id))
      |> Enum.reduce(0, fn d, acc -> acc + d.stake_amount_piconeros end)

    wagered + deposits + live_dispute_stakes
  end

  defp safe_positions(market_id) do
    safe(fn -> Facade.list_positions_for_market(market_id) end, [])
  end

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <Helpers.admin_header node_label={@node_label} />
    <Helpers.admin_sub_nav current_page={:dashboard} stats={@sub_nav_stats} />

    <main class="bp-root">
      <div class="bp-page-wide bp-admin-page">
        <.grid cols="4">
          <.panel title={Messages.panel_markets()}>
            <.panel_body>
              <.stat_rows rows={[
                %{label: Messages.stat_label_market_active(), value: "#{@active_markets}", class: "accent"},
                %{label: Messages.stat_label_market_pending(), value: "#{@pending_markets}"},
                %{label: Messages.stat_label_market_awaiting_resolution(), value: "#{@expired_markets}"},
                %{label: Messages.stat_label_market_in_dispute_window(), value: "#{@resolving_markets}"},
                %{label: Messages.stat_label_market_total(), value: "#{@total_markets}"}
              ]} />
            </.panel_body>
          </.panel>

          <.panel title={Messages.panel_activity()}>
            <.panel_body>
              <.stat_rows rows={[
                %{label: Messages.stat_label_volume_24h(), value: @volume_24h_xmr, class: "accent"},
                %{label: Messages.stat_label_trades_24h(), value: "#{@positions_24h}"},
                %{label: Messages.stat_label_pool_tvl(), value: @tvl_xmr}
              ]} />
            </.panel_body>
          </.panel>

          <.panel title={Messages.panel_wallet_and_signing()}>
            <.panel_body>
              <.stat_rows rows={[
                %{label: Messages.stat_label_wallet(), value: @wallet_status, class: wallet_status_class(@wallet_status)},
                %{label: Messages.stat_label_balance(), value: @wallet_balance},
                %{label: Messages.stat_label_unlocked(), value: @wallet_unlocked},
                %{label: Messages.stat_label_address(), value: @wallet_address_short},
                %{label: Messages.stat_label_wal_seq(), value: "#{@wal_seq}"},
                %{label: Messages.stat_label_signs_24h(), value: "#{@signs_24h} (#{@last_sign_label})"}
              ]} />
            </.panel_body>
          </.panel>

          <.panel title={Messages.panel_house_income()}>
            <.panel_body>
              <.stat_rows rows={[
                %{label: Messages.stat_label_income_total(), value: @income_total_xmr},
                %{label: Messages.stat_label_income_slashes(), value: @income_slashed_xmr},
                %{label: Messages.stat_label_income_burns(), value: @income_burned_xmr},
                %{label: Messages.stat_label_income_spread(), value: @income_spread_xmr},
                %{label: Messages.stat_label_income_drawn(), value: @income_drawn_xmr},
                %{label: Messages.stat_label_income_available(), value: @income_available_xmr, class: "accent"}
              ]} />
            </.panel_body>
          </.panel>
        </.grid>

        <.grid cols="2">
          <.panel title={Messages.panel_top_active_markets()}>
            <div class="bp-table-scroll">
              <WebHelpers.table_empty_state :if={@top_active_count == 0} message={Messages.empty_no_active_markets()} />

              <table :if={@top_active_count > 0} class="bp-data-table">
                <thead>
                  <tr>
                    <th scope="col" class="bp-cell-auto">{Messages.column_question()}</th>
                    <th scope="col" class="bp-cell-amount">{Messages.column_pool()}</th>
                    <th scope="col" class="bp-cell-num">{Messages.column_trades_24h()}</th>
                    <th scope="col" class="bp-cell-amount">{Messages.column_volume_24h()}</th>
                    <th scope="col" class="bp-cell-label">{Messages.column_time_to_close()}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- @top_active_rows} id={"top-active-#{row.id}"}>
                    <td class="bp-cell-auto" title={row.question}>{row.question}</td>
                    <td class="bp-cell-amount">{row.pool_xmr}</td>
                    <td class="bp-cell-num">{row.trades_24h}</td>
                    <td class="bp-cell-amount">{row.volume_24h_xmr}</td>
                    <td class="bp-cell-label">{row.time_to_close}</td>
                  </tr>
                </tbody>
              </table>
            </div>

            <Paginator.paginator
              page={@top_active_page}
              total={@top_active_count}
              per_page={@per_page}
              event="paginate:top_active"
              label={Messages.paginator_label_top_active()}
            />
          </.panel>

          <.panel title={Messages.panel_recent_settlements()}>
            <div class="bp-table-scroll">
              <WebHelpers.table_empty_state :if={@settlements_count == 0} message={Messages.empty_no_settlements()} />

              <table :if={@settlements_count > 0} class="bp-data-table">
                <thead>
                  <tr>
                    <th scope="col" class="bp-cell-auto">{Messages.column_question()}</th>
                    <th scope="col" class="bp-cell-label">{Messages.column_outcome()}</th>
                    <th scope="col" class="bp-cell-amount">{Messages.column_volume()}</th>
                    <th scope="col" class="bp-cell-label">{Messages.column_resolved()}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- @settlements_rows} id={"settlement-#{row.id}"}>
                    <td class="bp-cell-auto" title={row.question}>{row.question}</td>
                    <td class="bp-cell-label">
                      <span class={"bp-pill #{row.outcome_class}"}>{Messages.outcome_label(row.outcome)}</span>
                    </td>
                    <td class="bp-cell-amount">{row.volume_xmr}</td>
                    <td class="bp-cell-label">{row.resolved_label}</td>
                  </tr>
                </tbody>
              </table>
            </div>

            <Paginator.paginator
              page={@settlements_page}
              total={@settlements_count}
              per_page={@per_page}
              event="paginate:settlements"
              label={Messages.paginator_label_settlements()}
            />
          </.panel>
        </.grid>
      </div>

      <Helpers.admin_footer pips={@footer_pips} />
    </main>
    """
  end

  defp wallet_status_class(status) do
    if status == Messages.wallet_status_open(), do: "accent", else: "loss"
  end
end
