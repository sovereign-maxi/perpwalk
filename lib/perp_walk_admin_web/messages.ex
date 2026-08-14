defmodule PerpWalkAdminWeb.Messages do
  @moduledoc """
  Centralised operator-facing strings for the admin surface. Parallel
  to `PerpWalkWeb.Messages` for the user surface — every panel title,
  stat label, table header, empty state, and status label routes
  through here so admin copy changes happen in one place.

  Naming mirrors `PerpWalkWeb.Messages` — fully-qualified context
  prefix per group:

    * `brand_*` — brand mark + tagline
    * `page_title_*` — page titles
    * `panel_*` — panel titles
    * `stat_label_*` — stat-row labels
    * `column_*` — table column headers
    * `empty_*` — empty-state text
    * `action_*` — button labels
    * `aria_*` — ARIA labels
    * `sparkline_label_*` — sparkline data labels
    * `footer_pip_*` — footer pip labels
    * `nav_dropdown_label_*` / `nav_dropdown_item_*` — nav dropdown
    * `sub_nav_*` — ambient stats row on the sub-nav
    * `system_status_*` / `wallet_status_*` — status labels

  Pure functions, no process state, no IO. Safe to call from any
  admin LiveView render or helper module.
  """

  # --- Brand ---
  #
  # Same values as `PerpWalkWeb.Messages.brand_name/0` /
  # `brand_tagline/0` for now; kept duplicated so the admin surface
  # is self-contained (rebranding either surface shouldn't force a
  # cross-module change).

  def brand_name, do: "PERP WALK"
  def brand_tagline, do: "Markets Without Permission"

  @doc "Right-side badge; interpolates the resolved node label (e.g. `N1`, `S2`)."
  def admin_badge(node_label) when is_binary(node_label), do: "Admin - #{node_label}"

  # --- Page Titles ---

  def page_title_admin, do: "PERP WALK - ADMIN"

  # --- Nav Dropdown ---

  def nav_dropdown_label_dashboard, do: "DASHBOARD"
  def nav_dropdown_label_system, do: "SYSTEM"
  def nav_dropdown_label_events, do: "EVENTS"

  def nav_dropdown_item_dashboard, do: "Dashboard"
  def nav_dropdown_item_system, do: "System"
  def nav_dropdown_item_events, do: "Events"

  # --- Sub-Nav Ambient Stats ---

  def sub_nav_status, do: "Status"
  def sub_nav_markets, do: "Markets"
  def sub_nav_active, do: "Active"
  def sub_nav_backlog, do: "Backlog"

  # --- System Status Labels ---

  def system_status_healthy, do: "Healthy"
  def system_status_degraded, do: "Degraded"
  def system_status_critical, do: "Critical"
  def system_status_halted, do: "Halted"
  def system_status_unknown, do: "Unknown"

  @doc """
  Dispatcher for `Helpers.sub_nav_stats/0` which already has an atom
  in hand. Mirrors Web's `market_status_tooltip/1` pattern for
  atom-keyed status lookups.
  """
  def system_status_label(:healthy), do: system_status_healthy()
  def system_status_label(:degraded), do: system_status_degraded()
  def system_status_label(:critical), do: system_status_critical()
  def system_status_label(:halted), do: system_status_halted()
  def system_status_label(_), do: system_status_unknown()

  # --- Footer Pips ---

  @doc "Federation pip label with the online/total peer count interpolated."
  def footer_pip_federation(online, total) when is_integer(online) and is_integer(total),
    do: "Federation #{online}/#{total}"

  def footer_pip_tor, do: "Tor"
  def footer_pip_monero, do: "Monero"
  def footer_pip_storage, do: "Storage"
  def footer_pip_markets, do: "Markets"
  def footer_pip_system, do: "System"

  # --- Panel Titles ---

  def panel_markets, do: "MARKETS"
  def panel_activity, do: "ACTIVITY"
  def panel_wallet_and_signing, do: "WALLET & SIGNING"
  def panel_house_income, do: "HOUSE INCOME"
  def panel_top_active_markets, do: "TOP ACTIVE MARKETS"
  def panel_recent_settlements, do: "RECENT SETTLEMENTS"
  def panel_cpu, do: "CPU"
  def panel_memory, do: "MEMORY"
  def panel_disk, do: "DISK"
  def panel_replication, do: "REPLICATION"
  def panel_federation, do: "FEDERATION"
  def panel_monero, do: "MONERO"
  def panel_beam, do: "BEAM"
  def panel_active_alerts, do: "ACTIVE ALERTS"
  def panel_event_stream, do: "EVENT STREAM"

  # --- Stat-Row Labels (Markets panel) ---

  def stat_label_market_active, do: "Active"
  def stat_label_market_pending, do: "Pending"
  def stat_label_market_awaiting_resolution, do: "Awaiting resolution"
  def stat_label_market_in_dispute_window, do: "In dispute window"
  def stat_label_market_total, do: "Total"

  # --- Stat-Row Labels (Activity panel) ---

  def stat_label_volume_24h, do: "Volume (24h)"
  def stat_label_trades_24h, do: "Trades (24h)"
  def stat_label_pool_tvl, do: "Pool TVL"

  # --- Stat-Row Labels (Wallet & Signing panel) ---

  def stat_label_wallet, do: "Wallet"
  def stat_label_wallet_rpc, do: "Wallet RPC"
  def stat_label_balance, do: "Balance"
  def stat_label_unlocked, do: "Unlocked"
  def stat_label_address, do: "Address"
  def stat_label_wal_seq, do: "WAL seq"
  def stat_label_wal_entries, do: "WAL entries"
  def stat_label_signs_24h, do: "Signs (24h)"

  # --- Stat-Row Labels (House Income panel) ---

  def stat_label_income_total, do: "Total"
  def stat_label_income_slashes, do: "Slashes"
  def stat_label_income_burns, do: "Burns"
  def stat_label_income_spread, do: "Spread"
  def stat_label_income_drawn, do: "Drawn"
  def stat_label_income_available, do: "Available"

  # --- Stat-Row Labels (Federation panel) ---

  def stat_label_quorum, do: "Quorum"
  def stat_label_designated_processor, do: "Designated processor"
  def stat_label_last_sign, do: "Last sign"
  def stat_label_in_flight_payouts, do: "In-flight payouts"

  # --- Stat-Row Labels (Monero panel) ---

  def stat_label_wallet_chain_height, do: "Wallet chain height"

  # --- Stat-Row Labels (BEAM panel) ---

  def stat_label_load, do: "Load"
  def stat_label_beam_memory, do: "BEAM memory"
  def stat_label_ets_memory, do: "ETS memory"
  def stat_label_processes, do: "Processes"
  def stat_label_atoms, do: "Atoms"
  def stat_label_schedulers, do: "Schedulers"
  def stat_label_run_queue, do: "Run queue"
  def stat_label_uptime, do: "Uptime"

  # --- Sparkline Data Labels ---

  def sparkline_label_cpu, do: "Cpu"
  def sparkline_label_memory, do: "Memory"
  def sparkline_label_disk, do: "Disk"

  # --- Table Column Headers ---

  def column_question, do: "Question"
  def column_pool, do: "Pool"
  def column_trades_24h, do: "Trades (24h)"
  def column_volume_24h, do: "Volume (24h)"
  def column_volume, do: "Volume"
  def column_outcome, do: "Outcome"
  def column_resolved, do: "Resolved"
  def column_time_to_close, do: "Time to close"
  def column_peer, do: "Peer"
  def column_cursor, do: "Cursor"
  def column_peer_tip, do: "Peer tip"
  def column_lag, do: "Lag"
  def column_last_tick, do: "Last tick"

  # --- Paginator Labels ---

  def paginator_label_top_active, do: "active markets"
  def paginator_label_settlements, do: "settlements"

  # --- Empty States ---

  def empty_no_active_markets, do: "No active markets yet"
  def empty_no_settlements, do: "No settlements yet"
  def empty_no_replication_peers, do: "No peers configured yet"
  def empty_no_alerts, do: "No alerts yet"
  def empty_no_events, do: "No events yet"

  # --- Actions ---

  def action_clear, do: "CLEAR"

  # --- Wallet + Chain Status ---

  def wallet_status_open, do: "OPEN"
  def wallet_status_unreachable, do: "UNREACHABLE"

  # --- Sentinel Dashes / Labels ---

  @doc "Placeholder shown when a metric has no reading yet."
  def dash, do: "—"

  @doc "Fallback label for a datapoint that hasn't fired since boot."
  def never, do: "never"

  @doc "Replication panel — peer hasn't yet reported a tick."
  def no_tick_yet, do: "no tick yet"

  @doc "Suffix appended to the designated-processor row for the local node."
  def this_node_suffix, do: " (this node)"

  # --- Relative Time Labels ---
  #
  # Web's `PerpWalkWeb.Messages.relative_time/1` returns `"—"` for
  # nil and has no sub-5s carve-out. The admin surface additionally
  # wants a "just now" carve-out for the System page (fast-moving
  # signing / replication ticks look weird flashing between `1s
  # ago` and `2s ago`), so we expose both variants.

  @doc "Relative time. `never/0` for nil, no `just now` carve-out — mirrors Web."
  def relative_time(nil), do: never()

  def relative_time(diff_seconds) when is_integer(diff_seconds) do
    cond do
      diff_seconds < 60 -> "#{diff_seconds}s ago"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)}h ago"
      true -> "#{div(diff_seconds, 86_400)}d ago"
    end
  end

  @doc "Same as `relative_time/1` but coalesces < 5 s to `just now`."
  def relative_time_with_just_now(nil), do: never()

  def relative_time_with_just_now(diff_seconds) when is_integer(diff_seconds) do
    if diff_seconds < 5, do: "just now", else: relative_time(diff_seconds)
  end

  @doc """
  "Time to close" label rendered in the Top Active Markets table.
  `:expired` when the expiry has passed, otherwise the coarsest unit
  that fits (m / h / d) so the column stays narrow.
  """
  def time_until(nil), do: dash()

  def time_until(diff_seconds) when is_integer(diff_seconds) do
    cond do
      diff_seconds <= 0 -> "expired"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)}h"
      true -> "#{div(diff_seconds, 86_400)}d"
    end
  end

  # --- Outcome Labels ---
  #
  # Dispatcher-style (like `PerpWalkWeb.Messages.market_status_tooltip/1`)
  # because the label is a deterministic function of the outcome atom
  # and callers already have the atom in hand.

  def outcome_label(nil), do: dash()
  def outcome_label(outcome) when is_atom(outcome), do: outcome |> Atom.to_string() |> String.upcase()

  # --- Events Page Filter Options ---

  def domain_options, do: ["ALL", "Markets", "Federation", "Reserves", "Telemetry", "Monero", "Tor"]

  def severity_options, do: ["ALL", "Info", "Warning", "Critical", "Emergency"]

  # --- ARIA Labels ---

  def aria_filter_alerts_domain, do: "Filter alerts by domain"
  def aria_filter_alerts_severity, do: "Filter alerts by severity"
  def aria_filter_stream_domain, do: "Filter event stream by domain"
  def aria_filter_stream_severity, do: "Filter event stream by severity"
  def aria_active_alerts_log, do: "Active alerts"
  def aria_event_stream_log, do: "Event stream"
end
