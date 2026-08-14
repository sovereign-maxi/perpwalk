defmodule PerpWalk.Storage.Replication.Nonces do
  @moduledoc """
  ETS-backed single-use cache for replication and federation RPC
  request nonces.

  The HMAC layer in `PerpWalk.Storage.Replication.Auth` and
  `PerpWalk.Federation.RPC.Auth` rejects requests outside the
  configured clock-skew window, but a captured request inside that
  window could otherwise be replayed. This cache records every
  accepted nonce; subsequent presentations of the same nonce within
  the skew window are rejected.

  Atomic `:ets.insert_new/2` makes accept-and-record one operation
  so two concurrent verifications of the same captured request can't
  both succeed.

  ## Domain namespacing

  Federation RPC and storage replication share this cache but live
  in distinct namespaces — each accept is keyed on
  `{domain, nonce}` rather than `nonce` alone. Without the
  discriminator a single 16-byte nonce collision (vanishingly
  unlikely but real) would silently drop the legitimate request on
  whichever channel hit second, AND captured nonces in one channel
  would consume the other channel's nonce space. Pass
  `:federation_rpc` or `:replication` per accept call.

  ## Why a GenServer

  - Owns the named ETS table; no lazy creation race during boot.
  - Drives the periodic sweep that drops nonces older than the
    configured skew window.
  """

  use GenServer

  require Logger

  @type domain :: :federation_rpc | :replication

  @table __MODULE__

  # Sweep about as often as the skew window so the table stays small
  # without burning the scheduler.
  @sweep_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Records `nonce` as seen at `timestamp_ms`. Returns `:ok` if this
  is the first time the cache has seen it, `{:error, :replay}` if
  the nonce was recorded earlier within the skew window, or
  `{:error, :unavailable}` if the ETS table has been torn down
  unexpectedly.

  Fails closed: callers MUST treat `:unavailable` as a hard reject
  rather than letting the request through.
  """
  @spec accept(domain(), binary(), integer()) :: :ok | {:error, :replay | :unavailable}
  def accept(domain, nonce, timestamp_ms)
      when domain in [:federation_rpc, :replication] and is_binary(nonce) and
             is_integer(timestamp_ms) do
    if :ets.insert_new(@table, {{domain, nonce}, timestamp_ms}) do
      :ok
    else
      {:error, :replay}
    end
  rescue
    ArgumentError ->
      Logger.error("Nonces: table missing — failing closed (replay protection unavailable)")
      {:error, :unavailable}
  end

  @doc "ETS table name. Public so tests can clear it between runs."
  @spec table_name() :: atom()
  def table_name, do: @table

  # --- GenServer ---

  @impl true
  def init(_opts) do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

      _ref ->
        @table
    end

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff =
      System.system_time(:millisecond) -
        PerpWalk.Storage.Replication.Auth.clock_skew_ms() * 2

    spec = [{{{:_, :_}, :"$1"}, [{:<, :"$1", cutoff}], [true]}]
    removed = :ets.select_delete(@table, spec)

    if removed > 0, do: Logger.debug("Nonces: swept expired nonces, count=#{removed}")

    schedule_sweep()
    {:noreply, state}
  rescue
    ArgumentError ->
      schedule_sweep()
      {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
