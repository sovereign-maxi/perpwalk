defmodule PerpWalk.Events.Markets do
  @moduledoc """
  Markets bounded-context event taxonomy.

  Every struct here is a domain event — emitted by Markets services
  after a successful state transition, consumed by Telemetry, the
  dashboard LiveView, and any future Nostr publisher. Each struct has
  `@enforce_keys` to catch missing fields at construction time and a
  `Display` impl in `PerpWalk.Events.Display` for human rendering.
  """

  defmodule MarketCreated do
    @moduledoc false
    @enforce_keys [:market_id, :description, :category, :creator_account_id, :timestamp]
    defstruct [:market_id, :description, :category, :creator_account_id, :timestamp]

    @type t :: %__MODULE__{
            market_id: binary(),
            description: String.t(),
            category: atom(),
            creator_account_id: binary(),
            timestamp: DateTime.t()
          }
  end

  defmodule MarketDepositConfirmed do
    @moduledoc """
    Emitted when a market's creation deposit confirms on-chain. The
    market transitions `:awaiting_deposit → :pending` and the listing
    window opens.
    """
    @enforce_keys [:market_id, :deposit_subaddress_index, :timestamp]
    defstruct [:market_id, :deposit_subaddress_index, :timestamp]

    @type t :: %__MODULE__{
            market_id: binary(),
            deposit_subaddress_index: non_neg_integer() | nil,
            timestamp: DateTime.t()
          }
  end

  defmodule MarketActivated do
    @moduledoc false
    @enforce_keys [:market_id, :timestamp]
    defstruct [:market_id, :timestamp]

    @type t :: %__MODULE__{market_id: binary(), timestamp: DateTime.t()}
  end

  defmodule MarketRejected do
    @moduledoc false
    @enforce_keys [:market_id, :reputation, :timestamp]
    defstruct [:market_id, :reputation, :timestamp]

    @type t :: %__MODULE__{
            market_id: binary(),
            reputation: integer(),
            timestamp: DateTime.t()
          }
  end

  defmodule MarketExpired do
    @moduledoc false
    @enforce_keys [:market_id, :timestamp]
    defstruct [:market_id, :timestamp]

    @type t :: %__MODULE__{market_id: binary(), timestamp: DateTime.t()}
  end

  defmodule QuoteCreated do
    @moduledoc false
    @enforce_keys [
      :quote_id,
      :market_id,
      :account_id,
      :side,
      :contracts,
      :amount_paid_piconeros,
      :subaddress,
      :expires_at,
      :timestamp
    ]
    defstruct [
      :quote_id,
      :market_id,
      :account_id,
      :side,
      :contracts,
      :amount_paid_piconeros,
      :subaddress,
      :expires_at,
      :timestamp
    ]

    @type t :: %__MODULE__{
            quote_id: binary(),
            market_id: binary(),
            account_id: binary(),
            side: :yes | :no,
            contracts: pos_integer(),
            amount_paid_piconeros: pos_integer(),
            subaddress: String.t(),
            expires_at: DateTime.t(),
            timestamp: DateTime.t()
          }
  end

  defmodule QuoteFilled do
    @moduledoc false
    @enforce_keys [
      :quote_id,
      :position_id,
      :market_id,
      :account_id,
      :side,
      :contracts,
      :amount_paid_piconeros,
      :timestamp
    ]
    defstruct [
      :quote_id,
      :position_id,
      :market_id,
      :account_id,
      :side,
      :contracts,
      :amount_paid_piconeros,
      :deposit_txid,
      :timestamp
    ]

    @type t :: %__MODULE__{
            quote_id: binary(),
            position_id: binary(),
            market_id: binary(),
            account_id: binary(),
            side: :yes | :no,
            contracts: pos_integer(),
            amount_paid_piconeros: pos_integer(),
            deposit_txid: String.t() | nil,
            timestamp: DateTime.t()
          }
  end

  defmodule CreatorLpReturned do
    @moduledoc """
    The creator's liquidity return has confirmed on-chain. Fires
    when `Federation.Signer` finalises a `:creator_lp_return`
    payout — distinct from `PayoutSubmitted` (which is fired for
    every payout kind) so consumers can react to the LP-specific
    semantics (Nostr announcement, portfolio update, etc.).
    """
    @enforce_keys [:market_id, :creator_account_id, :amount_piconeros, :txid, :timestamp]
    defstruct [:market_id, :creator_account_id, :amount_piconeros, :txid, :timestamp]

    @type t :: %__MODULE__{
            market_id: binary(),
            creator_account_id: binary(),
            amount_piconeros: pos_integer(),
            txid: String.t(),
            timestamp: DateTime.t()
          }
  end

  defmodule QuoteDepositObserved do
    @moduledoc """
    The deposit transaction matching an open Quote has been observed
    on-chain (mempool or unconfirmed block) but is not yet through
    the confirmation threshold. UI consumers grey the QR / surface a
    "payment detected" indicator so the user knows further sends
    aren't needed.

    Distinct from `QuoteFilled`, which only fires after the deposit
    has crossed the confirmation threshold AND the AMM has accepted
    the fill.
    """
    @enforce_keys [:quote_id, :market_id, :txid, :amount_piconeros, :timestamp]
    defstruct [:quote_id, :market_id, :txid, :amount_piconeros, :timestamp]

    @type t :: %__MODULE__{
            quote_id: binary(),
            market_id: binary(),
            txid: String.t(),
            amount_piconeros: pos_integer(),
            timestamp: DateTime.t()
          }
  end

  defmodule QuoteUnderpaid do
    @moduledoc """
    A confirmed deposit has been matched to an open Quote but the
    amount received is less than the locked-in Quote price. No
    Position materialises; the Poller records an orphan for operator
    review, and this event drives the LiveView trade modal to a
    "amount received was less than expected — refund pending" state
    with the refund address the user provided at quote creation.

    Published locally on every node (no cluster-write; every node's
    Poller can independently observe the on-chain amount vs the
    Quote's expected amount) so LiveViews on any node see the
    transition regardless of which node the user is connected to.
    """
    @enforce_keys [
      :quote_id,
      :market_id,
      :txid,
      :amount_paid_piconeros,
      :amount_expected_piconeros,
      :refund_address,
      :timestamp
    ]
    defstruct [
      :quote_id,
      :market_id,
      :txid,
      :amount_paid_piconeros,
      :amount_expected_piconeros,
      :refund_address,
      :timestamp
    ]

    @type t :: %__MODULE__{
            quote_id: binary(),
            market_id: binary(),
            txid: String.t(),
            amount_paid_piconeros: pos_integer(),
            amount_expected_piconeros: pos_integer(),
            refund_address: String.t(),
            timestamp: DateTime.t()
          }
  end

  defmodule MarketDepositObserved do
    @moduledoc """
    The creator's initial-liquidity deposit transaction has been
    observed on-chain (mempool or unconfirmed block) but is not yet
    through the confirmation threshold. Same UX pattern as
    `QuoteDepositObserved` — the creator's liquidity modal greys
    the QR so they know the send landed and further sends aren't
    needed.

    Distinct from `MarketDepositConfirmed`, which only fires after
    the deposit crosses the full confirmation threshold and the
    Maker has flipped the market from `:awaiting_deposit` to
    `:pending`.
    """
    @enforce_keys [:market_id, :txid, :amount_piconeros, :timestamp]
    defstruct [:market_id, :txid, :amount_piconeros, :timestamp]

    @type t :: %__MODULE__{
            market_id: binary(),
            txid: String.t(),
            amount_piconeros: pos_integer(),
            timestamp: DateTime.t()
          }
  end

  defmodule PositionOpened do
    @moduledoc false
    @enforce_keys [
      :position_id,
      :market_id,
      :account_id,
      :side,
      :contracts,
      :amount_paid,
      :timestamp
    ]
    defstruct [
      :position_id,
      :market_id,
      :account_id,
      :side,
      :contracts,
      :amount_paid,
      :timestamp
    ]

    @type t :: %__MODULE__{
            position_id: binary(),
            market_id: binary(),
            account_id: binary(),
            side: :yes | :no,
            contracts: pos_integer(),
            amount_paid: pos_integer(),
            timestamp: DateTime.t()
          }
  end

  defmodule PositionPaidOut do
    @moduledoc false
    @enforce_keys [
      :position_id,
      :market_id,
      :account_id,
      :amount_piconeros,
      :destination,
      :payout_txid,
      :timestamp
    ]
    defstruct [
      :position_id,
      :market_id,
      :account_id,
      :amount_piconeros,
      :destination,
      :payout_txid,
      :timestamp
    ]

    @type t :: %__MODULE__{
            position_id: binary(),
            market_id: binary(),
            account_id: binary(),
            amount_piconeros: pos_integer(),
            destination: String.t(),
            payout_txid: String.t(),
            timestamp: DateTime.t()
          }
  end

  defmodule PositionCancelled do
    @moduledoc false
    @enforce_keys [:position_id, :market_id, :amount_refunded, :timestamp]
    defstruct [:position_id, :market_id, :amount_refunded, :timestamp]

    @type t :: %__MODULE__{
            position_id: binary(),
            market_id: binary(),
            amount_refunded: pos_integer(),
            timestamp: DateTime.t()
          }
  end

  defmodule ResolutionSubmitted do
    @moduledoc false
    @enforce_keys [:market_id, :outcome, :timestamp]
    defstruct [:market_id, :outcome, :timestamp]

    @type t :: %__MODULE__{
            market_id: binary(),
            outcome: :yes | :no | :void,
            timestamp: DateTime.t()
          }
  end

  defmodule ResolutionReversed do
    @moduledoc false
    @enforce_keys [:market_id, :previous_outcome, :new_outcome, :timestamp]
    defstruct [:market_id, :previous_outcome, :new_outcome, :timestamp]

    @type t :: %__MODULE__{
            market_id: binary(),
            previous_outcome: :yes | :no | :void,
            new_outcome: :yes | :no | :void,
            timestamp: DateTime.t()
          }
  end

  defmodule DisputeDepositObserved do
    @moduledoc """
    The deposit transaction matching an open Dispute stake has been
    observed on-chain (mempool or unconfirmed block) but is not yet
    through the confirmation threshold. UI consumers grey the QR /
    surface a "payment detected" indicator on the dispute modal so
    the user knows further sends aren't needed.

    Mirrors `QuoteDepositObserved` and `MarketDepositObserved` —
    distinct from `DisputeFlagged`, which only fires after the
    deposit has crossed the confirmation threshold AND the dispute
    has been committed to the Store.
    """
    @enforce_keys [:market_id, :account_id, :txid, :amount_piconeros, :timestamp]
    defstruct [:market_id, :account_id, :txid, :amount_piconeros, :timestamp]

    @type t :: %__MODULE__{
            market_id: binary(),
            account_id: binary(),
            txid: String.t(),
            amount_piconeros: pos_integer(),
            timestamp: DateTime.t()
          }
  end

  defmodule DisputeFlagged do
    @moduledoc """
    Emitted when a community member flags a dispute against a
    market's submitted resolution. Carries the new total flag count
    so subscribers can decide whether to surface the threshold.
    """
    @enforce_keys [:market_id, :account_id, :dispute_count, :timestamp]
    defstruct [:market_id, :account_id, :dispute_count, :timestamp]

    @type t :: %__MODULE__{
            market_id: binary(),
            account_id: binary(),
            dispute_count: pos_integer(),
            timestamp: DateTime.t()
          }
  end

  defmodule DisputeReReviewTriggered do
    @moduledoc """
    Emitted exactly once per acknowledgement cycle, when a fresh
    dispute pushes the unacknowledged count over the threshold.
    Signals to the guardian operator console that re-review is
    mandatory before settlement is allowed.
    """
    @enforce_keys [:market_id, :dispute_count, :threshold, :timestamp]
    defstruct [:market_id, :dispute_count, :threshold, :timestamp]

    @type t :: %__MODULE__{
            market_id: binary(),
            dispute_count: pos_integer(),
            threshold: pos_integer(),
            timestamp: DateTime.t()
          }
  end

  defmodule DisputesAcknowledged do
    @moduledoc """
    Emitted when the guardian federation acknowledges (re-reviews)
    the current dispute set. Settlement is allowed afterwards unless
    fresh disputes accumulate past the threshold again.
    """
    @enforce_keys [:market_id, :acknowledged_count, :timestamp]
    defstruct [:market_id, :acknowledged_count, :timestamp]

    @type t :: %__MODULE__{
            market_id: binary(),
            acknowledged_count: non_neg_integer(),
            timestamp: DateTime.t()
          }
  end

  defmodule DisputeResolved do
    @moduledoc """
    Emitted for every `:live` dispute when the guardian's review
    is finalised. Carries the terminal status, the disputer's
    refund amount in piconeros (full stake on `:resolved_against`,
    stake minus slash on `:resolved_for`), and the slashed amount
    (zero on `:resolved_against`).
    """
    @enforce_keys [
      :market_id,
      :account_id,
      :status,
      :refund_amount_piconeros,
      :slashed_amount_piconeros,
      :timestamp
    ]
    defstruct [
      :market_id,
      :account_id,
      :status,
      :refund_amount_piconeros,
      :slashed_amount_piconeros,
      :timestamp
    ]

    @type t :: %__MODULE__{
            market_id: binary(),
            account_id: binary(),
            status: :resolved_for | :resolved_against,
            refund_amount_piconeros: non_neg_integer(),
            slashed_amount_piconeros: non_neg_integer(),
            timestamp: DateTime.t()
          }
  end

  defmodule MarketSettled do
    @moduledoc false
    @enforce_keys [:market_id, :outcome, :resolved_at, :timestamp]
    defstruct [:market_id, :outcome, :resolved_at, :timestamp]

    @type t :: %__MODULE__{
            market_id: binary(),
            outcome: :yes | :no | :void,
            resolved_at: DateTime.t(),
            timestamp: DateTime.t()
          }
  end

  defmodule MarketVoided do
    @moduledoc """
    Emitted when a market is voided. `reason` distinguishes the
    initiator: `:operator` for explicit operator-initiated voids
    (Markets.Console / Facade), `:creator_no_show` when the
    Scheduler auto-voided an `:expired` market because the creator
    never submitted a resolution within the deadline, and
    `:guardian_undecidable` when the Scheduler auto-voided a
    `:resolving` market because guardians never acknowledged
    disputes within the deadline.
    """
    @enforce_keys [:market_id, :resolved_at, :reason, :timestamp]
    defstruct [:market_id, :resolved_at, :reason, :timestamp]

    @type reason :: :operator | :creator_no_show | :guardian_undecidable

    @type t :: %__MODULE__{
            market_id: binary(),
            resolved_at: DateTime.t(),
            reason: reason(),
            timestamp: DateTime.t()
          }
  end

  defmodule DepositBurned do
    @moduledoc false
    @enforce_keys [:market_id, :amount, :timestamp]
    defstruct [:market_id, :amount, :timestamp]

    @type t :: %__MODULE__{
            market_id: binary(),
            amount: pos_integer(),
            timestamp: DateTime.t()
          }
  end

  defmodule OrphanDepositObserved do
    @moduledoc """
    The Monero deposit poller observed a confirmed transfer to a
    per-trade subaddress whose owning record (Quote / Dispute /
    Market deposit) no longer matches — quote already consumed,
    dispute already resolved, or no record at all.

    The deposit is durably persisted in `PerpWalk.Monero.Orphans`
    for operator review. The user's funds are NOT lost — they sit
    in federation custody pending manual refund.
    """
    @enforce_keys [:txid, :amount_piconeros, :kind, :key, :timestamp]
    defstruct [:txid, :amount_piconeros, :kind, :key, :timestamp]

    @type kind :: :unknown_quote | :unknown_dispute | :unknown_market_deposit

    @type t :: %__MODULE__{
            txid: String.t(),
            amount_piconeros: pos_integer(),
            kind: kind(),
            key: term(),
            timestamp: DateTime.t()
          }
  end

  defmodule CommentReceived do
    @moduledoc """
    A signed Nostr comment event (kind 1) referencing a PERP WALK
    market has been ingested by `Markets.Comments.Inbox`.

    `event_id` is the Nostr event id (sha256 of canonical NIP-01
    serialization, hex). `author_pubkey` is the commenter's x-only
    Schnorr pubkey (hex, derived per-venue from their keyphrase via
    `Identity.Account.derive_nostr_keypair/1`). `market_id`
    references the market the comment is about, extracted from the
    event's `a` tag (NIP-33 addressable event reference).

    Subscribers (LiveView market detail surfaces) react to this
    event by appending to their rendered comment feed without
    re-fetching the inbox.
    """
    @enforce_keys [:event_id, :market_id, :author_pubkey, :content, :created_at, :timestamp]
    defstruct [:event_id, :market_id, :author_pubkey, :content, :created_at, :timestamp]

    @type t :: %__MODULE__{
            event_id: String.t(),
            market_id: binary(),
            author_pubkey: String.t(),
            content: String.t(),
            created_at: integer(),
            timestamp: DateTime.t()
          }
  end
end
