defmodule PerpWalk.Federation.Checkpointer.Digest do
  @moduledoc """
  Deterministic 32-byte state-root computation.

  Hashes the reserves snapshot fields + WAL cursor into a 32-byte
  digest. Any verifier with a guardian's pinned Ed25519 pubkey + the
  snapshot fields can recompute this locally and verify the
  checkpoint signature.

  ## Serialization

  Each numeric field is emitted as a 64-bit big-endian integer. The
  `captured_at` timestamp is converted to Unix seconds and emitted as
  a 64-bit signed integer. Order is fixed:

      wal_cursor
      held_piconeros
      outstanding_piconeros
      delta_piconeros (signed)
      captured_at_unix

  Total pre-image: 40 bytes. Tagged with a prefix so an attacker
  can't reuse a state root as any other kind of signable.
  """

  @tag "PERPWALK/checkpoint/v1"

  @doc """
  Computes the 32-byte state root over `snapshot` (as
  `Vault.Snapshot.to_piconeros/1` shape) and `wal_cursor`.
  Deterministic — same inputs always produce the same output.
  """
  @spec compute(map(), non_neg_integer()) :: binary()
  def compute(%{} = snapshot, wal_cursor) when is_integer(wal_cursor) do
    :crypto.hash(:sha256, tag_prefix() <> encode(snapshot, wal_cursor))
  end

  @doc """
  Serialises a snapshot + WAL cursor into the canonical 40-byte
  pre-image. Exposed for verification tooling — any client can
  recompute the state root by hashing `tag_prefix() <> encode(...)`.
  """
  @spec encode(map(), non_neg_integer()) :: binary()
  def encode(%{} = snapshot, wal_cursor) when is_integer(wal_cursor) do
    held = Map.get(snapshot, :held_piconeros, 0)
    outstanding = Map.get(snapshot, :outstanding_piconeros, 0)
    delta = Map.get(snapshot, :delta_piconeros, held - outstanding)
    captured_at = Map.get(snapshot, :captured_at) || DateTime.utc_now()

    <<
      wal_cursor::big-unsigned-integer-size(64),
      held::big-unsigned-integer-size(64),
      outstanding::big-unsigned-integer-size(64),
      delta::big-signed-integer-size(64),
      DateTime.to_unix(captured_at, :second)::big-signed-integer-size(64)
    >>
  end

  @doc "Tag prefix used to domain-separate checkpoint hashes from other sighashes."
  @spec tag_prefix() :: binary()
  def tag_prefix, do: @tag

  @doc """
  Verifies an Ed25519 signature against a recomputed state root.
  `pubkey` is the 32-byte Ed25519 public key of the signing guardian.
  Returns `true` if the signature is valid.
  """
  @spec verify(map(), non_neg_integer(), binary(), binary()) :: boolean()
  def verify(%{} = snapshot, wal_cursor, signature, pubkey)
      when is_integer(wal_cursor) and is_binary(signature) and byte_size(signature) == 64 and
             is_binary(pubkey) and byte_size(pubkey) == 32 do
    state_root = compute(snapshot, wal_cursor)
    :crypto.verify(:eddsa, :none, state_root, signature, [pubkey, :ed25519])
  end

  def verify(_snapshot, _wal_cursor, _signature, _pubkey), do: false
end
