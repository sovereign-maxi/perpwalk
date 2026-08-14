defmodule PerpWalk.Events.Telemetry do
  @moduledoc """
  Telemetry context events: alerts, system status, Tor health.

  Generic alert events (`AlertFired`, `AlertResolved`) carry the rule
  name + severity + reason, so any LiveView can render them without
  knowing about the specific failure mode. Domain-specific shadows
  (`TorDown`, `TorDegraded`, `TorRecovered`) exist so user-facing UI
  can subscribe to a narrow signal without filtering by alert name.
  """

  defmodule SystemStatusChanged do
    @moduledoc false
    @enforce_keys [:status, :timestamp]
    defstruct [:status, :timestamp]
    @type t :: %__MODULE__{status: atom(), timestamp: DateTime.t()}
  end

  defmodule AlertFired do
    @moduledoc false
    @enforce_keys [:name, :domain, :severity, :reason, :timestamp]
    defstruct [:name, :domain, :severity, :reason, :timestamp]

    @type t :: %__MODULE__{
            name: atom(),
            domain: String.t(),
            severity: atom(),
            reason: String.t(),
            timestamp: DateTime.t()
          }
  end

  defmodule AlertResolved do
    @moduledoc false
    @enforce_keys [:name, :domain, :timestamp]
    defstruct [:name, :domain, :detail, :timestamp]

    @type t :: %__MODULE__{
            name: atom(),
            domain: String.t(),
            detail: String.t() | nil,
            timestamp: DateTime.t()
          }
  end

  defmodule TorDown do
    @moduledoc false
    @enforce_keys [:timestamp]
    defstruct [:reason, :timestamp]
    @type t :: %__MODULE__{reason: String.t() | nil, timestamp: DateTime.t()}
  end

  defmodule TorDegraded do
    @moduledoc false
    @enforce_keys [:timestamp]
    defstruct [:reason, :timestamp]
    @type t :: %__MODULE__{reason: String.t() | nil, timestamp: DateTime.t()}
  end

  defmodule TorRecovered do
    @moduledoc false
    @enforce_keys [:timestamp]
    defstruct [:timestamp]
    @type t :: %__MODULE__{timestamp: DateTime.t()}
  end
end
