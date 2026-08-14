defmodule PerpWalk.Nostr.Facade do
  @moduledoc """
  Public surface of the Nostr domain.

  ## Nostr is a distribution transport, not a source of truth

  Every venue-owned piece of state — markets, positions, comments,
  reserves — lives in the local WAL. Nostr is how we publish that
  state outward (kind 30819 market events, kind 30078 reserve
  proofs) and how anonymous comments authored elsewhere flow
  inward. Relays are unreliable, forgetful, and outside the
  operator's control by design; nothing the venue relies on to
  function should assume a relay retained anything.

  Inbound events are ingested to the WAL first, then to ETS;
  outbound events are broadcast to configured relays but the
  event exists as WAL truth whether any relay accepts it or not.

  ## Boundaries

  Cross-domain callers (web layer, controllers, other domains) reach
  the Nostr substrate through this facade. Internal Nostr modules
  (`Relay.Client`, `Subscription.Supervisor`, `Venue.Identity`,
  `Event`, `Frame`) are not part of the public surface and must not
  be aliased from outside `PerpWalk.Nostr`.
  """

  alias PerpWalk.Nostr.Relay
  alias PerpWalk.Nostr.Venue

  @doc """
  The venue's BIP-340 Schnorr public key as a 32-byte x-only
  binary. Returned as `{:ok, pubkey}` while the key is loaded;
  `{:error, :not_available}` if the venue identity hasn't booted
  yet (start-up race).
  """
  @spec venue_pubkey() :: {:ok, binary()} | {:error, :not_available}
  defdelegate venue_pubkey(), to: Venue.Identity, as: :pubkey

  @doc """
  Returns the venue's signing keypair as an `{:ok, %{private, xonly,
  public, public_hex}}` map. Callers use this to sign events they
  built themselves (attestation publishers, market announcements,
  alert publishers). The keypair is loaded from the venue identity
  GenServer and re-derived on demand from the same seed as
  `venue_pubkey/0`.

  The `:private` field is secret material — never log, never
  persist, never transmit.
  """
  @spec venue_signing_keypair() ::
          {:ok,
           %{
             private: binary(),
             xonly: binary(),
             public: binary(),
             public_hex: String.t()
           }}
  defdelegate venue_signing_keypair(), to: Venue.Identity, as: :keypair

  @doc """
  Publishes a signed Nostr event map to a single relay URL. Returns
  `{:ok, event_id}` on relay acceptance, `{:error, reason}` on any
  failure. Cross-domain publishers (Markets, Reserves, Telemetry)
  reach the relay client through this facade.
  """
  @spec publish_event(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  defdelegate publish_event(relay_url, event), to: Relay.Client, as: :publish
end
