defmodule PerpWalk.Storage.WAL.Signing do
  @moduledoc """
  Per-entry Ed25519 authentication for WAL entries.

  Every WAL entry the local Sealer produces is signed with this
  node's Ed25519 signing key (from `PerpWalk.Federation.Keys`). The
  signature covers a deterministic serialisation of `{type, payload}`
  where `payload` includes the `origin` and `seq` stamped by the
  Sealer but excludes the signature itself.

  The Replicator verifies each inbound entry's signature against the
  claimed origin's pinned public key before applying — a rogue peer
  cannot forge entries stamped with another origin, and cannot
  publish entries claiming its own origin unless it holds the
  matching private key.

  ## Canonicalisation

  `:erlang.term_to_binary(term, [:deterministic])` (OTP 26+) sorts
  map keys and produces the same bytes regardless of insertion
  order — safe input for a signature.

  ## Grandfathered unsigned entries

  Local WAL entries written before this module landed have no `:sig`
  field. `verify_entry/1` returns `{:error, :unsigned}` for those —
  the Replicator treats that as a rejection when applying from a
  peer, but domain stores' boot replay reads the WAL directly and
  doesn't call verify, so old entries still replay locally.

  ## Missing local key

  In dev / single-node boots with no local key provisioned,
  `sign_entry/2` returns `{:error, :not_found}`. Callers may proceed
  with an unsigned entry (dev tolerance) — signature enforcement
  happens on the peer-verify side, and dev boots have no peers.
  """

  alias Locker.WAL.Entry
  alias PerpWalk.Federation.Keys
  alias PerpWalk.Role

  @sig_size 64

  @doc """
  Signs the `{type, sealed_payload}` pair with the local Ed25519
  key. `sealed_payload` must already carry `:origin` and `:seq`
  (Sealer's stamp step) but must NOT yet carry `:sig`.

  Returns `{:ok, sig}` (64 bytes) or `{:error, :not_found}` if the
  local key is not provisioned.
  """
  @spec sign_entry(atom(), map()) :: {:ok, binary()} | {:error, :not_found}
  def sign_entry(type, sealed_payload) when is_atom(type) and is_map(sealed_payload) do
    material = canonicalize(type, sealed_payload)
    Keys.sign(material)
  end

  @doc """
  Verifies a signed WAL entry's signature against the pinned public
  key of its stamped `:origin`.

  Returns:
  - `:ok` — signature valid
  - `{:error, :unsigned}` — no `:sig` field on the payload
  - `{:error, :missing_origin}` — no `:origin` field (malformed)
  - `{:error, :unknown_participant}` — origin has no pinned pubkey
  - `{:error, :bad_signature}` — signature does not verify
  """
  @spec verify_entry(Entry.t()) ::
          :ok
          | {:error, :unsigned | :missing_origin | :unknown_participant | :bad_signature}
  def verify_entry(%Entry{type: type, payload: payload}) when is_map(payload) do
    with {:ok, sig} <- extract_sig(payload),
         {:ok, origin} <- extract_origin(payload),
         :ok <- ensure_known_participant(origin) do
      material = canonicalize(type, Map.delete(payload, :sig))

      if Keys.verify(origin, material, sig) do
        :ok
      else
        {:error, :bad_signature}
      end
    end
  end

  def verify_entry(_other), do: {:error, :unsigned}

  @doc """
  Deterministic serialisation of `{type, payload}` for signing. Two
  callers with the same logical entry always produce the same bytes.
  """
  @spec canonicalize(atom(), map()) :: binary()
  def canonicalize(type, payload) when is_atom(type) and is_map(payload) do
    :erlang.term_to_binary({type, payload}, [:deterministic])
  end

  # --- Private ---

  @spec extract_sig(map()) :: {:ok, binary()} | {:error, :unsigned}
  defp extract_sig(%{sig: sig}) when is_binary(sig) and byte_size(sig) == @sig_size do
    {:ok, sig}
  end

  defp extract_sig(_), do: {:error, :unsigned}

  @spec extract_origin(map()) :: {:ok, Role.participant_id()} | {:error, :missing_origin}
  defp extract_origin(%{origin: origin}) when is_atom(origin), do: {:ok, origin}
  defp extract_origin(_), do: {:error, :missing_origin}

  @spec ensure_known_participant(Role.participant_id()) ::
          :ok | {:error, :unknown_participant}
  defp ensure_known_participant(origin) do
    if Keys.known_participant?(origin) do
      :ok
    else
      {:error, :unknown_participant}
    end
  end
end
