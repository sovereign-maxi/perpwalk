defmodule PerpWalk.Events.Federation do
  @moduledoc """
  Federation context events: Payout lifecycle, signing
  rounds, federation health.

  Events span the request lifecycle from creation through rules
  evaluation, signing, on-chain submission, and final payout.
  Each one carries enough context that a subscriber (admin
  dashboard, Nostr alert publisher, audit log) can render or
  react without having to look up auxiliary state.
  """

  defmodule PayoutRequested do
    @moduledoc false

    @enforce_keys [
      :request_id,
      :market_id,
      :account_id,
      :kind,
      :amount_piconeros,
      :destination,
      :timestamp
    ]
    defstruct [
      :request_id,
      :position_id,
      :market_id,
      :account_id,
      :kind,
      :amount_piconeros,
      :destination,
      :timestamp
    ]

    @type t :: %__MODULE__{
            request_id: binary(),
            position_id: binary() | nil,
            market_id: binary(),
            account_id: binary(),
            kind:
              :winner_payout
              | :refund
              | :dispute_refund_full
              | :dispute_refund_partial
              | :federation_income
              | :creator_lp_return,
            amount_piconeros: pos_integer(),
            destination: String.t(),
            timestamp: DateTime.t()
          }
  end

  defmodule RuleCheckPassed do
    @moduledoc false
    @enforce_keys [:request_id, :timestamp]
    defstruct [:request_id, :timestamp]
    @type t :: %__MODULE__{request_id: binary(), timestamp: DateTime.t()}
  end

  defmodule RuleCheckFailed do
    @moduledoc false
    @enforce_keys [:request_id, :reason, :timestamp]
    defstruct [:request_id, :reason, :timestamp]

    @type t :: %__MODULE__{
            request_id: binary(),
            reason: String.t(),
            timestamp: DateTime.t()
          }
  end

  defmodule PayoutSubmitted do
    @moduledoc false
    @enforce_keys [:request_id, :payout_txid, :amount_piconeros, :timestamp]
    defstruct [:request_id, :position_id, :payout_txid, :amount_piconeros, :timestamp]

    @type t :: %__MODULE__{
            request_id: binary(),
            position_id: binary() | nil,
            payout_txid: String.t(),
            amount_piconeros: pos_integer(),
            timestamp: DateTime.t()
          }
  end

  defmodule PayoutFailed do
    @moduledoc """
    Emitted when a Payout cannot proceed because the signing backend
    rejected the request OR rule revalidation failed at sign time.
    Carries `:reason` for operator triage. No on-chain effect — the
    tx was not submitted. Distinct from `PayoutFinalizeFailed`,
    which fires only after a successful broadcast.
    """
    @enforce_keys [:request_id, :reason, :timestamp]
    defstruct [:request_id, :reason, :timestamp]

    @type t :: %__MODULE__{
            request_id: binary(),
            reason: String.t(),
            timestamp: DateTime.t()
          }
  end

  defmodule PayoutSettlementUnknown do
    @moduledoc """
    Emitted when a multisig submit RPC returned an ambiguous outcome
    (timeout, transport error, 5xx, null-result) so the auto-signer
    cannot determine whether the tx was broadcast. The Payout is
    pinned in `:settlement_unknown`; operator must reconcile against
    wallet transfer history and drive resolution via console.

    Distinct from `PayoutFailed` (no broadcast, safe to retry) and
    `PayoutFinalizeFailed` (broadcast confirmed, bookkeeping lagging).
    This event means: **funds may or may not have moved — do not
    auto-retry**.
    """
    @enforce_keys [:request_id, :reason, :timestamp]
    defstruct [:request_id, :reason, :timestamp]

    @type t :: %__MODULE__{
            request_id: binary(),
            reason: String.t(),
            timestamp: DateTime.t()
          }
  end

  defmodule PayoutFinalizeFailed do
    @moduledoc """
    Emitted when the Monero tx broadcast succeeded — `payout_txid` is
    on-chain — but the Markets-side bookkeeping
    (`mark_position_paid_out` / `mark_dispute_refunded`) returned
    `{:error, _}`. The Signer's `:submitted` retry path will keep
    attempting the finalisation step; this event is the alert for
    operators that bookkeeping is lagging chain state.

    Distinct from `PayoutFailed`: a `PayoutFinalizeFailed` means
    funds have already moved, the operator should expect
    eventual finalisation, not investigate a "missing payout".
    """
    @enforce_keys [:request_id, :payout_txid, :reason, :timestamp]
    defstruct [:request_id, :payout_txid, :reason, :timestamp]

    @type t :: %__MODULE__{
            request_id: binary(),
            payout_txid: String.t(),
            reason: String.t(),
            timestamp: DateTime.t()
          }
  end

  defmodule OperatorOverride do
    @moduledoc """
    Emitted when the operator force-approves a Payout that the rules
    engine had previously rejected. Audit trail for every
    `Federation.Console.force_sign/1` call.
    """
    @enforce_keys [:request_id, :previous_reason, :timestamp]
    defstruct [:request_id, :previous_reason, :timestamp]

    @type t :: %__MODULE__{
            request_id: binary(),
            previous_reason: String.t() | nil,
            timestamp: DateTime.t()
          }
  end

  defmodule SigningHalted do
    @moduledoc """
    Emitted when the operator halts auto-signing on this node via
    `Federation.Console.halt/0`. Local — other peers unaffected.
    """
    @enforce_keys [:timestamp]
    defstruct [:timestamp]

    @type t :: %__MODULE__{timestamp: DateTime.t()}
  end

  defmodule SigningResumed do
    @moduledoc """
    Emitted when the operator resumes auto-signing on this node via
    `Federation.Console.resume/0`.
    """
    @enforce_keys [:timestamp]
    defstruct [:timestamp]

    @type t :: %__MODULE__{timestamp: DateTime.t()}
  end

  defmodule BootstrapAddressMismatch do
    @moduledoc """
    Emitted when `Federation.Bootstrap` detects the guardians
    converged to different multisig addresses. Ceremony halts;
    operator must investigate before any payouts are accepted.
    """
    @enforce_keys [:addresses, :timestamp]
    defstruct [:addresses, :timestamp]

    @type t :: %__MODULE__{
            addresses: [String.t()],
            timestamp: DateTime.t()
          }
  end

  defmodule MultisigAddressMismatch do
    @moduledoc """
    Emitted by `Federation.MultisigGuard` when the open wallet's
    address does not match the configured `:multisig_address`.
    Wallet-rpc has opened the wrong wallet — every subsequent
    balance read and signing operation targets the wrong key share.
    """
    @enforce_keys [:expected, :actual, :timestamp]
    defstruct [:expected, :actual, :timestamp]

    @type t :: %__MODULE__{
            expected: String.t(),
            actual: String.t(),
            timestamp: DateTime.t()
          }
  end

  defmodule PeerLost do
    @moduledoc """
    Emitted by `Federation.HealthBridge` when a federation peer stops
    sending heartbeats and is marked offline. Quorum may still be
    intact (single-peer-down with N-1 ≥ threshold) — see `QuorumLost`
    for the federation-wide-degradation signal.
    """
    @enforce_keys [:peer_id, :timestamp]
    defstruct [:peer_id, :timestamp]

    @type t :: %__MODULE__{peer_id: atom() | String.t(), timestamp: DateTime.t()}
  end

  defmodule PeerJoined do
    @moduledoc """
    Emitted by `Federation.HealthBridge` when a previously-offline
    federation peer resumes sending heartbeats and is marked online.
    """
    @enforce_keys [:peer_id, :timestamp]
    defstruct [:peer_id, :timestamp]

    @type t :: %__MODULE__{peer_id: atom() | String.t(), timestamp: DateTime.t()}
  end

  defmodule QuorumLost do
    @moduledoc """
    Emitted when federation online-peer count drops below the signing
    threshold. The platform enters HALTED state: new-liability writes
    (quote generation, market creation, position purchase) are
    refused at the application layer; signing-required operations
    halt automatically because multisig signing requires the
    threshold. Existing read paths continue to work.
    """
    @enforce_keys [:online, :threshold, :timestamp]
    defstruct [:online, :threshold, :timestamp]

    @type t :: %__MODULE__{
            online: non_neg_integer(),
            threshold: pos_integer(),
            timestamp: DateTime.t()
          }
  end

  defmodule QuorumRestored do
    @moduledoc """
    Emitted when federation online-peer count returns to threshold
    after a `QuorumLost`. HALTED state lifts; new-liability writes
    resume.
    """
    @enforce_keys [:online, :threshold, :timestamp]
    defstruct [:online, :threshold, :timestamp]

    @type t :: %__MODULE__{
            online: non_neg_integer(),
            threshold: pos_integer(),
            timestamp: DateTime.t()
          }
  end
end
