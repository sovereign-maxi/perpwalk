defmodule PerpWalk.Federation.Signing.Peer.Throttle do
  @moduledoc """
  Sliding-window rate cap on the volume this peer is willing to sign
  for, regardless of who is asking.

  `PerpWalk.Federation.Signing.Peer.Policy` enforces per-transaction
  caps (50 XMR per recipient, 100 XMR per signing round). It is
  intentionally stateless. That leaves a compromised peer free to
  grind at the per-round cap indefinitely — RPC tick after RPC tick,
  100 XMR each, bounded only by the multisig wallet balance and
  operator vigilance.

  This module is the per-peer time-aware cap that the policy doesn't
  carry. Every `Federation.RPC.Peer.sign/1` records an accepted
  signing round here BEFORE invoking the wallet RPC. The recorded
  amount is the total outflow across all recipients as parsed by
  `Darks.Multisig.describe/1`. Records older than the configured
  window are pruned on every access; new requests are rejected when
  recording would push the running total over the cap.

  ## Defaults

  - 200 XMR per 6-hour window — leaves headroom for legitimate
    payouts at expected launch volumes, while bounding the
    one-day worst-case drain by a compromised peer at four
    rounds' worth (≈800 XMR/day).

  ## Override

      config :perpwalk, :peer_throttle,
        max_total_piconeros: 200 * 1_000_000_000_000,
        window_seconds: 6 * 3_600

  ## Persistence

  In-memory only. A node restart resets the window. This is
  intentional for launch posture — persistence would add WAL
  coupling for a defense-in-depth gate whose first-line defense
  is the operator's monitoring of `PayoutSubmitted` events. If
  an attacker can also trigger a restart, the surrounding
  monitoring should already be firing.

  ## Time source

  Window arithmetic uses `System.monotonic_time(:millisecond)`, not
  wall-clock. A forward NTP step on a peer would otherwise prune
  in-window entries early and reset the grind cap on the very threat
  model this throttle exists to bound.
  """

  use GenServer

  require Logger

  @default_max_total_piconeros 200 * 1_000_000_000_000
  @default_window_seconds 6 * 3_600

  @type entry :: {integer(), pos_integer()}
  @type state :: %{
          entries: [entry()],
          max_total_piconeros: pos_integer(),
          window_ms: pos_integer()
        }

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Atomic check-and-record. Accepts `amount_piconeros` if the running
  window total would stay within cap; otherwise rejects without
  recording.

  Test seam: the second arity takes an explicit `now_ms` so tests
  can advance time without `Process.sleep`.
  """
  @spec reserve(pos_integer()) :: :ok | {:reject, String.t()}
  def reserve(amount_piconeros),
    do: reserve(amount_piconeros, System.monotonic_time(:millisecond))

  @spec reserve(pos_integer(), integer()) :: :ok | {:reject, String.t()}
  def reserve(amount_piconeros, now_ms)
      when is_integer(amount_piconeros) and amount_piconeros > 0 and
             is_integer(now_ms) do
    GenServer.call(__MODULE__, {:reserve, amount_piconeros, now_ms})
  end

  @doc """
  Snapshot of the current window. Returns `current_total`,
  configured `cap`, and `window_seconds` for the operator
  dashboard / observability.
  """
  @spec status() :: %{current_total: non_neg_integer(), cap: pos_integer(), window_seconds: pos_integer()}
  def status, do: status(System.monotonic_time(:millisecond))

  @spec status(integer()) :: %{current_total: non_neg_integer(), cap: pos_integer(), window_seconds: pos_integer()}
  def status(now_ms) when is_integer(now_ms) do
    GenServer.call(__MODULE__, {:status, now_ms})
  end

  @doc """
  Clears the recorded window. Test seam only — sealed in `:prod` to
  prevent an iex caller from wiping the accumulated throttle
  running-total and thereby signing well past the cap in a single
  burst. Same posture as `Signer.set_backend/1` and
  `Scheduler.reconfigure/1`.
  """
  @spec reset() :: :ok | {:error, :production_seal}
  def reset do
    if Application.get_env(:perpwalk, :env) == :prod do
      {:error, :production_seal}
    else
      GenServer.call(__MODULE__, :reset)
    end
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    cap = config_value(:max_total_piconeros, @default_max_total_piconeros)
    window_ms = config_value(:window_seconds, @default_window_seconds) * 1_000

    {:ok, %{entries: [], max_total_piconeros: cap, window_ms: window_ms}}
  end

  @impl true
  def handle_call({:reserve, amount, now_ms}, _from, state) do
    pruned = prune(state.entries, now_ms - state.window_ms)
    running_total = sum_amounts(pruned)

    if running_total + amount > state.max_total_piconeros do
      Logger.warning(
        "Throttle: signing refused, projected=#{running_total + amount}, cap=#{state.max_total_piconeros}, window_s=#{div(state.window_ms, 1_000)}"
      )

      reason =
        "peer_throttle: projected #{running_total + amount} piconeros exceeds cap " <>
          "#{state.max_total_piconeros} in last #{div(state.window_ms, 1_000)}s window"

      {:reply, {:reject, reason}, %{state | entries: pruned}}
    else
      {:reply, :ok, %{state | entries: [{now_ms, amount} | pruned]}}
    end
  end

  def handle_call({:status, now_ms}, _from, state) do
    pruned = prune(state.entries, now_ms - state.window_ms)

    snapshot = %{
      current_total: sum_amounts(pruned),
      cap: state.max_total_piconeros,
      window_seconds: div(state.window_ms, 1_000)
    }

    {:reply, snapshot, %{state | entries: pruned}}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | entries: []}}
  end

  # --- Internal ---

  defp prune(entries, cutoff_ms) do
    Enum.filter(entries, fn {ts, _} -> ts >= cutoff_ms end)
  end

  defp sum_amounts(entries) do
    Enum.reduce(entries, 0, fn {_ts, amt}, acc -> acc + amt end)
  end

  defp config_value(key, default) do
    Application.get_env(:perpwalk, :peer_throttle, [])
    |> Keyword.get(key, default)
  end
end
