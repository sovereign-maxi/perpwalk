defmodule PerpWalk.Federation.Keys do
  @moduledoc """
  Per-participant Ed25519 signing key registry.

  Each federation participant has an Ed25519 signing keypair used to
  authenticate the entries it publishes. Public keys are **pinned**
  in application config: a rogue node cannot claim participant
  identity without holding the matching private key AND being pinned
  in every peer's registry.

  ## Two surfaces

  1. **Local private key** — this node's Ed25519 signing key, derived
     by Cartel at boot from `PERPWALK_NODE_PASSPHRASE` via PBKDF2-SHA256
     (600K iterations). Sourced live from `Cartel.config().signing_key`
     so it never lands on disk in this module — the passphrase
     derivation is Cartel's already-vaulted mechanism, reused.
  2. **Pinned public key registry** — a map of
     `participant_id => 32-byte public key` assembled from Cartel's
     already-loaded peer keys plus this node's own pubkey. Federated
     boots see a fully-populated registry with zero extra config;
     dev/test single-node boots (Cartel absent) see an empty map,
     which downstream consumers treat as "unpinned mode, lenient".

  ## Boot verification

  `verify_local_key_pinning/0` is called during boot. If this
  participant is pinned in the registry AND the local key on disk
  derives a public key that does not match the pinned value, the
  venue halts via `Telemetry.Health.System.set_source_halt/2`. A
  pinned-but-mismatched key means either the registry is stale or
  the local key store was compromised — both fail-closed.

  ## Runtime surface

  - `sign/1` — produce a 64-byte Ed25519 signature over a message
    using the local private key.
  - `verify/3` — verify a signature against a claimed origin's
    pinned public key. Returns `false` for unknown participants.

  ## Bootstrap

  `generate_keypair/0` + `store_local_key!/1` are provided for the
  bootstrap ceremony. The operator generates a keypair on each node,
  records the public key, and pins the full set of public keys in
  config before mainnet.
  """

  alias PerpWalk.Role
  alias PerpWalk.Telemetry.Health.System, as: HealthSystem

  require Logger

  @pubkey_size 32
  @privkey_size 32
  @signature_size 64

  defmodule KeyMismatchError do
    @moduledoc """
    Raised when the local signing key on disk does not derive the
    public key pinned in the participant registry for this node.
    """
    defexception [:message]

    @impl true
    def exception(reason) do
      %__MODULE__{message: "federation key pinning mismatch: #{reason}"}
    end
  end

  # --- Local key ---

  @doc """
  Returns this node's Ed25519 private key from Cartel's already-loaded
  signing keypair. Derived at boot from `PERPWALK_NODE_PASSPHRASE`;
  never touches disk in this module.

  `{:error, :not_found}` if Cartel isn't running (dev/test single-node
  boots where no passphrase was configured).
  """
  @spec local_private_key() :: {:ok, binary()} | {:error, :not_found}
  def local_private_key do
    case safe_cartel_config() do
      {:ok, cfg} ->
        priv = Cartel.Config.private_key(cfg)

        if is_binary(priv) and byte_size(priv) == @privkey_size do
          {:ok, priv}
        else
          {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns this node's Ed25519 public key from Cartel. Same source as
  `local_private_key/0` — the derived pair is atomic. `{:error, :not_found}`
  if Cartel isn't running.
  """
  @spec local_public_key() :: {:ok, binary()} | {:error, :not_found}
  def local_public_key do
    case safe_cartel_config() do
      {:ok, cfg} ->
        pub = Cartel.Config.public_key(cfg)

        if is_binary(pub) and byte_size(pub) == @pubkey_size do
          {:ok, pub}
        else
          {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  # --- Pinned registry ---

  @doc """
  Full pinned public key registry — a map of `participant_id` to
  32-byte Ed25519 public key. Assembled at call time from Cartel's
  loaded config: this node's own pubkey (mapped to `Role.participant_id/0`)
  plus every peer pubkey (mapped from Cartel's integer node ids to
  atom participant ids using the local env prefix).

  Returns `%{}` on dev/test boots where Cartel isn't running — treated
  as "unpinned mode" by downstream consumers (Sealer is lenient,
  Replicator would halt but has no peers to replicate against).

  A test/override path is honoured: `:perpwalk, :participant_pubkeys`
  in app env takes precedence when explicitly set. Production leaves
  it unset and lets Cartel be the sole source of truth.
  """
  @spec pinned_pubkeys() :: %{Role.participant_id() => binary()}
  def pinned_pubkeys do
    case Application.fetch_env(:perpwalk, :participant_pubkeys) do
      {:ok, map} when is_map(map) ->
        validate_pinned_map!(map)

      :error ->
        cartel_pinned_pubkeys()
    end
  end

  defp cartel_pinned_pubkeys do
    case safe_cartel_config() do
      {:ok, cfg} ->
        self_atom = Role.participant_id()
        prefix = env_prefix(self_atom)

        peer_map =
          cfg.peer_public_keys
          |> Enum.map(fn {node_id, pk} -> {:"#{prefix}#{node_id}", pk} end)
          |> Map.new()

        Map.put(peer_map, self_atom, Cartel.Config.public_key(cfg))

      :error ->
        %{}
    end
  end

  defp env_prefix(atom_id) do
    atom_id |> Atom.to_string() |> String.first()
  end

  defp safe_cartel_config do
    {:ok, Cartel.config()}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  @doc """
  Returns the pinned Ed25519 public key for `participant`, or
  `{:error, :unknown_participant}` if that participant has no
  pinned key.
  """
  @spec public_key_for(Role.participant_id()) ::
          {:ok, binary()} | {:error, :unknown_participant}
  def public_key_for(participant) when is_atom(participant) do
    case Map.fetch(pinned_pubkeys(), participant) do
      {:ok, pubkey} -> {:ok, pubkey}
      :error -> {:error, :unknown_participant}
    end
  end

  @doc "True if `participant` has a pinned public key in the registry."
  @spec known_participant?(Role.participant_id()) :: boolean()
  def known_participant?(participant) when is_atom(participant) do
    Map.has_key?(pinned_pubkeys(), participant)
  end

  # --- Boot verification ---

  @doc """
  Verifies the local signing key matches the pinned public key for
  this participant, if pinned. Called from
  `PerpWalk.Federation.Supervisor.init/1` before any signing-capable
  child starts.

  Behaviour:

  - Not pinned + local key present   → warn, allow boot (dev)
  - Not pinned + no local key        → warn, allow boot (single-node dev)
  - Pinned + local key matches       → ok
  - Pinned + local key missing       → auto-halt
  - Pinned + local key mismatch      → auto-halt
  """
  @spec verify_local_key_pinning() :: :ok
  def verify_local_key_pinning do
    self_id = Role.participant_id()

    case {public_key_for(self_id), local_public_key()} do
      {{:ok, pinned}, {:ok, local}} ->
        if secure_equal?(pinned, local) do
          :ok
        else
          fail_closed("pinned pubkey for #{inspect(self_id)} does not match local key")
        end

      {{:ok, _pinned}, {:error, :not_found}} ->
        fail_closed("participant #{inspect(self_id)} is pinned but no local key on disk")

      {{:error, :unknown_participant}, _} ->
        Logger.warning("Keys: participant #{inspect(self_id)} not pinned in :participant_pubkeys, running unpinned")

        :ok
    end
  end

  # --- Signing ---

  @doc """
  Signs `message` with the local Ed25519 private key. Returns
  `{:ok, sig}` (64 bytes) or `{:error, :not_found}` if the local
  key is missing.
  """
  @spec sign(iodata()) :: {:ok, binary()} | {:error, :not_found}
  def sign(message) do
    case local_private_key() do
      {:ok, seed} ->
        sig = :crypto.sign(:eddsa, :none, message, [seed, :ed25519])
        {:ok, sig}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Verifies a 64-byte Ed25519 signature `sig` over `message` against
  the pinned public key for `origin`. Returns `false` for unknown
  participants or malformed signatures — both must be treated as
  authentication failure.
  """
  @spec verify(Role.participant_id(), iodata(), binary()) :: boolean()
  def verify(origin, message, sig)
      when is_atom(origin) and is_binary(sig) and byte_size(sig) == @signature_size do
    case public_key_for(origin) do
      {:ok, pubkey} -> :crypto.verify(:eddsa, :none, message, sig, [pubkey, :ed25519])
      {:error, :unknown_participant} -> false
    end
  end

  def verify(_origin, _message, _sig), do: false

  # --- Private ---

  @spec validate_pinned_map!(map()) :: %{Role.participant_id() => binary()}
  defp validate_pinned_map!(map) when is_map(map) do
    Enum.each(map, fn {id, pubkey} ->
      unless id in Role.valid_participants() do
        raise ArgumentError,
              "invalid participant id in :participant_pubkeys: #{inspect(id)}"
      end

      unless is_binary(pubkey) and byte_size(pubkey) == @pubkey_size do
        raise ArgumentError,
              "pinned pubkey for #{inspect(id)} must be #{@pubkey_size} bytes; got #{inspect(pubkey)}"
      end
    end)

    map
  end

  @spec secure_equal?(binary(), binary()) :: boolean()
  defp secure_equal?(a, b) when byte_size(a) == byte_size(b) do
    Plug.Crypto.secure_compare(a, b)
  end

  defp secure_equal?(_a, _b), do: false

  @spec fail_closed(String.t()) :: :ok
  defp fail_closed(reason) do
    HealthSystem.set_source_halt(:federation_keys, "federation key mismatch: #{reason}")
    Logger.error("Keys: #{reason}, auto-halting")
    :ok
  end
end
