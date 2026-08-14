defmodule PerpWalkAdminWeb.Live.System do
  @moduledoc """
  System page — host vitals + venue infrastructure telemetry.

  Seven panels across three rows:

    * Row 1 (3-col): **CPU** · **Memory** · **Disk** sparklines, each
      a 60-point series from `Telemetry.Facade.metrics_series/2`
    * Row 2 (2-col): **Replication** (per-peer cursor / peer_tip /
      lag / last-tick) + **Federation** (quorum, designated processor,
      signing detail)
    * Row 3 (2-col): **Monero** (wallet RPC, balance, chain height)
      + **BEAM** (load, memory, ETS, processes, atoms, schedulers,
      run queue, uptime, WAL entries, WAL seq)

  Refreshed on a 5 s tick plus event subscriptions:

    * `SystemStatusChanged` / `TorDown` / `TorDegraded` / `TorRecovered`
      keep the chrome's Status stat current
    * `FederationEvents.QuorumLost/Restored/PeerLost/PeerJoined` /
      `WithdrawalSigned` refresh the Federation panel without waiting
      for the next tick
  """

  use PerpWalkAdminWeb, :live_view

  import PerpWalkAdminWeb.Live.Components.Sparkline

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents
  alias PerpWalk.Events.Telemetry, as: TelemetryEvents
  alias PerpWalk.Federation.Facade, as: FederationFacade
  alias PerpWalk.Federation.Store, as: FederationStore
  alias PerpWalk.Markets.Store, as: MarketsStore
  alias PerpWalk.Monero.Facade, as: MoneroFacade
  alias PerpWalk.Role
  alias PerpWalk.Storage.Replicator
  alias PerpWalk.Telemetry.Facade, as: TelemetryFacade
  alias PerpWalkAdminWeb.Live.Helpers
  alias PerpWalkAdminWeb.Messages
  alias PerpWalkWeb.Live.Helpers, as: WebHelpers

  @tick_interval_ms 5_000

  # Per-tick lag thresholds (in WAL entries) for colouring the
  # Replication panel. Match the alert-rule warning + critical
  # thresholds so the panel colour and the alert state agree.
  @lag_warning_entries 500
  @lag_critical_entries 5_000

  # A peer that hasn't ticked within this window has stalled.
  @tick_stale_seconds 30

  @event_subscriptions [
    TelemetryEvents.SystemStatusChanged,
    TelemetryEvents.TorDown,
    TelemetryEvents.TorDegraded,
    TelemetryEvents.TorRecovered,
    FederationEvents.QuorumLost,
    FederationEvents.QuorumRestored,
    FederationEvents.PeerLost,
    FederationEvents.PeerJoined,
    FederationEvents.WithdrawalSigned
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
     |> refresh_snapshot()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_interval_ms)
    {:noreply, refresh_snapshot(socket)}
  end

  def handle_info(_event, socket) do
    {:noreply, refresh_snapshot(socket)}
  end

  defp refresh_snapshot(socket) do
    sys_metrics = safe(fn -> TelemetryFacade.system_metrics() end, %{})

    socket
    |> assign(:sub_nav_stats, Helpers.sub_nav_stats())
    |> assign(:footer_pips, Helpers.footer_pips())
    |> assign(:sys_metrics, sys_metrics)
    |> assign(:cpu_series, safe(fn -> TelemetryFacade.metrics_series(:cpu_pct, 60) end, []))
    |> assign(:memory_series, safe(fn -> TelemetryFacade.metrics_series(:memory_pct, 60) end, []))
    |> assign(:disk_series, safe(fn -> TelemetryFacade.metrics_series(:disk_pct, 60) end, []))
    |> assign(:wal_info, safe(fn -> MarketsStore.wal_info() end, %{entry_count: 0, last_seq: 0}))
    |> assign(:replication_rows, replication_rows())
    |> assign(:federation, federation_snapshot())
    |> assign(:monero, monero_snapshot())
  end

  # --- Replication ---

  defp replication_rows do
    status = safe(fn -> Replicator.status() end, %{})

    Enum.map(status, fn {origin, %{cursor: cursor, peer_tip: peer_tip}} ->
      tick = safe(fn -> TelemetryFacade.health_cache_get({:replicator_tick, origin}) end, :unknown)
      lag = max(peer_tip - cursor, 0)

      %{
        origin: origin,
        cursor: cursor,
        peer_tip: peer_tip,
        lag: lag,
        lag_class: lag_class(lag),
        last_tick_label: tick_label(tick),
        tick_stale?: tick_stale?(tick)
      }
    end)
    |> Enum.sort_by(& &1.origin)
  end

  defp lag_class(lag) when lag >= @lag_critical_entries, do: "pw-lag-critical"
  defp lag_class(lag) when lag >= @lag_warning_entries, do: "pw-lag-warning"
  defp lag_class(_), do: "pw-lag-ok"

  defp tick_label(:unknown), do: Messages.no_tick_yet()
  defp tick_label(%{timestamp: %DateTime{} = ts}), do: relative_label(ts)
  defp tick_label(_), do: Messages.dash()

  defp tick_stale?(%{timestamp: %DateTime{} = ts}) do
    DateTime.diff(DateTime.utc_now(), ts, :second) > @tick_stale_seconds
  end

  defp tick_stale?(_), do: false

  # --- Federation ---

  defp federation_snapshot do
    online = safe(fn -> FederationFacade.online_peer_count() end, 0) + 1
    total = safe(fn -> FederationFacade.member_count() end, 0)
    quorum_ok = safe(fn -> FederationFacade.quorum?() end, false)
    in_flight = safe(fn -> FederationFacade.list_in_flight_requests() end, []) |> length()
    signing = safe(fn -> FederationStore.signing_stats() end, %{signs_window: 0, last_sign_at: nil})

    %{
      quorum_label: "#{online}/#{total}",
      quorum_class: if(quorum_ok, do: "accent", else: "loss"),
      designated_processor: designated_processor_label(),
      last_sign_label: relative_label(signing.last_sign_at),
      signs_24h: signing.signs_window,
      in_flight_payouts: in_flight
    }
  end

  # Reads the CURRENTLY-designated processor for the local env.
  # Defaults to `:p1` on prod and `:s1` on staging (per @default_designated_processors
  # in Role), but `Federation.Console.promote_processor/1` mutates the
  # set at runtime — the label must reflect the live value, not the
  # default. Federations are homogeneous (all-N or all-S), so the local
  # node's prefix identifies which entry in the designated set applies
  # here.
  defp designated_processor_label do
    local_prefix = Role.participant_id() |> Atom.to_string() |> String.first()

    label =
      Role.designated_processors()
      |> Enum.map(&Atom.to_string/1)
      |> Enum.find(&String.starts_with?(&1, local_prefix))
      |> Kernel.||("#{local_prefix}?")

    if Role.designated_processor?(), do: label <> Messages.this_node_suffix(), else: label
  end

  # --- Monero Chain ---

  defp monero_snapshot do
    {wallet_status, wallet_class} =
      case safe(fn -> MoneroFacade.health_check() end, {:error, :unknown}) do
        :ok -> {Messages.wallet_status_open(), "accent"}
        _ -> {Messages.wallet_status_unreachable(), "loss"}
      end

    {balance_label, unlocked_label} =
      case safe(fn -> MoneroFacade.balance() end, {:error, :unknown}) do
        {:ok, %{balance: b, unlocked_balance: u}} ->
          {WebHelpers.format_xmr_compact(b), WebHelpers.format_xmr_compact(u)}

        _ ->
          {Messages.dash(), Messages.dash()}
      end

    {height_label, height_class} =
      case safe(fn -> MoneroFacade.block_height() end, {:error, :unknown}) do
        {:ok, h} when is_integer(h) -> {Integer.to_string(h), "accent"}
        _ -> {Messages.dash(), "loss"}
      end

    %{
      wallet_status: wallet_status,
      wallet_class: wallet_class,
      balance: balance_label,
      unlocked: unlocked_label,
      height: height_label,
      height_class: height_class
    }
  end

  # --- Format Helpers ---

  defp relative_label(nil), do: Messages.never()

  defp relative_label(%DateTime{} = ts) do
    DateTime.utc_now()
    |> DateTime.diff(ts, :second)
    |> Messages.relative_time_with_just_now()
  end

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end

  defp current_pct(metrics, key) do
    case Map.get(metrics, key, 0) do
      v when is_float(v) -> Float.round(v, 1)
      v -> v
    end
  end

  defp format_count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_count(_), do: Messages.dash()

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <Helpers.admin_header node_label={@node_label} />
    <Helpers.admin_sub_nav current_page={:system} stats={@sub_nav_stats} />

    <main class="bp-root">
      <div class="bp-page-wide bp-admin-page">
        <.grid cols="3">
          <.panel title={Messages.panel_cpu()}>
            <.panel_body>
              <.sparkline
                data={@cpu_series}
                label={Messages.sparkline_label_cpu()}
                value={to_string(current_pct(@sys_metrics, :cpu_pct))}
                color="var(--color-accent)"
                max_value={100.0}
              />
            </.panel_body>
          </.panel>

          <.panel title={Messages.panel_memory()}>
            <.panel_body>
              <.sparkline
                data={@memory_series}
                label={Messages.sparkline_label_memory()}
                value={to_string(current_pct(@sys_metrics, :memory_pct))}
                color="var(--color-warning)"
                max_value={100.0}
              />
            </.panel_body>
          </.panel>

          <.panel title={Messages.panel_disk()}>
            <.panel_body>
              <.sparkline
                data={@disk_series}
                label={Messages.sparkline_label_disk()}
                value={to_string(current_pct(@sys_metrics, :disk_pct))}
                color="var(--color-info)"
                max_value={100.0}
              />
            </.panel_body>
          </.panel>
        </.grid>

        <.grid cols="2">
          <.panel title={Messages.panel_replication()}>
            <.panel_scroll>
              <WebHelpers.table_empty_state :if={@replication_rows == []} message={Messages.empty_no_replication_peers()} />
              <table :if={@replication_rows != []} class="bp-mini-table">
                <thead>
                  <tr>
                    <th scope="col">{Messages.column_peer()}</th>
                    <th scope="col">{Messages.column_cursor()}</th>
                    <th scope="col">{Messages.column_peer_tip()}</th>
                    <th scope="col">{Messages.column_lag()}</th>
                    <th scope="col">{Messages.column_last_tick()}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- @replication_rows} id={"replication-#{row.origin}"}>
                    <td class="pw-origin">{row.origin}</td>
                    <td>{format_count(row.cursor)}</td>
                    <td>{format_count(row.peer_tip)}</td>
                    <td class={row.lag_class}>{format_count(row.lag)}</td>
                    <td class={if row.tick_stale?, do: "pw-tick-stale"}>{row.last_tick_label}</td>
                  </tr>
                </tbody>
              </table>
            </.panel_scroll>
          </.panel>

          <.panel title={Messages.panel_federation()}>
            <.panel_body>
              <.stat_rows rows={[
                %{label: Messages.stat_label_quorum(), value: @federation.quorum_label, class: @federation.quorum_class},
                %{label: Messages.stat_label_designated_processor(), value: @federation.designated_processor},
                %{label: Messages.stat_label_last_sign(), value: @federation.last_sign_label},
                %{label: Messages.stat_label_signs_24h(), value: "#{@federation.signs_24h}"},
                %{label: Messages.stat_label_in_flight_payouts(), value: "#{@federation.in_flight_payouts}"}
              ]} />
            </.panel_body>
          </.panel>
        </.grid>

        <.grid cols="2">
          <.panel title={Messages.panel_monero()}>
            <.panel_body>
              <.stat_rows rows={[
                %{label: Messages.stat_label_wallet_rpc(), value: @monero.wallet_status, class: @monero.wallet_class},
                %{label: Messages.stat_label_balance(), value: @monero.balance},
                %{label: Messages.stat_label_unlocked(), value: @monero.unlocked},
                %{label: Messages.stat_label_wallet_chain_height(), value: @monero.height, class: @monero.height_class}
              ]} />
            </.panel_body>
          </.panel>

          <.panel title={Messages.panel_beam()}>
            <.panel_body>
              <.stat_rows rows={beam_rows(@sys_metrics, @wal_info)} />
            </.panel_body>
          </.panel>
        </.grid>
      </div>

      <Helpers.admin_footer pips={@footer_pips} />
    </main>
    """
  end

  defp beam_rows(metrics, wal) do
    [
      %{label: Messages.stat_label_load(), value: "#{Map.get(metrics, :load_avg, "n/a")}"},
      %{label: Messages.stat_label_beam_memory(), value: "#{Map.get(metrics, :beam_memory_mb, 0)} MB"},
      %{label: Messages.stat_label_ets_memory(), value: "#{Map.get(metrics, :beam_ets_mb, 0)} MB"},
      %{label: Messages.stat_label_processes(), value: "#{Map.get(metrics, :beam_processes, 0)}"},
      %{label: Messages.stat_label_atoms(), value: "#{Map.get(metrics, :beam_atoms, 0)}"},
      %{label: Messages.stat_label_schedulers(), value: "#{Map.get(metrics, :beam_schedulers, 0)}"},
      %{label: Messages.stat_label_run_queue(), value: "#{Map.get(metrics, :beam_run_queue, 0)}"},
      %{label: Messages.stat_label_uptime(), value: "#{Map.get(metrics, :uptime_hours, 0)}h"},
      %{label: Messages.stat_label_wal_entries(), value: format_count(Map.get(wal, :entry_count, 0))},
      %{label: Messages.stat_label_wal_seq(), value: format_count(Map.get(wal, :last_seq, 0))}
    ]
  end
end
