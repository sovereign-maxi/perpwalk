defmodule PerpWalk.Events.Reserves do
  @moduledoc """
  Reserves context events: proof generation and deficit detection.
  """

  defmodule ProofGenerated do
    @moduledoc """
    A reserve proof was generated and published.

    Fires every proof-generation interval. Subscribers (admin
    dashboard, Nostr alerts) can react without re-fetching the proof.
    """
    @enforce_keys [:proof_id, :ratio, :status, :timestamp]
    defstruct [:proof_id, :ratio, :status, :timestamp]

    @type t :: %__MODULE__{
            proof_id: term(),
            ratio: number() | :infinity,
            status: atom(),
            timestamp: DateTime.t()
          }
  end

  defmodule ReserveDeficit do
    @moduledoc "Reserves dropped below outstanding liabilities."
    @enforce_keys [:ratio, :deficit_piconeros, :previous_status, :timestamp]
    defstruct [:ratio, :deficit_piconeros, :previous_status, :timestamp]

    @type t :: %__MODULE__{
            ratio: number(),
            deficit_piconeros: non_neg_integer(),
            previous_status: atom(),
            timestamp: DateTime.t()
          }
  end

  defmodule ReserveCriticalDeficit do
    @moduledoc "Reserve deficit crossed the critical threshold."
    @enforce_keys [:ratio, :deficit_piconeros, :previous_status, :timestamp]
    defstruct [:ratio, :deficit_piconeros, :previous_status, :timestamp]

    @type t :: %__MODULE__{
            ratio: number(),
            deficit_piconeros: non_neg_integer(),
            previous_status: atom(),
            timestamp: DateTime.t()
          }
  end

  defmodule ReserveRecovered do
    @moduledoc "Reserves returned to a non-deficit status."
    @enforce_keys [:ratio, :previous_status, :timestamp]
    defstruct [:ratio, :previous_status, :timestamp]

    @type t :: %__MODULE__{
            ratio: number(),
            previous_status: atom(),
            timestamp: DateTime.t()
          }
  end
end
