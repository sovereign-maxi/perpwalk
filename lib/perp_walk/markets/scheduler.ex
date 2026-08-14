defmodule PerpWalk.Markets.Scheduler do
  @moduledoc """
  Thin tick driver for time-driven market transitions.

  All eligibility logic — what transitions are allowed and when —
  lives in `PerpWalk.Markets.Services.Resolver.tick/2`. This module's
  only job is to fire on an interval, gate on `Guards.operational?/0`,
  hand control to the Resolver, and sweep expired quotes as a side
  errand. The Resolver is the single source of truth for transition
  preconditions; this module owns timing, not policy.
  """

  use GenServer

  require Logger

  alias PerpWalk.Guards
  alias PerpWalk.Markets.Facade
  alias PerpWalk.Markets.Services.Resolver
  alias PerpWalk.Role

  @default_tick_interval_ms 30_000
  @default_pending_window_seconds 86_400
  @default_dispute_window_seconds 86_400
  @default_auto_void_grace_seconds 86_400

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Run a synchronous tick. Useful from iex during incident response
  and from tests that drive transitions explicitly.
  """
  @spec run_now() :: :ok
  def run_now do
    GenServer.call(__MODULE__, :run_now, 30_000)
  end

  @doc """
  Reconfigures the running scheduler. Sim runs use this to push
  compressed window values into the already-started scheduler so
  markets progress through their lifecycle in sim-compressed time.

  Refuses in `:prod`. An iex caller able to shrink `tick_interval_ms`
  to 1 hammers ETS + Resolver; extending `auto_void_grace_seconds`
  defeats the failsafe that auto-voids stuck markets. Production
  configures these via `:perpwalk, :markets_scheduler` at init.

  Accepts any of `:tick_interval_ms`, `:pending_window_seconds`,
  `:dispute_window_seconds`, `:auto_void_grace_seconds`. Unspecified
  keys are unchanged.
  """
  @spec reconfigure(keyword()) :: :ok | {:error, :production_seal}
  def reconfigure(opts) when is_list(opts) do
    if Application.get_env(:perpwalk, :env) == :prod do
      {:error, :production_seal}
    else
      GenServer.call(__MODULE__, {:reconfigure, opts}, 30_000)
    end
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    state = %{
      tick_interval_ms:
        Keyword.get(
          opts,
          :tick_interval_ms,
          get_config(:tick_interval_ms, @default_tick_interval_ms)
        ),
      pending_window_seconds:
        Keyword.get(
          opts,
          :pending_window_seconds,
          get_config(:pending_window_seconds, @default_pending_window_seconds)
        ),
      dispute_window_seconds:
        Keyword.get(
          opts,
          :dispute_window_seconds,
          get_config(:dispute_window_seconds, @default_dispute_window_seconds)
        ),
      auto_void_grace_seconds:
        Keyword.get(
          opts,
          :auto_void_grace_seconds,
          get_config(:auto_void_grace_seconds, @default_auto_void_grace_seconds)
        )
    }

    schedule_tick(state.tick_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:run_now, _from, state) do
    do_tick(state)
    {:reply, :ok, state}
  end

  def handle_call({:reconfigure, opts}, _from, state) do
    new_state =
      Map.merge(
        state,
        opts
        |> Keyword.take([
          :tick_interval_ms,
          :pending_window_seconds,
          :dispute_window_seconds,
          :auto_void_grace_seconds
        ])
        |> Map.new()
      )

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:tick, state) do
    do_tick(state)
    schedule_tick(state.tick_interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Tick ---

  defp do_tick(state) do
    cond do
      not Guards.operational?() ->
        Logger.debug("Scheduler: skipping tick, system halted")

      not Role.designated_processor?() ->
        # Lifecycle writes (activate/expire/settle/void, quote expiry)
        # are cluster-state mutations — only the designated processor
        # drives them. Followers receive the results via WAL
        # replication; two nodes settling from lagging local state
        # would diverge the books.
        Logger.debug("Scheduler: skipping tick, not the designated processor")

      true ->
        now = DateTime.utc_now()

        Resolver.tick(now,
          pending_window_seconds: state.pending_window_seconds,
          dispute_window_seconds: state.dispute_window_seconds,
          auto_void_grace_seconds: state.auto_void_grace_seconds
        )

        expire_quotes(now)
    end
  end

  # Quote expiry is independent of the market state machine — quotes
  # are pre-trade reservations on subaddresses, not part of the
  # market lifecycle, so they stay here rather than moving into
  # Resolver.tick.
  defp expire_quotes(now) do
    now
    |> safe_list_quotes_expired()
    |> Enum.reject(&underpayment_refund_in_flight?/1)
    |> Enum.each(fn quote ->
      case PerpWalk.Markets.Store.put_quote_expired(quote.id) do
        :ok ->
          Logger.debug("Scheduler: quote expired, quote_id=#{quote.id}")

        {:error, reason} ->
          Logger.warning("Scheduler: expire quote failed, quote_id=#{quote.id}, reason=#{inspect(reason)}")
      end
    end)
  end

  # A quote with an in-flight underpayment refund must not be deleted:
  # the refund's rules check re-reads the quote row for its amount
  # bound, and deleting it strands the refund in :awaiting_operator
  # with the funds in custody. Once the refund is terminal the quote
  # expires on a later tick.
  defp underpayment_refund_in_flight?(quote) do
    PerpWalk.Federation.Facade.quote_underpayment_pending?(quote.id)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp safe_list_quotes_expired(now) do
    Facade.list_quotes_expired(now)
  rescue
    e ->
      Logger.warning("Scheduler: list_quotes_expired failed, reason=#{inspect(e)}")
      []
  catch
    :exit, _ -> []
  end

  defp schedule_tick(interval) do
    Process.send_after(self(), :tick, interval)
  end

  defp get_config(key, default) do
    Application.get_env(:perpwalk, :markets_scheduler, [])
    |> Keyword.get(key, default)
  end
end
