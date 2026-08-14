defmodule PerpWalk.Markets.Vote do
  @moduledoc """
  A community vote on a market.

  Each `account_id` may cast at most one vote per market — uniqueness
  is enforced upstream by the vote store keyed on `{account_id,
  market_id}`. Votes drive moderation: net negative votes during a
  market's PENDING window cause the creation deposit to be burned
  (see `Markets.Moderation`).
  """

  @type direction :: :up | :down

  @type t :: %__MODULE__{
          account_id: binary(),
          market_id: binary(),
          direction: direction(),
          created_at: DateTime.t()
        }

  @enforce_keys [:account_id, :market_id, :direction, :created_at]
  defstruct [:account_id, :market_id, :direction, :created_at]

  # --- Public API ---

  @doc "Creates a new vote with the current timestamp."
  @spec new(binary(), binary(), direction()) :: t()
  def new(account_id, market_id, direction)
      when is_binary(account_id) and is_binary(market_id) and direction in [:up, :down] do
    %__MODULE__{
      account_id: account_id,
      market_id: market_id,
      direction: direction,
      created_at: DateTime.utc_now()
    }
  end
end
