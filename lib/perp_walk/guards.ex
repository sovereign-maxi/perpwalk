defmodule PerpWalk.Guards do
  @moduledoc """
  Centralised operational guards for write-path entry points.

  Every operation that creates, modifies, or moves state must call
  `ensure_operational!/0` before proceeding. This prevents any new
  state from landing on a node's local WAL when the federation
  can't make safe forward progress: lost quorum, disk-critical,
  `/data` unmounted, or an operator-initiated halt.

  Reads directly from `:persistent_term` — sub-microsecond, no
  GenServer call, no ETS lookup. Cheap enough to put at the top of
  every mutation.

  See `PerpWalk.Telemetry.Health.System` for the writer side.
  """

  alias PerpWalk.Telemetry.Facade, as: TelemetryFacade

  defmodule SystemHaltedError do
    @moduledoc "Raised when a write operation is attempted while the system is halted."
    defexception [:message]

    @impl true
    def exception(reason) do
      %__MODULE__{message: "system is halted: #{reason}"}
    end
  end

  defmodule ProdSafetyError do
    @moduledoc "Raised when a module marked `__test_only__?` is resolved in `:env == :prod`."
    defexception [:message]

    @impl true
    def exception(module) do
      %__MODULE__{
        message: "prod safety violation: #{inspect(module)} is test-only and cannot run in :prod"
      }
    end
  end

  @doc """
  Raises `SystemHaltedError` if the system is halted.

  Call at the top of every write-path entry point.
  """
  @spec ensure_operational!() :: :ok
  def ensure_operational! do
    if TelemetryFacade.halted?() do
      raise SystemHaltedError, TelemetryFacade.halt_reason() || "unknown"
    end

    :ok
  end

  @doc """
  Returns `true` if the system is operational (not halted).

  Use for conditional checks where raising is not appropriate — UI
  rendering, scheduler tick short-circuits, conditional logging.
  """
  @spec operational?() :: boolean()
  def operational? do
    not TelemetryFacade.halted?()
  end

  @doc "Inverse of `operational?/0`. Convenience for `cond` chains."
  @spec halted?() :: boolean()
  def halted?, do: TelemetryFacade.halted?()

  @doc """
  Refuses to proceed if `module` exports `__test_only__?/0` returning
  `true` AND `:perpwalk, :env` is `:prod`. Call from
  `Application.assert_release_env!/0` at boot and from every facade
  that resolves a swappable client on each call — catches both release
  boot and post-boot config drift via `iex --remsh` or a hot
  `Application.put_env`.

  Modules opt in to being test-only by defining
  `def __test_only__?, do: true`.
  """
  @spec assert_prod_safe_module!(module()) :: :ok
  def assert_prod_safe_module!(module) when is_atom(module) do
    if Application.get_env(:perpwalk, :env) == :prod and test_only?(module) do
      raise ProdSafetyError, module
    end

    :ok
  end

  @spec test_only?(module()) :: boolean()
  defp test_only?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__test_only__?, 0) and
      module.__test_only__?() == true
  end
end
