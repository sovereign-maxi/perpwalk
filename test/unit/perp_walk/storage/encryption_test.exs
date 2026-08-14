defmodule PerpWalk.Storage.EncryptionTest do
  @moduledoc "Unit tests for PerpWalk.Storage.Encryption."

  use ExUnit.Case, async: true

  alias PerpWalk.Storage.Encryption

  describe "encrypt/1 and decrypt/1" do
    test "round-trips binary data" do
      plaintext = "hello world, this is sensitive at-rest data"
      {:ok, encrypted} = Encryption.encrypt(plaintext)

      assert encrypted != plaintext
      assert byte_size(encrypted) > byte_size(plaintext)

      {:ok, decrypted} = Encryption.decrypt(encrypted)
      assert decrypted == plaintext
    end

    test "different encryptions of same plaintext produce different ciphertext" do
      plaintext = "same data"
      {:ok, enc1} = Encryption.encrypt(plaintext)
      {:ok, enc2} = Encryption.encrypt(plaintext)

      # Random IV per call means ciphertexts must differ.
      assert enc1 != enc2
    end

    test "decrypting corrupted data returns an error" do
      {:ok, encrypted} = Encryption.encrypt("test")
      <<a, rest::binary>> = encrypted
      corrupted = <<Bitwise.bxor(a, 0xFF), rest::binary>>

      assert {:error, _} = Encryption.decrypt(corrupted)
    end

    test "decrypting too-short data returns invalid_encrypted_data" do
      assert {:error, :invalid_encrypted_data} = Encryption.decrypt("too_short")
    end
  end

  describe "encrypt_term/1 and decrypt_term/1" do
    test "round-trips Elixir terms" do
      term = %{
        scalar: 1,
        binary: :crypto.strong_rand_bytes(32),
        list: [:a, :b, :c]
      }

      {:ok, encrypted} = Encryption.encrypt_term(term)
      {:ok, decrypted} = Encryption.decrypt_term(encrypted)

      assert decrypted == term
    end

    test "round-trips deeply nested terms" do
      term = %{
        outer: %{
          inner: %{
            keys: %{
              1 => :crypto.strong_rand_bytes(32),
              2 => :crypto.strong_rand_bytes(32)
            }
          }
        },
        meta: [created_at: 12_345, version: 1]
      }

      {:ok, encrypted} = Encryption.encrypt_term(term)
      {:ok, decrypted} = Encryption.decrypt_term(encrypted)

      assert decrypted == term
    end
  end
end
