defmodule PerpWalk.Markets.Status do
  @moduledoc """
  Semantic helpers over the `PerpWalk.Markets.Market` state machine.

  Both web layers (`PerpWalkWeb`, `PerpWalkAdminWeb`) ask "is this
  status terminal / trading / awaiting operator action" via this
  module rather than pattern-matching on raw atoms inline. New
  states added to the state machine surface in one place when the
  taxonomy evolves; the presentation choices each web layer makes
  (collapse vs distinguish, dropdown labels, widget counts) stay
  where they belong — at the web boundary.

  Not presentation. Neither labels nor variants live here. The
  module answers operational questions about an atom; each web
  layer maps those answers to its own user-facing surface.

  Reserved for status-of-the-Market — Position, Dispute, Payout, and
  Quote statuses have their own state machines and predicates live
  alongside them where applicable.
  """

  alias PerpWalk.Markets.Market

  @typedoc "Internal Market status atom — see `Market.status/0`."
  @type status :: Market.status()

  @doc """
  Trading is open against the AMM.
  """
  @spec trading?(status()) :: boolean()
  def trading?(:active), do: true
  def trading?(_), do: false

  @doc """
  Market is in its proposal phase, before trading opens. Covers
  the creator's deposit-confirmation wait (`:awaiting_deposit`)
  and the listing-vote window (`:pending`) — both render to users
  as the PENDING pill.
  """
  @spec listing_window?(status()) :: boolean()
  def listing_window?(:awaiting_deposit), do: true
  def listing_window?(:pending), do: true
  def listing_window?(_), do: false

  @doc """
  Trading has ended and the creator has not yet submitted an
  outcome. Sits here until either `submit_resolution` is called
  or the auto-void grace window elapses.
  """
  @spec awaiting_creator_resolution?(status()) :: boolean()
  def awaiting_creator_resolution?(:expired), do: true
  def awaiting_creator_resolution?(_), do: false

  @doc """
  Creator has submitted an outcome; the 24-hour dispute window is
  open. Users can flag the resolution; guardians can acknowledge
  or reverse before `settle/1` is called.
  """
  @spec in_dispute_window?(status()) :: boolean()
  def in_dispute_window?(:resolving), do: true
  def in_dispute_window?(_), do: false

  @doc """
  Market needs operator attention — either to submit a resolution
  or to watch / settle the dispute window. Union of
  `awaiting_creator_resolution?/1` and `in_dispute_window?/1`.
  Used by operator-side queue / backlog counters and by the public
  CLOSED bucket (which collapses both into one user-facing pill).
  """
  @spec awaiting_operator_action?(status()) :: boolean()
  def awaiting_operator_action?(status),
    do: awaiting_creator_resolution?(status) or in_dispute_window?(status)

  @doc """
  Market has reached a terminal state — `:settled`, `:voided`, or
  `:rejected`. No further transitions; positions are claimable
  (settled / voided) or burned (rejected).
  """
  @spec terminal?(status()) :: boolean()
  def terminal?(:settled), do: true
  def terminal?(:voided), do: true
  def terminal?(:rejected), do: true
  def terminal?(_), do: false

  @doc """
  Market contributes to currently-locked value — open positions
  may still pay out or be refunded. Excludes terminal states
  (positions are already settled / refunded / burned at that
  point). Used by TVL aggregators and the in-flight markets index.
  """
  @spec in_flight?(status()) :: boolean()
  def in_flight?(status),
    do:
      listing_window?(status) or trading?(status) or
        awaiting_operator_action?(status)
end
