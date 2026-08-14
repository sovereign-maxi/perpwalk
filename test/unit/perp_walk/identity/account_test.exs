defmodule PerpWalk.Identity.AccountTest do
  @moduledoc """
  Unit tests for `PerpWalk.Identity.Account` keyphrase derivation.
  """

  use ExUnit.Case, async: true

  alias PerpWalk.Identity.Account

  describe "derive_from_keyphrase/1" do
    test "produces a 64-char hex account_id" do
      assert {:ok, %{account_id: id}} = Account.derive_from_keyphrase("AMBER-FROST-DELTA-NINE-WOLF-APEX")

      assert byte_size(id) == 64
      assert id =~ ~r/^[0-9a-f]{64}$/
    end

    test "is deterministic — same keyphrase yields same account_id" do
      assert {:ok, %{account_id: a}} = Account.derive_from_keyphrase("BIRD-HACK-CALM-DUEL-EAST-FACE")
      assert {:ok, %{account_id: b}} = Account.derive_from_keyphrase("BIRD-HACK-CALM-DUEL-EAST-FACE")

      assert a == b
    end

    test "different keyphrases yield different account_ids" do
      assert {:ok, %{account_id: a}} = Account.derive_from_keyphrase("BIRD-HACK-CALM-DUEL-EAST-FACE")
      assert {:ok, %{account_id: b}} = Account.derive_from_keyphrase("WOLF-HACK-CALM-DUEL-EAST-FACE")

      refute a == b
    end

    test "normalises whitespace and case" do
      assert {:ok, %{account_id: a}} = Account.derive_from_keyphrase("amber-frost-delta-nine-wolf-apex")
      assert {:ok, %{account_id: b}} = Account.derive_from_keyphrase("  AMBER-FROST-DELTA-NINE-WOLF-APEX  ")
      assert {:ok, %{account_id: c}} = Account.derive_from_keyphrase("AMBER-FROST-DELTA-NINE-WOLF-APEX")

      assert a == b
      assert b == c
    end

    test "rejects empty keyphrase" do
      assert {:error, :empty_keyphrase} = Account.derive_from_keyphrase("")
      assert {:error, :empty_keyphrase} = Account.derive_from_keyphrase("   ")
    end

    test "returns the normalized form for downstream use" do
      assert {:ok, %{normalized_keyphrase: norm}} =
               Account.derive_from_keyphrase("  amber-frost-delta-nine-wolf-apex  ")

      assert norm == "AMBER-FROST-DELTA-NINE-WOLF-APEX"
    end

    test "handle is included in the result" do
      assert {:ok, %{account_id: id, handle: handle}} =
               Account.derive_from_keyphrase("BIRD-HACK-CALM-DUEL-EAST-FACE")

      assert handle == Account.handle_for(id)
    end
  end

  describe "handle_for/1" do
    test "produces an adjective-animal-NNNN handle" do
      handle = Account.handle_for(String.duplicate("a", 64))

      assert handle =~ ~r/^[a-z]+-[a-z]+-\d{4}$/
    end

    test "is deterministic" do
      id = String.duplicate("c", 64)
      assert Account.handle_for(id) == Account.handle_for(id)
    end

    test "different account_ids produce different handles (with overwhelming probability)" do
      ids = for i <- 1..50, do: String.duplicate(<<i>>, 64)
      handles = Enum.map(ids, &Account.handle_for/1)

      # 41M handle space against 50 samples — collisions astronomically improbable.
      assert length(Enum.uniq(handles)) == 50
    end

    test "stable across calls — same input every time" do
      keyphrase = "AMBER-FROST-DELTA-NINE-WOLF-APEX"
      {:ok, %{account_id: id}} = Account.derive_from_keyphrase(keyphrase)

      handle1 = Account.handle_for(id)
      handle2 = Account.handle_for(id)
      handle3 = Account.handle_for(id)

      assert handle1 == handle2
      assert handle2 == handle3
    end
  end

  describe "derive_nostr_keypair/1" do
    test "returns 32-byte seckey and 32-byte x-only pubkey" do
      assert {:ok, {seckey, pubkey}} =
               Account.derive_nostr_keypair("AMBER-FROST-DELTA-NINE-WOLF-APEX")

      assert byte_size(seckey) == 32
      assert byte_size(pubkey) == 32
    end

    test "is deterministic — same keyphrase yields same keypair" do
      assert {:ok, {a_sk, a_pk}} =
               Account.derive_nostr_keypair("BIRD-HACK-CALM-DUEL-EAST-FACE")

      assert {:ok, {b_sk, b_pk}} =
               Account.derive_nostr_keypair("BIRD-HACK-CALM-DUEL-EAST-FACE")

      assert a_sk == b_sk
      assert a_pk == b_pk
    end

    test "different keyphrases yield different keypairs" do
      assert {:ok, {a_sk, a_pk}} =
               Account.derive_nostr_keypair("BIRD-HACK-CALM-DUEL-EAST-FACE")

      assert {:ok, {b_sk, b_pk}} =
               Account.derive_nostr_keypair("WOLF-HACK-CALM-DUEL-EAST-FACE")

      refute a_sk == b_sk
      refute a_pk == b_pk
    end

    test "normalises whitespace and case before derivation" do
      assert {:ok, {a, _}} = Account.derive_nostr_keypair("amber-frost-delta-nine-wolf-apex")

      assert {:ok, {b, _}} =
               Account.derive_nostr_keypair("  AMBER-FROST-DELTA-NINE-WOLF-APEX  ")

      assert {:ok, {c, _}} = Account.derive_nostr_keypair("AMBER-FROST-DELTA-NINE-WOLF-APEX")

      assert a == b
      assert b == c
    end

    test "produces a different seckey than the account_id for the same keyphrase" do
      # Domain separation: handle/account derivation and Nostr
      # derivation use different salts so leakage of one tells
      # nothing about the other.
      keyphrase = "AMBER-FROST-DELTA-NINE-WOLF-APEX"
      {:ok, %{account_id: account_id}} = Account.derive_from_keyphrase(keyphrase)
      {:ok, {seckey, _pubkey}} = Account.derive_nostr_keypair(keyphrase)

      seckey_hex = Base.encode16(seckey, case: :lower)
      refute account_id == seckey_hex
    end

    test "the derived pubkey signs and verifies under BIP-340 Schnorr" do
      keyphrase = "AMBER-FROST-DELTA-NINE-WOLF-APEX"
      {:ok, {seckey, pubkey}} = Account.derive_nostr_keypair(keyphrase)

      msg = :crypto.hash(:sha256, "test message")
      {:ok, {signature, signer_pubkey}} = Cashew.schnorr_sign(seckey, msg)

      # schnorr_sign also returns the x-only pubkey it derived from
      # the seckey — assert it matches the pubkey our derivation
      # produced (closes the loop on the parity-byte strip).
      assert signer_pubkey == pubkey
      assert :ok = Cashew.schnorr_verify(pubkey, msg, signature)
    end

    test "rejects empty input" do
      assert {:error, :empty_keyphrase} = Account.derive_nostr_keypair("")
      assert {:error, :empty_keyphrase} = Account.derive_nostr_keypair("   ")
    end
  end

  describe "nostr_handle_for/1" do
    test "produces an adjective-animal-NNNN handle from a hex pubkey" do
      handle = Account.nostr_handle_for(String.duplicate("a", 64))
      assert handle =~ ~r/^[a-z]+-[a-z]+-\d{4}$/
    end

    test "accepts both 32-byte raw and 64-char hex inputs" do
      raw = String.duplicate(<<0xAB>>, 32)
      hex = Base.encode16(raw, case: :lower)

      # The handle space is intentionally namespace-separated from
      # account-id handles, so the two encodings produce DIFFERENT
      # handles when fed into the same function — different inputs
      # to the HMAC. This documents the behaviour rather than
      # asserting raw == hex (which is wrong).
      assert is_binary(Account.nostr_handle_for(raw))
      assert is_binary(Account.nostr_handle_for(hex))
    end

    test "is deterministic — same pubkey yields same handle" do
      pubkey = String.duplicate("c", 64)
      assert Account.nostr_handle_for(pubkey) == Account.nostr_handle_for(pubkey)
    end

    test "different pubkeys produce different handles with overwhelming probability" do
      handles =
        for i <- 1..50, do: Account.nostr_handle_for(Base.encode16(<<i::256>>, case: :lower))

      assert length(Enum.uniq(handles)) == 50
    end

    test "uses a distinct namespace from handle_for/1 (different domain separator)" do
      # Even a value that's both a valid account_id and a valid
      # nostr pubkey hex won't produce colliding handles, because
      # the two functions use different domain separators.
      common = String.duplicate("9", 64)
      refute Account.handle_for(common) == Account.nostr_handle_for(common)
    end

    test "rejects malformed pubkey inputs" do
      assert_raise FunctionClauseError, fn -> Account.nostr_handle_for("too-short") end
      assert_raise FunctionClauseError, fn -> Account.nostr_handle_for(:not_binary) end
    end
  end
end
