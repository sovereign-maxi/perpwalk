defmodule PerpWalk.Monero.Multisig.Scheduler do
  @moduledoc """
  Periodic Monero multisig info exchange across federation peers.

  Defense-in-depth against state drift: even if the post-spend hook
  in `Federation.Signer` misses a sync (process crash, transient
  failure, race), the periodic cycle catches up within the
  configured interval. Drift in proof-of-reserves attestation rounds
  is generally noticeable within minutes once it appears, so the
  default 10-minute interval bounds the maximum desync window
  without paying a meaningful constant cost.

  Halt-aware: ticks are skipped while the federation is halted. The
  scheduler doesn't pause its own loop — it just no-ops on tick, so
  resume picks up the next tick immediately without a restart.

  ## Configuration

      config :perpwalk, :monero,
        multisig_sync_interval_ms: 600_000,    # 10 minutes
        multisig_scheduler_enabled: true
  """

  use GenServer

  require Logger

  alias PerpWalk.Federation.Facade, as: FederationFacade
  alias PerpWalk.Monero.Facade, as: MoneroFacade

  @default_interval_ms 10 * 60 * 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, configured_interval_ms())
    schedule_next(interval)
    {:ok, %{interval_ms: interval}}
  end

  @impl true
  def handle_info(:sync, %{interval_ms: interval} = state) do
    if FederationFacade.halted?() do
      Logger.debug("Scheduler: skipping tick, reason=federation_halted")
    else
      run_sync()
    end

    schedule_next(interval)
    {:noreply, state}
  end

  # --- Internal ---

  defp run_sync do
    case MoneroFacade.sync_multisig_with_peers(triggered_by: :periodic) do
      {:ok, _result} -> :ok
      {:error, reason} -> Logger.warning("Scheduler: periodic sync failed, reason=#{inspect(reason)}")
    end
  rescue
    e -> Logger.error("Scheduler: tick crashed, reason=#{Exception.message(e)}")
  end

  defp schedule_next(interval_ms) do
    Process.send_after(self(), :sync, interval_ms)
  end

  defp configured_interval_ms do
    :perpwalk
    |> Application.get_env(:monero, [])
    |> Keyword.get(:multisig_sync_interval_ms, @default_interval_ms)
  end
end
