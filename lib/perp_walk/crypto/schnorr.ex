defmodule PerpWalk.Crypto.Schnorr do
  @moduledoc """
  Thin adapter for BIP-340 Schnorr signing on secp256k1.

  Cross-domain utility — zero state, no GenServer, designed as the
  single source of truth for secp256k1 ops so flipping the
  underlying library (Cashew today; could be a dedicated secp256k1
  NIF later) is a one-file swap rather than a sweep across
  consumers.

  Wraps the Cashew NIF — the underlying library is a Cashu BDHKE
  implementation that happens to expose general-purpose secp256k1
  primitives we use here. Routing the calls through this module
  keeps the Cashew naming contained.

  All functions return raw binaries:

    - private key: 32 bytes
    - compressed public key: 33 bytes
    - x-only public key (BIP-340): 32 bytes
    - signature: 64 bytes (concatenated R||S)
    - message hash: 32 bytes (typically SHA-256 of the canonical
      event bytes)
  """

  @doc "Generate a random secp256k1 keypair: `{:ok, {privkey, compressed_pubkey}}`."
  @spec generate_keypair() :: {:ok, {binary(), binary()}}
  def generate_keypair, do: Cashew.generate_keypair()

  @doc """
  Derive a compressed public key from a 32-byte private key.

  Returns `{:ok, compressed_pubkey}` (33 bytes) or `{:error, reason}`.
  Raises `FunctionClauseError` on malformed input (non-binary or
  wrong byte length) — callers must validate at the boundary.
  """
  @spec pubkey_from_privkey(binary()) :: {:ok, binary()} | {:error, atom()}
  def pubkey_from_privkey(privkey) when is_binary(privkey) and byte_size(privkey) == 32 do
    Cashew.pubkey_from_privkey(privkey)
  end

  @doc """
  BIP-340 Schnorr sign. Returns `{:ok, {signature, xonly_pubkey}}` —
  the 64-byte signature plus the 32-byte x-only public key derived
  from the private key.

  `msg_hash` must be 32 bytes (typically SHA-256 of canonical event
  bytes per NIP-01). Raises `FunctionClauseError` on malformed
  input — callers must validate at the boundary.
  """
  @spec sign(binary(), binary()) :: {:ok, {binary(), binary()}} | {:error, atom()}
  def sign(privkey, msg_hash)
      when is_binary(privkey) and byte_size(privkey) == 32 and
             is_binary(msg_hash) and byte_size(msg_hash) == 32 do
    Cashew.schnorr_sign(privkey, msg_hash)
  end

  @doc """
  BIP-340 Schnorr verify. Returns `:ok` on a valid signature,
  `{:error, reason}` otherwise. Raises `FunctionClauseError` on
  malformed input — callers must validate at the boundary.
  """
  @spec verify(binary(), binary(), binary()) :: :ok | {:error, atom()}
  def verify(xonly_pubkey, msg_hash, signature)
      when is_binary(xonly_pubkey) and byte_size(xonly_pubkey) == 32 and
             is_binary(msg_hash) and byte_size(msg_hash) == 32 and
             is_binary(signature) and byte_size(signature) == 64 do
    Cashew.schnorr_verify(xonly_pubkey, msg_hash, signature)
  end
end
