defmodule PerpWalk.Identity.Account do
  @moduledoc """
  Pure derivation of account identity from a Locksmith keyphrase.

  A 6-word keyphrase is the credential. The user's possession of
  the keyphrase IS their account — there is no email, no password
  reset, no recovery. From the keyphrase we deterministically
  derive three things:

  - `account_id` — `Locksmith.Key.hash(normalized_keyphrase)`
    (Argon2id, raw 32-byte tag, hex-encoded). The opaque
    identifier used as a foreign key everywhere markets, votes,
    positions, and quotes reference an account. Argon2id is
    chosen over a bare hash so a keyphrase wordlist attacker
    pays the per-derivation memory + time cost even if they
    obtain the account_id surface.
  - `handle` — a friendly `adjective-animal-NNNN` display string
    (e.g. `"swift-otter-7421"`) deterministically derived from
    `account_id`. Same keyphrase always produces the same handle,
    so there is nothing to store and nothing to recover.
  - `nostr_keypair` — a per-venue secp256k1 keypair derived from
    the keyphrase via HKDF with a fixed PERP WALK domain separator.
    Used to sign Nostr events (market comments, position
    attestations) without ever touching the user's real Nostr
    identity elsewhere. See `derive_nostr_keypair/1`.

  No state, no IO. Same input → same output, on every node.

  ## Why deterministic handles

  A persisted handle would need to replicate across the federation
  and survive WAL nuke / restore. By deriving it on the fly from
  `account_id` we sidestep all of that — anyone with the keyphrase
  has their handle back instantly. The handle space is large
  enough (`length(@adjectives) × length(@animals) × 10000`,
  on the order of 10⁷) that collisions among the realistic user
  count are vanishingly rare; even when they happen, the keyphrase
  is the real identity, so a shared display string is cosmetic,
  not a security property.

  ## Why a per-venue Nostr keypair

  Letting users log in with their own existing `npub` would link
  their PERP WALK positions to a persistent public reputation graph
  (followers, post history, relationships). That defeats the entire
  "anonymous signal surfacing" thesis the moment any user picks the
  path of least resistance. Instead we derive a fresh secp256k1
  keypair scoped to this venue only — same keyphrase always produces
  the same keypair on PERP WALK, with zero cryptographic relationship
  to the user's main Nostr identity.
  """

  @adjectives ~w(
    amber arctic ashen autumn azure bitter blazing bold brave bright
    bronze calm clever cobalt copper crimson curious daring dawn deep
    distant dusky eager ember fearless fierce fleet forest frosty gentle
    glacial gleaming golden grave hardy hazy hidden hollow honest humble
    indigo iron ivory jade jovial keen lively lonely lucid lunar
    mellow misty noble obsidian onyx peaceful prairie quiet radiant rapid
    raven restless rusty sable savage scarlet shadow silent silver slate
    smoky snowy solemn somber sovereign steady stoic stormy subtle sudden
    swift tender thunder twilight valiant vermilion vivid weathered whisper wild
  )

  @animals ~w(
    badger bear beaver bison boar buffalo cobra cougar coyote crane
    crow deer dingo dolphin eagle elk falcon ferret finch fox
    gazelle gecko goose hawk heron hornet hyena ibex jackal jaguar
    kestrel kingfisher kite koala leopard lion lynx mantis marlin marten
    mongoose moose newt orca osprey otter owl panther pelican peregrine
    polecat puma raven sable salmon serpent shrew skua sloth sparrow
    stag stoat sturgeon swan tiger trout turaco vixen vulture walrus
    whale wolf wolverine wombat wren zebra
  )

  @adjective_count length(@adjectives)
  @animal_count length(@animals)

  @derivation_secret "perpwalk.handle.v1"

  # Domain separator for handles derived from Nostr pubkeys (as
  # opposed to account_ids). The mapping is the same shape
  # (`adjective-animal-NNNN`) but the namespace is intentionally
  # disjoint from `@derivation_secret` so the same user's
  # account-handle and nostr-handle won't collide and can't be
  # cross-correlated from the handle alone. Both still derive
  # deterministically from the keyphrase.
  @nostr_handle_derivation_secret "perpwalk.nostr-handle.v1"

  # HKDF salt for the per-venue Nostr keypair derivation. Distinct
  # from `@derivation_secret` so the handle and Nostr key are in
  # different domain-separator namespaces — leakage of one tells
  # nothing about the other. The `v1` suffix leaves room to rotate
  # the derivation if the curve / hash combination ever changes.
  @nostr_derivation_salt "perp-walk-nostr-v1"
  @nostr_seckey_bytes 32

  @type t :: %{
          account_id: String.t(),
          handle: String.t(),
          normalized_keyphrase: String.t()
        }

  @doc """
  Derives the account identity from a keyphrase.

  The keyphrase is normalized via Locksmith (trim + uppercase +
  hyphen-separator) before hashing, so cosmetic typing differences
  (lowercase, extra whitespace) all map to the same account.

  Returns `{:error, :empty_keyphrase}` for blank input.
  """
  @spec derive_from_keyphrase(String.t()) :: {:ok, t()} | {:error, :empty_keyphrase}
  def derive_from_keyphrase(keyphrase) when is_binary(keyphrase) do
    normalized = Locksmith.Key.normalize(keyphrase)

    if normalized == "" do
      {:error, :empty_keyphrase}
    else
      account_id = Locksmith.Key.hash(normalized)

      {:ok,
       %{
         account_id: account_id,
         handle: handle_for(account_id),
         normalized_keyphrase: normalized
       }}
    end
  end

  @doc """
  Derives the display handle for a given `account_id`.

  Format: `adjective-animal-NNNN` where `NNNN` is a zero-padded
  4-digit number. Uses HMAC-SHA256 with a fixed domain-separator
  string so the mapping is stable across deploys but distinct from
  any other use of the account_id.

  Each segment draws from a 16-bit slice of the HMAC so the modulo
  bias is at most ~1/(65536/N) — negligible compared to the 8-bit
  slices a prior version used.
  """
  @spec handle_for(String.t()) :: String.t()
  def handle_for(account_id) when is_binary(account_id) do
    <<adj::16, animal::16, num::16, _rest::binary>> =
      :crypto.mac(:hmac, :sha256, @derivation_secret, account_id)

    adjective = Enum.at(@adjectives, rem(adj, @adjective_count))
    animal = Enum.at(@animals, rem(animal, @animal_count))
    number = rem(num, 10_000) |> Integer.to_string() |> String.pad_leading(4, "0")

    "#{adjective}-#{animal}-#{number}"
  end

  @doc """
  Derives the friendly handle for a Nostr-pubkey-identified actor.

  Mirrors `handle_for/1` (same `adjective-animal-NNNN` shape) but
  uses a different domain separator so the handle space for Nostr
  identities is distinct from the account-id handle space. The
  same user's account-handle and nostr-handle won't collide and
  can't be cross-correlated from the handle alone — only the
  keyphrase deterministically produces both.

  Accepts the x-only Nostr pubkey as either a 32-byte binary or
  a 64-char hex string. Raises on any other input.
  """
  @spec nostr_handle_for(binary()) :: String.t()
  def nostr_handle_for(pubkey)
      when is_binary(pubkey) and byte_size(pubkey) in [32, 64] do
    <<adj::16, animal::16, num::16, _rest::binary>> =
      :crypto.mac(:hmac, :sha256, @nostr_handle_derivation_secret, pubkey)

    adjective = Enum.at(@adjectives, rem(adj, @adjective_count))
    animal = Enum.at(@animals, rem(animal, @animal_count))
    number = rem(num, 10_000) |> Integer.to_string() |> String.pad_leading(4, "0")

    "#{adjective}-#{animal}-#{number}"
  end

  @doc """
  Derives the per-venue Nostr keypair from a keyphrase.

  Returns `{:ok, {seckey, xonly_pubkey}}` where both are 32-byte
  binaries. The secret key is HKDF-SHA256 over the Argon2id-stretched
  account id (`Locksmith.Key.hash/1` of the normalized keyphrase)
  with a fixed PERP WALK domain separator (`perp-walk-nostr-v1`) —
  never over the raw phrase, so an `author_pubkey` on a public relay
  is not an offline dictionary oracle running at HMAC speed.
  the public key is the BIP-340 x-only Schnorr pubkey (33-byte
  compressed form from `Cashew.pubkey_from_privkey/1` with the
  leading parity byte stripped).

  Same keyphrase always produces the same keypair on this venue,
  with no cryptographic relationship to any external Nostr identity
  the user may hold. Used for signing market comments and position
  attestations within PERP WALK.

  Returns `{:error, :empty_keyphrase}` for blank input or
  `{:error, term()}` if `Cashew.pubkey_from_privkey/1` rejects the
  derived seckey (vanishingly unlikely for HKDF output on
  secp256k1).
  """
  @spec derive_nostr_keypair(String.t()) ::
          {:ok, {binary(), binary()}}
          | {:error, :empty_keyphrase | atom()}
  def derive_nostr_keypair(keyphrase) when is_binary(keyphrase) do
    normalized = Locksmith.Key.normalize(keyphrase)

    if normalized == "" do
      {:error, :empty_keyphrase}
    else
      seckey = hkdf_nostr_seckey(Locksmith.Key.hash(normalized))

      case Cashew.pubkey_from_privkey(seckey) do
        {:ok, <<_parity_byte, xonly_pubkey::binary-size(32)>>} ->
          {:ok, {seckey, xonly_pubkey}}

        {:error, _} = err ->
          err
      end
    end
  end

  # HKDF-SHA256 single-block extract+expand for a 32-byte output.
  # IKM = the Argon2id-stretched account id (never the raw phrase);
  # salt = the fixed Nostr-domain separator; info empty. RFC 5869
  # single-iteration since 32 bytes ≤ HashLen.
  defp hkdf_nostr_seckey(stretched_account_id) do
    prk = :crypto.mac(:hmac, :sha256, @nostr_derivation_salt, stretched_account_id)
    t1 = :crypto.mac(:hmac, :sha256, prk, <<>> <> <<1>>)
    binary_part(t1, 0, @nostr_seckey_bytes)
  end
end
