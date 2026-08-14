defmodule PerpWalk.Nostr.Venue.Identity do
  @moduledoc """
  Owns the venue's Nostr signing identity. Single source of truth.

  Loads (or, on first boot, generates) a BIP-340 Schnorr secp256k1
  signing key from an encrypted key file via `Storage.Facade`, holds
  it in memory for the lifetime of the node, and exposes it through
  `pubkey/0` and `sign_hash/1`. Every venue-published Nostr event
  (reserve proofs, market lifecycle events, position-holder
  attestations) signs through this module — the publishers do not
  hold or load the key themselves.

  ## Why a separate module

  Reserves and Markets are both *consumers* of the venue identity,
  not its owner. Earlier the key lived inside
  `Reserves.Publishers.Nostr` and `Reserves.Facade.nostr_pubkey/0`
  pretended Reserves owned it, while `Markets.Publishers.Nostr`
  separately re-loaded the same file. That created a cross-domain
  boundary inversion: lower-level Nostr substrate (the relay
  subscriber, the comment renderer) had to import a Reserves module
  to find out the venue's own pubkey. Centralising here removes the
  inversion — `Venue.Identity` is Nostr-namespace substrate alongside
  `Nostr.Relay.Client` and `Nostr.Event`.

  ## Boot semantics

  Started by `PerpWalk.Application` directly after `Storage.Supervisor`
  so the key is loaded before Markets, Monero, Federation, or
  Reserves come up. Three outcomes inside `init/1`:

    * File missing (`:not_found`) — legitimate first boot; mint and
      persist a fresh key. The same code path Reserves used.
    * File present and decrypts cleanly — adopt the existing
      identity. The encrypted-key file format is unchanged across
      this refactor; nodes upgrading in place keep the same npub.
    * Anything else (decrypt failure, malformed binary, IO error) —
      refuse to start. Silently regenerating would orphan every
      historical published event from its verifier and an attacker
      with brief filesystem write access could force the rotation
      by corrupting one byte.

  ## Secret hygiene

  `format_status/2` redacts the in-memory seckey from crash dumps
  and `:sys.get_state/1`. Most callers use `sign_hash/1` — they send
  a 32-byte hash and get back a hex signature, never the seckey.
  Publishers that assemble NIP-01 envelopes end-to-end fetch the
  full keypair via `keypair/0` and sign locally — that API hands
  over the private bytes by design, and its contract requires
  callers to never log, persist, or transmit them.
  """

  use GenServer

  require Logger

  alias PerpWalk.Crypto.Schnorr
  alias PerpWalk.Storage.Facade, as: StorageFacade

  @key_label "nostr-signing-key"

  # Per-record AAD label, retained verbatim from the previous
  # Reserves.Publishers.Nostr location so an in-place upgrade reads
  # the existing key file without re-keying. Binds the ciphertext to
  # its purpose so a filesystem attacker can't swap this for another
  # encrypted record sharing the default AAD.
  @key_file_aad "reserves-nostr-key-v1"

  @type signing_key :: %{
          private: binary(),
          public: binary(),
          xonly: binary(),
          public_hex: String.t()
        }

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns the venue's x-only Schnorr pubkey as a lowercase hex
  string. Always `{:ok, hex}` once boot completes — the genserver
  refuses to start if the key isn't loadable, so a successful call
  here means the identity is live.
  """
  @spec pubkey() :: {:ok, String.t()} | {:error, :not_available}
  def pubkey, do: GenServer.call(__MODULE__, :pubkey)

  @doc """
  Signs a 32-byte message hash with the venue's seckey and returns
  the lowercase hex signature (64 bytes / 128 hex chars). The hash
  is typically SHA-256 of canonical NIP-01 event bytes.

  Returns `{:ok, sig_hex}` on success or `{:error, reason}` on a
  Schnorr signing failure (vanishingly rare — the key was already
  validated at boot).
  """
  @spec sign_hash(binary()) :: {:ok, String.t()} | {:error, atom()}
  def sign_hash(hash) when is_binary(hash) and byte_size(hash) == 32 do
    GenServer.call(__MODULE__, {:sign_hash, hash})
  end

  @doc """
  Returns the full signing-key struct (private, x-only pubkey,
  compressed pubkey, public_hex). Used by publishers that build
  events end-to-end — they assemble the NIP-01 envelope, ask for
  the keypair once at init, and sign locally without round-tripping
  through this GenServer per event.

  Callers MUST treat the returned `:private` bytes as a secret —
  never log, never persist, never transmit.
  """
  @spec keypair() :: {:ok, signing_key()}
  def keypair, do: GenServer.call(__MODULE__, :keypair)

  # --- GenServer ---

  @impl true
  def init(_opts) do
    key = load_or_generate_key()
    Logger.info("Identity: ready, pubkey=#{key.public_hex}")
    {:ok, %{signing_key: key}}
  end

  @impl true
  def handle_call(:pubkey, _from, %{signing_key: %{public_hex: hex}} = state) do
    {:reply, {:ok, hex}, state}
  end

  def handle_call(:keypair, _from, %{signing_key: key} = state) do
    {:reply, {:ok, key}, state}
  end

  def handle_call({:sign_hash, hash}, _from, %{signing_key: %{private: priv}} = state) do
    result =
      case Schnorr.sign(priv, hash) do
        {:ok, {signature, _xonly}} -> {:ok, Base.encode16(signature, case: :lower)}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, state}
  end

  # Redact signing key from crash dumps and `:sys.get_state/1`.
  @impl true
  def format_status(_reason, [pdict, state]) do
    redacted = %{state | signing_key: :redacted}
    [{:data, [{"State", redacted}]} | pdict]
  end

  # --- Key Management ---

  defp load_or_generate_key do
    case load_key_file(@key_label) do
      {:ok, key_data} ->
        case deserialize_key(key_data) do
          {:ok, key} ->
            key

          {:error, reason} ->
            raise "Identity: refusing to start — stored signing key is malformed (#{inspect(reason)}). " <>
                    "Investigate before clearing the key file; rotating identity here breaks " <>
                    "verification of every historical Nostr event the venue published."
        end

      {:error, :not_found} ->
        generate_and_store_key()

      {:error, reason} ->
        raise "Identity: refusing to start — could not load signing key (#{inspect(reason)}). " <>
                "If the key file is present but unreadable, the operator must investigate " <>
                "rather than have the node silently mint a new identity."
    end
  end

  defp generate_and_store_key do
    key = generate_key()

    case store_key_file(@key_label, serialize_key(key)) do
      :ok ->
        Logger.info("Identity: generated and stored signing key, pubkey=#{key.public_hex}")
        key

      {:error, reason} ->
        raise "Identity: refusing to start — could not persist freshly generated signing key " <>
                "(#{inspect(reason)})"
    end
  end

  defp generate_key do
    {:ok, {privkey, pubkey}} = Schnorr.generate_keypair()
    <<_prefix::8, xonly::binary-32>> = pubkey

    %{
      private: privkey,
      public: pubkey,
      xonly: xonly,
      public_hex: Base.encode16(xonly, case: :lower)
    }
  end

  defp serialize_key(key), do: key.private <> key.xonly

  defp deserialize_key(<<privkey::binary-32, xonly::binary-32>>) do
    case Schnorr.pubkey_from_privkey(privkey) do
      {:ok, pubkey} ->
        {:ok,
         %{
           private: privkey,
           public: pubkey,
           xonly: xonly,
           public_hex: Base.encode16(xonly, case: :lower)
         }}

      {:error, reason} ->
        {:error, {:pubkey_derivation_failed, reason}}
    end
  end

  defp deserialize_key(_other), do: {:error, :malformed_key_file}

  defp load_key_file(label) do
    path = StorageFacade.key_file(label)

    with {:ok, encrypted} <- File.read(path),
         {:ok, plaintext} <- StorageFacade.decrypt(encrypted, @key_file_aad) do
      {:ok, plaintext}
    else
      {:error, :enoent} -> {:error, :not_found}
      error -> error
    end
  end

  defp store_key_file(label, data) do
    path = StorageFacade.key_file(label)
    File.mkdir_p!(Path.dirname(path))

    with {:ok, encrypted} <- StorageFacade.encrypt(data, @key_file_aad),
         :ok <- File.write(path, encrypted) do
      case File.chmod(path, 0o600) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Identity: key file chmod failed, path=#{path}, reason=#{inspect(reason)}")
          :ok
      end
    end
  end
end
