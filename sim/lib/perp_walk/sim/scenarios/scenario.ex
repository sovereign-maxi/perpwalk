defmodule PerpWalk.Sim.Scenarios.Scenario do
  @moduledoc """
  Contract for sim scenarios.

  A scenario configures the actor mix, the duration, and any
  scripted events (halts, crashes, etc.) for a single sim run.
  Scenarios are stateless data — `init/1` returns a config map
  that the engine consumes; `on_tick/3` lets the scenario inject
  events at specific simulated timestamps.

  ## Lifecycle

  1. `init/1` — engine calls once at run start with the parsed
     CLI args; returns the scenario state plus the actor mix.
  2. `on_tick/3` — engine calls each tick with the current
     timestamp, tick number, and scenario state; returns any
     scripted events plus the next state.

  ## Scripted events

  - `{:halt, federation}` — call `Federation.Console.halt/0`.
  - `{:resume, federation}` — call `Federation.Console.resume/0`.
  - `{:crash, supervisor_atom}` — kill a named supervisor child
    so its restart logic gets exercised.
  - `{:override_resolution, market_id, outcome}` — operator
    override via `Markets.Facade.override_resolution/2`.

  Scenarios that don't need any of these can return `{:ok, [], state}`
  on every tick — `Baseline` does exactly this.
  """

  @type event ::
          :halt
          | :resume
          | {:crash, supervisor :: atom()}
          | {:override_resolution, market_id :: binary(), outcome :: atom()}

  @type actor_spec :: %{
          required(:role) => atom(),
          required(:strategy) => atom(),
          required(:count) => pos_integer(),
          optional(:opts) => keyword()
        }

  @type state :: %{required(any()) => any()}

  @doc """
  Returns the actor mix and initial scenario state for the run.

  The actor mix is a list of `actor_spec` maps; the engine starts
  one process per actor across all specs.
  """
  @callback init(opts :: keyword()) :: {:ok, %{actors: [actor_spec()], state: state()}}

  @doc """
  Runs one scenario tick. Returns scripted events to execute
  this tick plus the updated scenario state.
  """
  @callback on_tick(now :: DateTime.t(), tick :: non_neg_integer(), state :: state()) ::
              {:ok, [event()], state()}
end
