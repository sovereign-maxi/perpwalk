defmodule PerpWalk.Telemetry.Facade do
  @moduledoc """
  Published Language facade for the Telemetry bounded context.

  Single entry point for the admin dashboard and any future
  consumer. All functions are crash-safe — if the Telemetry
  supervision tree isn't running (e.g. during recovery), the
  fallbacks return safe defaults so callers never have to wrap
  Telemetry calls in their own try/rescue.
  """

  alias PerpWalk.Telemetry.Alerts.Manager, as: AlertsManager
  alias PerpWalk.Telemetry.Health.Cache
  alias PerpWalk.Telemetry.Health.System
  alias PerpWalk.Telemetry.Metrics.Ring

  @doc "Current overall system status: `:healthy | :degraded | :critical | :halted`."
  @spec system_status() :: atom()
  def system_status do
    System.status()
  rescue
    _ -> :healthy
  catch
    :exit, _ -> :healthy
  end

  @doc "Per-component health map (tor, monero, storage, markets, system)."
  @spec health_components() :: map()
  def health_components do
    System.components()
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  @doc "Currently firing or resolving alerts."
  @spec active_alerts() :: [map()]
  def active_alerts do
    AlertsManager.active_alerts()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc """
  Recently resolved alerts within `window_seconds` (default 24 h),
  capped at `limit` (default 20). Sorted newest first. Used by the
  admin events page to render a resolved-alerts strip alongside
  the active column.
  """
  @spec recent_resolved_alerts() :: [map()]
  @spec recent_resolved_alerts(pos_integer()) :: [map()]
  @spec recent_resolved_alerts(pos_integer(), pos_integer()) :: [map()]
  def recent_resolved_alerts(window_seconds \\ 86_400, limit \\ 20) do
    AlertsManager.recent_resolved(window_seconds, limit)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc "Most recent system metrics snapshot."
  @spec system_metrics() :: map()
  def system_metrics do
    Ring.latest() || %{}
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  @doc "Time-series for a metric key — list of `{unix_ts, value}` oldest-first."
  @spec metrics_series(atom(), pos_integer()) :: [{integer(), number()}]
  def metrics_series(key, limit \\ 360) do
    Ring.series(key, limit)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc "Sets the system to halted with a reason. Used during incident response."
  @spec set_halted(String.t()) :: :ok
  def set_halted(reason), do: System.set_halted(reason)

  @doc "Clears a previously set halt."
  @spec clear_halt() :: :ok
  def clear_halt, do: System.clear_halt()

  @doc "Returns the current halt reason string, or `nil` if not halted."
  @spec halt_reason() :: String.t() | nil
  defdelegate halt_reason(), to: System

  @doc """
  Returns `true` when the system is currently halted, `false`
  otherwise. Cross-domain callers (Guards, LiveViews) use this
  instead of reaching into `Telemetry.Health.System` directly.
  """
  @spec halted?() :: boolean()
  def halted? do
    System.halted?()
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc """
  Returns the most recent value cached under `key` in the health
  cache, or `nil` if never cached. Published as a diagnostic
  surface so admin LiveViews can read health snapshots (e.g.
  `{:replicator_tick, origin}`) without reaching into the cache
  module directly.
  """
  @spec health_cache_get(term()) :: term() | nil
  def health_cache_get(key) do
    Cache.get(key)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
