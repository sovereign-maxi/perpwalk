defmodule PerpWalk.Telemetry.Health.Metrics do
  @moduledoc """
  System-level metrics readers.

  Pure functions over `/proc` and `df` — no GenServer, no state.
  Used by `Telemetry.Metrics.Ring` for rolling-window samples and
  by `Telemetry.Alerts.Manager` rules that compare CPU/memory/disk
  against thresholds.
  """

  @doc "CPU usage percentage (0.0 to 100.0). Cumulative since boot — good enough for thresholds."
  @spec cpu_usage() :: float()
  def cpu_usage do
    case File.read("/proc/stat") do
      {:ok, content} ->
        [line | _] = String.split(content, "\n")
        calculate_cpu(line)

      _ ->
        0.0
    end
  rescue
    _ -> 0.0
  end

  @doc "Memory usage percentage (0.0 to 100.0)."
  @spec memory_usage() :: float()
  def memory_usage do
    case File.read("/proc/meminfo") do
      {:ok, content} ->
        info = parse_meminfo(content)
        total = Map.get(info, "MemTotal", 1)
        available = Map.get(info, "MemAvailable", total)

        if total > 0 do
          Float.round((1.0 - available / total) * 100, 1)
        else
          0.0
        end

      _ ->
        0.0
    end
  rescue
    _ -> 0.0
  end

  @doc "Disk usage percentage for the given path. Returns nil on failure."
  @spec disk_usage(String.t()) :: float() | nil
  def disk_usage(path \\ "/") do
    case System.cmd("df", ["--output=pcent", path], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> List.last()
        |> String.trim()
        |> String.trim_trailing("%")
        |> String.to_integer()
        |> Kernel./(1)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc "Load average — '1.23 0.97 0.81' or 'n/a' if /proc/loadavg unreadable."
  @spec load_average() :: String.t()
  def load_average do
    case File.read("/proc/loadavg") do
      {:ok, data} ->
        case String.split(data) do
          [l1, l5, l15 | _] -> "#{l1} #{l5} #{l15}"
          _ -> "n/a"
        end

      _ ->
        "n/a"
    end
  rescue
    _ -> "n/a"
  end

  @doc """
  Snapshot of all system metrics. The Ring takes one of these per
  minute and stores the last 360 of them (6h window).
  """
  @spec snapshot() :: map()
  def snapshot do
    # Accept both shapes for backwards-compatibility with any caller still
    # configuring `disk_mounts` as a flat list of paths:
    #   ["/", "/data"]                                       (old)
    #   [{"/", %{...}}, {"/data", %{...}}]                   (new with thresholds)
    mounts =
      Application.get_env(:perpwalk, :disk_mounts, [{"/", %{high: 90, critical: 95}}])
      |> Enum.map(fn
        {path, _thresholds} -> path
        path when is_binary(path) -> path
      end)

    disks =
      Enum.map(mounts, fn path ->
        {path, disk_usage(path) || 0.0}
      end)

    # `disk_pct` is the max usage across all mounts — single scalar
    # so it slots into the metrics ring alongside `cpu_pct` and
    # `memory_pct` for a sparkline series. Per-mount detail stays in
    # `:disks` for the per-disk bar rendering.
    disk_pct =
      disks
      |> Enum.map(fn {_path, pct} -> pct end)
      |> Enum.max(fn -> 0.0 end)

    %{
      cpu_pct: cpu_usage(),
      memory_pct: memory_usage(),
      disk_pct: disk_pct,
      load_avg: load_average(),
      disks: disks,
      beam_memory_mb: Float.round(:erlang.memory(:total) / 1_048_576, 1),
      beam_ets_mb: Float.round(:erlang.memory(:ets) / 1_048_576, 1),
      beam_processes: :erlang.system_info(:process_count),
      beam_ports: :erlang.system_info(:port_count),
      beam_atoms: :erlang.system_info(:atom_count),
      beam_schedulers: :erlang.system_info(:schedulers_online),
      beam_run_queue: :erlang.statistics(:total_run_queue_lengths_all),
      uptime_hours: uptime_hours()
    }
  end

  # --- Private ---

  defp uptime_hours do
    {ms, _} = :erlang.statistics(:wall_clock)
    Float.round(ms / 3_600_000, 1)
  end

  defp calculate_cpu(cpu_line) do
    parts =
      cpu_line
      |> String.split()
      |> Enum.drop(1)
      |> Enum.map(&String.to_integer/1)

    case parts do
      [user, nice, system, idle, iowait, irq, softirq | _rest] ->
        total = user + nice + system + idle + iowait + irq + softirq
        busy = total - idle - iowait

        if total > 0 do
          Float.round(busy / total * 100, 1)
        else
          0.0
        end

      _ ->
        0.0
    end
  rescue
    _ -> 0.0
  end

  defp parse_meminfo(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":") do
        [key, value] ->
          kb =
            value
            |> String.trim()
            |> String.split()
            |> List.first()
            |> String.to_integer()

          Map.put(acc, String.trim(key), kb)

        _ ->
          acc
      end
    end)
  rescue
    _ -> %{}
  end
end
