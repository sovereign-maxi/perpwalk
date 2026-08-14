defmodule PerpWalk.Sim.Actors.Behaviour do
  @moduledoc """
  Contract for sim actors.

  An actor is a GenServer started by `PerpWalk.Sim.Supervisor`
  that participates in a simulation run as a creator, voter,
  trader, disputer, guardian, or claimer. Each actor holds a
  fixed `account_id` (registered via `Identity.Facade.register/0`
  at start), a strategy variant (`:honest`, `:dishonest`,
  `:sybil`, etc.), and per-actor RNG state seeded from the run
  seed plus the actor index.

  ## Tick contract

  The engine sends `:tick` messages on each simulation tick.
  Actors handle ticks via `handle_info(:tick, state)` and call
  domain Facades (`Markets.Facade`, `Federation.Facade`, etc.)
  directly — no action-dispatch layer. Each actor runs its
  strategy independently and updates local state.

  ## State shape

  Actors hold at minimum:

  - `:account_id` — the actor's identity, set at start
  - `:strategy` — the variant atom
  - `:rng` — per-actor RNG state, seeded once from run seed
  - `:tick_count` — number of ticks processed
  - actor-specific tracking (markets created, positions held, etc.)

  ## Termination

  Actors stop cleanly when `:halt` is received from the engine.
  No actor should hold non-WAL state that would be lost on stop —
  the WAL is the source of truth for everything actors do.
  """

  @type strategy :: atom()
  @type account_id :: binary()
  @type state :: %{
          required(:account_id) => account_id(),
          required(:strategy) => strategy(),
          required(:rng) => :rand.state(),
          required(:tick_count) => non_neg_integer(),
          optional(any()) => any()
        }

  @doc """
  Initializes the actor. Called by the GenServer at start_link.

  Receives the parsed opts (account_id, strategy, seed, plus
  actor-specific config) and returns the initial state.
  """
  @callback init(opts :: keyword()) :: {:ok, state()}

  @doc """
  Runs one tick of the actor's strategy. May call any domain
  Facade. Returns the updated state.
  """
  @callback handle_tick(now :: DateTime.t(), state :: state()) :: {:ok, state()}

  @optional_callbacks init: 1, handle_tick: 2
end
