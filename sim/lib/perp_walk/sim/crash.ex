defmodule PerpWalk.Sim.Crash do
  @moduledoc """
  Crash orchestration for the Crash scenario.

  Kills supervised store processes and waits for the supervisor
  to restart them. Each restart triggers the store's `init/1`
  which replays the WAL and rebuilds ETS — that's the
  production crash-recovery path under test.

  ## Targets

  - `:markets_store` — `PerpWalk.Markets.Store`
  - `:federation_store` — `PerpWalk.Federation.Store`

  ## Restart-budget awareness

  `Markets.Supervisor` carries `max_restarts: 10, max_seconds: 60`;
  `Federation.Supervisor` similar. A scenario that crashes the
  same store more than 10 times in a minute will exhaust the
  supervisor's budget and propagate the failure upward, which
  is its own kind of useful signal — but most scenarios should
  pace crashes well under that limit.

  ## Snapshot helper

  `snapshot/0` records pre-crash entity counts so the Replay
  invariant can compare post-crash recovery against them. The
  comparison is a count match, not byte-for-byte ETS equality —
  that's a stronger property best implemented as a separate
  follow-up if/when needed.
  """

  require Logger

  alias PerpWalk.Federation.Facade, as: FederationFacade
  alias PerpWalk.Markets.Facade, as: MarketsFacade

  @default_restart_timeout_ms 5_000
  @restart_poll_ms 50

  # --- Public API ---

  @doc """
  Snapshots current entity counts. Returns a map of
  `count_kind => count` that the Replay invariant compares
  against post-crash.
  """
  @spec snapshot() :: map()
  def snapshot do
    %{
      markets: length(MarketsFacade.list_markets()),
      positions: count_positions(),
      disputes: length(MarketsFacade.list_disputes()),
      payouts: length(FederationFacade.list_requests())
    }
  end

  @doc """
  Compares the live state against `pre_crash`. Returns `:ok`
  when counts match (allowing for in-flight changes during the
  crash window) or `{:mismatch, details}` when they diverge.
  """
  @spec compare(map()) :: :ok | {:mismatch, map()}
  def compare(pre_crash) do
    post_crash = snapshot()

    diffs =
      pre_crash
      |> Enum.flat_map(fn {key, before_count} ->
        after_count = Map.get(post_crash, key, 0)

        # Allow `after_count >= before_count` — actors continue
        # to act during the crash window, so post-crash counts
        # should never SHRINK. Any decrease is a recovery bug.
        if after_count < before_count do
          [%{kind: key, before: before_count, after: after_count}]
        else
          []
        end
      end)

    if diffs == [] do
      :ok
    else
      {:mismatch, %{kind: :count_decrease, diffs: diffs, before: pre_crash, after: post_crash}}
    end
  end

  @doc """
  Kills the named store and waits for the supervisor to restart
  it. Returns when the new process is alive and registered, or
  `{:error, :timeout}` if the restart doesn't complete within
  `:timeout_ms`.
  """
  @spec kill_and_wait(atom(), keyword()) :: :ok | {:error, :timeout}
  def kill_and_wait(target, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_restart_timeout_ms)
    module = target_to_module(target)

    case Process.whereis(module) do
      nil ->
        Logger.warning("Crash: target not registered, target=#{inspect(target)}")
        :ok

      pid ->
        Logger.info("Crash: killing #{inspect(target)}, pid=#{inspect(pid)}")
        Process.exit(pid, :kill)
        wait_for_restart(module, pid, timeout_ms)
    end
  end

  # --- Internal ---

  defp target_to_module(:markets_store), do: PerpWalk.Markets.Store
  defp target_to_module(:federation_store), do: PerpWalk.Federation.Store

  defp count_positions, do: length(MarketsFacade.list_all_positions())

  defp wait_for_restart(module, prior_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(module, prior_pid, deadline)
  end

  defp do_wait(module, prior_pid, deadline) do
    case Process.whereis(module) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(@restart_poll_ms)
          do_wait(module, prior_pid, deadline)
        end

      pid when pid == prior_pid ->
        # Same pid — supervisor hasn't restarted it yet.
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(@restart_poll_ms)
          do_wait(module, prior_pid, deadline)
        end

      new_pid ->
        Logger.info("Crash: restart complete, module=#{inspect(module)}, pid=#{inspect(new_pid)}")
        :ok
    end
  end
end
