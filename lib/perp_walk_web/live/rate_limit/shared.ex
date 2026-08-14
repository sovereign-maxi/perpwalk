defmodule PerpWalkWeb.Live.RateLimit.Shared do
  @moduledoc """
  Account-scoped rate limiter backed by a single shared ETS table.
  Survives WebSocket reconnects — an attacker opening many sockets
  to defeat the per-socket `PerpWalkWeb.Live.RateLimit` still hits
  the same bucket here, keyed on their authenticated `account_id`.

  Used only for events where domain-level idempotency does NOT
  already gate real state changes:

  - `:claim_submit` — each successful submit queues a Federation
    Payout. Even though `Federation.Rules` and the per-position
    uniqueness check filter abuse downstream, hammering the
    endpoint burns WAL writes and ETS inserts at the leader.
  - `:dispute_open` — each successful call allocates a fresh
    Monero subaddress + writes a Dispute row.
  - `:trade_open` — each successful call allocates a fresh Monero
    subaddress via Darks and writes a Quote row. The per-socket
    cap is defeated by an attacker who rotates Tor circuits to
    open many sockets under the same account; the account-scoped
    bucket here is the hard ceiling against wallet RPC saturation
    and quote-table pollution.

  Other rate-limited events stay on the per-socket bucket because
  their domain layer (`Voter` dedup, `Resolver` state machine,
  `Trader.fill_quote` deletion-on-fill) already serialises
  by single dedup keys — per-socket is sufficient there.

  Anonymous callers (`account_id == nil`) get `:ok` directly. The
  load-bearing events all require an account anyway; checking
  before the auth check would just pollute the table with
  shared-nil rows.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @sweep_interval_ms 60_000

  # Hard ceilings across all of an account's connected sockets.
  # Deliberately stricter than the per-socket limits because this is
  # the "absolute cap", not the "UX-friendly cap".
  #
  # `:comment_submit` lives here because each successful comment
  # writes a Nostr event to relay + WAL — domain dedup doesn't gate
  # rapid distinct comments, so the per-socket bucket alone can be
  # bypassed by an attacker rotating sockets under the same account.
  @defaults %{
    claim_submit: {20, 60_000},
    dispute_claim_submit: {10, 60_000},
    dispute_open: {10, 60_000},
    # `:trade_open` was previously 30/min — but each create_quote
    # allocates a permanent Monero wallet subaddress. A logged-in
    # attacker over Tor at the prior cap could burn 30 indices per
    # account-minute, with no recovery once allocated. 3/min is well
    # above any realistic human pace (a discretionary trader places
    # well under one quote per minute) and bounds the per-account
    # subaddress cost-per-minute by a factor of 10.
    trade_open: {3, 60_000},
    # `:create_market` keys on the per-account shared bucket because
    # each market also allocates a permanent subaddress. 3/hour caps
    # one attacker session at ~72 markets/day; combined with the
    # existing :awaiting_deposit auto-void Scheduler tick, the cost
    # of an abandoned-market storm is bounded.
    create_market: {3, 3_600_000},
    comment_submit: {30, 60_000},
    vote: {30, 60_000},
    resolve_submit: {10, 60_000}
  }

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Checks the shared bucket for `{account_id, kind}`. Returns `:ok`
  if under the cap, `{:error, :rate_limited}` if at or over. No-op
  (returns `:ok`) when `account_id` is `nil`.
  """
  @spec check(String.t() | nil, atom()) :: :ok | {:error, :rate_limited}
  def check(nil, _kind), do: :ok

  def check(account_id, kind) when is_binary(account_id) and is_atom(kind) do
    # Atomic check-and-insert. Two concurrent LiveViews under the
    # same account hitting `check/2` between :ets.lookup and the
    # follow-up :ets.insert would both see the same "under cap" view
    # and both succeed even when they should have collectively been
    # rejected. Serialising via the GenServer collapses the window —
    # the check and the insert happen inside the same handle_call.
    GenServer.call(__MODULE__, {:check, account_id, kind})
  catch
    :exit, _ ->
      # GenServer down (boot race, supervisor restart window,
      # deployment interlude). Fail CLOSED: without the GenServer we
      # can't rate-limit, so the safe posture is to refuse. Pre-fix
      # this returned `:ok` (fail-open), which meant an attacker
      # timing their burst to a Shared supervisor restart could
      # burn through the account-scoped ceilings on trades /
      # disputes / claims during the restart window. Failing closed
      # is briefly annoying for legitimate users during a real
      # restart; failing open is a security regression under the
      # same conditions.
      {:error, :rate_limited}
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    create_table()
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:check, account_id, kind}, _from, state) do
    {max, window_ms} = limits_for(kind)
    now = System.monotonic_time(:millisecond)
    key = {account_id, kind}

    reply =
      case :ets.lookup(@table, key) do
        [{^key, timestamps}] ->
          fresh = Enum.filter(timestamps, fn ts -> now - ts < window_ms end)

          if length(fresh) >= max do
            :telemetry.execute(
              [:perp_walk_web, :live, :rate_limited_shared],
              %{count: 1},
              %{kind: kind}
            )

            {:error, :rate_limited}
          else
            :ets.insert(@table, {key, [now | fresh]})
            :ok
          end

        [] ->
          :ets.insert(@table, {key, [now]})
          :ok
      end

    {:reply, reply, state}
  rescue
    ArgumentError ->
      # Table missing — the limiter cannot account, so refuse.
      # Fail-closed, mirroring check/2's GenServer-down posture.
      :telemetry.execute(
        [:perp_walk_web, :live, :rate_limiter_unavailable],
        %{count: 1},
        %{kind: kind}
      )

      {:reply, {:error, :rate_limited}, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - max_window_ms() * 2

    @table
    |> :ets.tab2list()
    |> Enum.each(fn {key, timestamps} ->
      fresh = Enum.filter(timestamps, fn ts -> ts >= cutoff end)

      if fresh == [] do
        :ets.delete(@table, key)
      else
        :ets.insert(@table, {key, fresh})
      end
    end)

    schedule_sweep()
    {:noreply, state}
  rescue
    ArgumentError ->
      schedule_sweep()
      {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  defp create_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ref ->
        @table
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp limits_for(kind) do
    overrides =
      :perpwalk
      |> Application.get_env(__MODULE__, [])
      |> Map.new()

    Map.get(overrides, kind) || Map.get(@defaults, kind) || {30, 60_000}
  end

  defp max_window_ms do
    @defaults
    |> Map.values()
    |> Enum.map(&elem(&1, 1))
    |> Enum.max(fn -> 60_000 end)
  end
end
