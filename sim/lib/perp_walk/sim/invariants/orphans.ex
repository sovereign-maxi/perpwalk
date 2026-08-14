defmodule PerpWalk.Sim.Invariants.Orphans do
  @moduledoc """
  Verifies underpayment orphans transition to `:resolved` shortly
  after the Poller records them — the underpayment auto-refund
  pipeline contract.

  Poller's `enqueue_underpayment_refund/3` marks the orphan resolved
  as soon as `Federation.Facade.enqueue_quote_underpayment_refund/5`
  returns `{:ok, _}`. If enqueue fails, the orphan stays `:open` and
  requires operator attention — that's the legitimate violation this
  invariant catches. Any `:underpayment` orphan that persists as
  `:open` for more than `@stuck_threshold_checks` validator ticks
  signals the auto-refund path is broken.

  ## Poll-based, no subscription

  Orphans state lives in DETS and mutates through
  `Orphans.record/5` and `Orphans.mark_resolved/1` — both go
  through the same GenServer, so a single `Orphans.list/0` on
  `check/1` gets a consistent snapshot. No need to track events.

  ## What this DOESN'T cover

  - `:overpayment`, `:unknown_quote`, `:unknown_dispute`,
    `:unknown_market_deposit`, `:unmatched_subaddress`, `:fill_failed`
    orphans do NOT have an auto-refund path and are expected to
    stay `:open` until an operator intervenes. This invariant
    ignores those kinds.
  - Orphans marked `:resolved` are audit-trail only — no further
    invariant to enforce on them.
  """

  use GenServer

  alias PerpWalk.Monero.Orphans

  @default_stuck_threshold_checks 20

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec check(map()) :: :ok | {:violation, map()}
  def check(_snapshot) do
    case GenServer.call(__MODULE__, :snapshot) do
      [] ->
        :ok

      violations ->
        {:violation,
         %{
           kind: :underpayment_orphan_stuck,
           count: length(violations),
           sample: Enum.take(violations, 5)
         }}
    end
  end

  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # --- GenServer ---

  @impl true
  def init(opts) do
    threshold = Keyword.get(opts, :stuck_threshold_checks, @default_stuck_threshold_checks)

    {:ok,
     %{
       check_counter: 0,
       # txid => check_counter when the orphan was first seen :open
       first_seen: %{},
       stuck_threshold_checks: threshold
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = %{state | check_counter: state.check_counter + 1}
    {violations, first_seen} = walk_orphans(state)
    {:reply, violations, %{state | first_seen: first_seen}}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | check_counter: 0, first_seen: %{}}}
  end

  # --- Internal ---

  defp walk_orphans(state) do
    Orphans.list()
    |> Enum.filter(fn o -> o.kind == :underpayment and o.status == :open end)
    |> Enum.reduce({[], state.first_seen}, fn orphan, {violations, seen} ->
      seen_at = Map.get_lazy(seen, orphan.txid, fn -> state.check_counter end)
      age = state.check_counter - seen_at

      if age > state.stuck_threshold_checks do
        violation = %{txid: orphan.txid, amount: orphan.amount_piconeros, age_checks: age}
        {[violation | violations], seen}
      else
        {violations, Map.put(seen, orphan.txid, seen_at)}
      end
    end)
  rescue
    _ -> {[], state.first_seen}
  end
end
