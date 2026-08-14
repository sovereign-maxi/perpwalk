defmodule PerpWalk.Storage.Runner do
  @moduledoc false

  use GenServer, restart: :transient

  alias PerpWalk.Storage.Recovery

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}, {:continue, :run_recovery}}
  end

  @impl true
  def handle_continue(:run_recovery, state) do
    case Recovery.run() do
      {:ok, _report} ->
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Runner: recovery failed, halting startup, reason=#{inspect(reason)}")
        # Halt the entire VM — boot must fail visibly on irrecoverable
        # corruption rather than serve traffic with bad state.
        System.halt(1)
    end
  end
end
