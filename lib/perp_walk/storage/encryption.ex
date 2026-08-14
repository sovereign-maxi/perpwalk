defmodule PerpWalk.Storage.Encryption do
  @moduledoc """
  At-rest encryption helpers.

  AES-256-GCM with a single root master key (`PERPWALK_ENCRYPTION_KEY`)
  derived through HKDF-SHA256 with domain separation. Each at-rest secret
  in the application (Nostr signing key, Monero wallet seed, anything
  else added later) shares the same root and is bound to a per-message
  random IV.

  ## Configuration

      # `runtime.exs` reads PERPWALK_ENCRYPTION_KEY from the environment
      # and copies it into application env:
      config :perpwalk, :encryption_key, "..."

  Production boot refuses to start without the env var set.
  """

  # --- Constants ---

  @aad "perpwalk-v1"
  @hkdf_salt "perpwalk-encryption-salt-v1"
  @hkdf_info "perpwalk-encryption-key-v1"

  # --- Public API ---

  @doc """
  Encrypts a binary value. Returns `{:ok, ciphertext}` where ciphertext
  is `iv (12) || tag (16) || ciphertext`.

  `aad` is the additional-authenticated-data string. Pass a label
  describing the at-rest record's purpose (e.g. `"reserves-nostr-v1"`)
  so an attacker who swaps two ciphertexts on disk gets a tag
  mismatch on decrypt — without per-record AAD all encrypted records
  share the same authentication context. Defaults to `"perpwalk-v1"`
  for backwards compatibility with records persisted before the
  per-record AAD became part of the API.
  """
  @spec encrypt(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def encrypt(plaintext, aad \\ @aad) when is_binary(plaintext) and is_binary(aad) do
    key = get_key()
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        iv,
        plaintext,
        aad,
        true
      )

    {:ok, iv <> tag <> ciphertext}
  end

  @doc """
  Decrypts a binary previously produced by `encrypt/2`. The `aad`
  passed here MUST match the one used at encrypt time.
  """
  @spec decrypt(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def decrypt(encrypted, aad \\ @aad)

  def decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>, aad) when is_binary(aad) do
    key = get_key()

    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           iv,
           ciphertext,
           aad,
           tag,
           false
         ) do
      :error -> {:error, :decryption_failed}
      plaintext -> {:ok, plaintext}
    end
  end

  def decrypt(_, _), do: {:error, :invalid_encrypted_data}

  @doc "Encrypts an Erlang term by first serialising to binary."
  @spec encrypt_term(term(), binary()) :: {:ok, binary()} | {:error, term()}
  def encrypt_term(term, aad \\ @aad), do: encrypt(:erlang.term_to_binary(term), aad)

  @doc "Decrypts a binary back into an Erlang term using the safe decoder."
  @spec decrypt_term(binary(), binary()) :: {:ok, term()} | {:error, term()}
  def decrypt_term(encrypted, aad \\ @aad) do
    case decrypt(encrypted, aad) do
      {:ok, bin} -> {:ok, :erlang.binary_to_term(bin, [:safe])}
      error -> error
    end
  end

  # --- Key Derivation ---

  # Fixed salt is intentional — backup restores across hosts must derive
  # the same key from the same root. Per-message uniqueness is provided
  # by the random IV in `encrypt/1`.
  @doc false
  def get_key do
    case Application.get_env(:perpwalk, :encryption_key) do
      nil ->
        if Application.get_env(:perpwalk, :env) == :prod do
          raise "PERPWALK_ENCRYPTION_KEY must be set in production!"
        end

        hkdf_derive("perpwalk-dev-key-do-not-use-in-production")

      key when is_binary(key) and byte_size(key) == 32 ->
        key

      key when is_binary(key) ->
        hkdf_derive(key)
    end
  end

  # HKDF-SHA256 extract-and-expand with explicit salt + info for domain
  # separation. Produces a 32-byte output suitable for AES-256-GCM.
  defp hkdf_derive(ikm) do
    prk = :crypto.mac(:hmac, :sha256, @hkdf_salt, ikm)
    :crypto.mac(:hmac, :sha256, prk, @hkdf_info <> <<1>>)
  end
end
