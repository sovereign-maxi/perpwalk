defmodule PerpWalkAdminWeb.Live.Helpers do
  @moduledoc """
  Shared chrome for the admin LiveViews — header, sub-nav with
  page-switcher dropdown, footer pip strip — plus the cross-page
  helpers each LiveView leans on for stats freshness.

  Three admin pages share this chrome:

    * `Live.Dashboard` — venue stats
    * `Live.System` — host metrics + BEAM telemetry
    * `Live.Events` — alerts + event stream

  The sub-nav stats line stays identical across all three so the
  operator's ambient situational awareness (Status / Markets /
  Active / Backlog) doesn't move when they switch pages. Each page
  computes its own stats from `sub_nav_stats/0` at render time —
  cheap ETS reads, no GenServer calls.
  """

  use PerpWalkAdminWeb, :html

  alias PerpWalk.Federation.Facade, as: FederationFacade
  alias PerpWalk.Markets.Facade
  alias PerpWalk.Telemetry.Facade, as: TelemetryFacade
  alias PerpWalk.Version
  alias PerpWalkAdminWeb.Messages

  # --- Header ---

  @doc """
  Admin header. Logo + tagline on the left, an `Admin - <label>`
  badge on the right so the operator always sees which federation
  node they're SSH'd into. Logo links back to the dashboard.

  `node_label` is a string like `"N1"` (prod) or `"S2"` (staging),
  supplied by `node_label/0` — see that function for the resolution
  order.
  """
  attr(:node_label, :string, required: true)

  def admin_header(assigns) do
    ~H"""
    <.header
      logo_text={Messages.brand_name()}
      logo_href="/admin/dashboard"
      tagline={Messages.brand_tagline()}
      badge={Messages.admin_badge(@node_label)}
    />
    """
  end

  # --- Sub-Nav With Page Dropdown ---

  @doc """
  Sub-nav strip with the four ambient stats (Status / Markets /
  Active / Backlog) plus the page-switcher dropdown on the left.
  `current_page` is one of `:dashboard | :system | :events` and
  controls both the dropdown label and which menu items render.

  `stats` is a required attr — must come from a socket assign
  (e.g. `@sub_nav_stats`) that the LiveView refreshes on tick /
  subscribed events, NOT an inline `Helpers.sub_nav_stats()` call
  in the template. LiveView's change tracking only diffs assigns;
  an inline helper call gets evaluated but the resulting HTML is
  cached against the stable `current_page` attr, so the Status pip
  never updates on `SystemStatusChanged`. Same pattern as
  `admin_footer pips=`.
  """
  attr(:current_page, :atom, required: true)
  attr(:stats, :list, required: true)

  def admin_sub_nav(assigns) do
    assigns =
      assigns
      |> assign(:dropdown_label, dropdown_label(assigns.current_page))
      |> assign(:dropdown_items, dropdown_items(assigns.current_page))

    ~H"""
    <.sub_nav stats={@stats}>
      <.nav_dropdown label={@dropdown_label} items={@dropdown_items} />
    </.sub_nav>
    """
  end

  defp dropdown_label(:dashboard), do: Messages.nav_dropdown_label_dashboard()
  defp dropdown_label(:system), do: Messages.nav_dropdown_label_system()
  defp dropdown_label(:events), do: Messages.nav_dropdown_label_events()

  defp dropdown_items(current_page) do
    [
      {:dashboard, Messages.nav_dropdown_item_dashboard(), "/admin/dashboard"},
      {:system, Messages.nav_dropdown_item_system(), "/admin/system"},
      {:events, Messages.nav_dropdown_item_events(), "/admin/events"}
    ]
    |> Enum.reject(fn {page, _label, _href} -> page == current_page end)
    |> Enum.map(fn {_page, label, href} -> {label, href} end)
  end

  # --- Footer ---

  @doc """
  Admin footer pip strip + commit hash. Each LiveView reads its
  own component statuses from `Telemetry.Facade.health_components/0`
  on the same `:tick` cadence that refreshes the rest of its
  snapshot, so the footer stays in step with the page's content.
  """
  attr(:pips, :list, required: true)

  def admin_footer(assigns) do
    ~H"""
    <.footer pips={@pips} commit_hash={Version.git_sha()} />
    """
  end

  # --- Cross-Page Snapshots ---

  @doc """
  Reads the four sub-nav stats fresh from facades. Cheap (ETS-backed)
  and called on every render — so any event that triggers a LiveView
  re-render also refreshes the stats line.
  """
  @spec sub_nav_stats() :: [map()]
  def sub_nav_stats do
    markets = safe(fn -> Facade.list_markets() end, [])

    total = length(markets)
    active = Enum.count(markets, &(&1.status == :active))

    backlog =
      Enum.count(markets, &Facade.status_awaiting_operator_action?(&1.status))

    system_status = safe(fn -> TelemetryFacade.system_status() end, :unknown)

    [
      %{
        label: Messages.sub_nav_status(),
        value: Messages.system_status_label(system_status),
        class: system_status_class(system_status)
      },
      %{label: Messages.sub_nav_markets(), value: "#{total}"},
      %{label: Messages.sub_nav_active(), value: "#{active}"},
      %{
        label: Messages.sub_nav_backlog(),
        value: "#{backlog}",
        class: backlog_class(backlog)
      }
    ]
  end

  @doc """
  Reads the footer pip strip from the current health-component
  snapshot. Same cadence as `sub_nav_stats/0` — any re-render gets
  a fresh pip strip.
  """
  @spec footer_pips() :: [map()]
  def footer_pips do
    components = safe(fn -> TelemetryFacade.health_components() end, %{})

    [
      # Federation reads direct from FederationFacade — the telemetry
      # health map only surfaces alerted states (quorum lost / signing
      # halted), so it never reflects "quorum intact but peer down".
      # Reading the facade keeps admin and user pips in step.
      %{label: federation_label(), status: safe(fn -> FederationFacade.pip_status() end, :offline)},
      %{label: Messages.footer_pip_tor(), status: pip_status(Map.get(components, :tor, :unknown))},
      %{label: Messages.footer_pip_monero(), status: pip_status(Map.get(components, :monero, :unknown))},
      %{label: Messages.footer_pip_storage(), status: pip_status(Map.get(components, :storage, :unknown))},
      %{label: Messages.footer_pip_markets(), status: pip_status(Map.get(components, :markets, :unknown))},
      %{label: Messages.footer_pip_system(), status: pip_status(Map.get(components, :system, :unknown))}
    ]
  end

  @doc """
  Resolves the operator-facing node label. Prefers the string
  `NODE_LABEL` env value (suffix set at deploy time, e.g. `"N1"`
  for a prod node) when set, otherwise falls back to
  `"N<cartel node_id>"` for backwards compatibility with
  environments where federation is configured but NODE_LABEL isn't.
  """
  @spec node_label() :: String.t()
  def node_label do
    case Application.get_env(:perpwalk, :node_label) do
      label when is_binary(label) and byte_size(label) > 0 -> label
      _ -> "N#{cartel_node_id_fallback()}"
    end
  end

  defp cartel_node_id_fallback do
    case Application.get_env(:cartel, :node_id) do
      n when is_integer(n) and n > 0 -> n
      _ -> 1
    end
  end

  # --- Private ---

  defp federation_label do
    online = FederationFacade.online_peer_count() + 1
    total = FederationFacade.member_count()
    Messages.footer_pip_federation(online, total)
  end

  defp system_status_class(:healthy), do: "accent"
  defp system_status_class(:degraded), do: "warning"
  defp system_status_class(:critical), do: "loss"
  defp system_status_class(:halted), do: "loss"
  defp system_status_class(_), do: "muted"

  defp backlog_class(0), do: "muted"
  defp backlog_class(_), do: "warning"

  defp pip_status(:healthy), do: :ok
  defp pip_status(:degraded), do: :degraded
  defp pip_status(:critical), do: :critical
  defp pip_status(:halted), do: :critical
  defp pip_status(_), do: :offline

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end
end
