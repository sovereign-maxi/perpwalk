defmodule PerpWalk.Identity.Facade do
  @moduledoc """
  Published Language facade for the Identity bounded context.

  PERP WALK's identity model: a 6-word keyphrase IS the account.
  No email, no password, no recovery. The user's possession of
  the keyphrase grants the account; the SHA-256 hash of the
  keyphrase is the only persistent identifier.

  Two operations:

  - `register/0` — generates a fresh keyphrase via Locksmith,
    derives the `account_id` and `handle` from it, and returns
    everything for one-time display. The display key is shown
    once and never persisted server-side.
  - `authenticate/1` — accepts a keyphrase pasted by the user,
    normalizes it, and returns `{:ok, account_id, handle}` for
    any non-empty input. There is no allow-list — any well-formed
    keyphrase is a valid account. The session cookie that the
    web layer subsequently sets is what gates real operations.

  The handle is derived deterministically from the `account_id`
  and is not persisted. See `PerpWalk.Identity.Account` for the
  derivation.
  """

  alias PerpWalk.Identity.{Account, Sessions}

  @doc """
  Generates a fresh 6-word keyphrase and derives the account
  identity from it.

  Returns `{:ok, %{display_key, account_id, handle}}`. The
  `display_key` is shown to the user once and never persisted —
  the user is responsible for keeping it.
  """
  @spec register() ::
          {:ok,
           %{
             display_key: String.t(),
             account_id: String.t(),
             handle: String.t(),
             nostr_seckey: binary(),
             nostr_pubkey: binary()
           }}
  def register do
    {:ok, _events, %{display_key: display_key}} = Locksmith.generate(:keyphrase, words: 6)

    {:ok, %{account_id: account_id, handle: handle}} =
      Account.derive_from_keyphrase(display_key)

    {:ok, {nostr_seckey, nostr_pubkey}} = Account.derive_nostr_keypair(display_key)

    {:ok,
     %{
       display_key: display_key,
       account_id: account_id,
       handle: handle,
       nostr_seckey: nostr_seckey,
       nostr_pubkey: nostr_pubkey
     }}
  end

  @doc """
  Derives the account identity from a user-supplied keyphrase.

  Normalizes whitespace and case before hashing, so a paste with
  stray spaces or lowercase letters resolves to the same account
  as the canonical form.
  """
  @spec authenticate(String.t()) ::
          {:ok,
           %{
             account_id: String.t(),
             handle: String.t(),
             nostr_seckey: binary(),
             nostr_pubkey: binary()
           }}
          | {:error, :empty_keyphrase | :keyphrase_too_short | :invalid}
  def authenticate(keyphrase) when is_binary(keyphrase) do
    with :ok <- validate_keyphrase_shape(keyphrase),
         {:ok, %{account_id: account_id, handle: handle}} <-
           Account.derive_from_keyphrase(keyphrase),
         {:ok, {nostr_seckey, nostr_pubkey}} <- Account.derive_nostr_keypair(keyphrase) do
      {:ok,
       %{
         account_id: account_id,
         handle: handle,
         nostr_seckey: nostr_seckey,
         nostr_pubkey: nostr_pubkey
       }}
    end
  end

  def authenticate(_), do: {:error, :invalid}

  # Refuse keyphrases that lack the 6-token structure Locksmith
  # generates. Pre-fix `authenticate/1` accepted any non-empty
  # string — a user typing "password" got an account with
  # account_id = sha256("password") that anyone else typing the
  # same word would collide with. The Argon2id cost (~500ms) and
  # global rate-limit bucket (50/300s) were the only defences
  # against online guessing of low-entropy self-chosen phrases.
  #
  # Generated 6-word phrases carry ~48 bits of entropy (8 bits per
  # word from a 256-word list); the 6-word floor here matches the
  # generator so a user pasting their generated phrase always
  # works and a user typing "hunter2" bounces early. Longer phrases
  # are welcome — the check counts tokens, not caps them.
  @min_word_count 6

  defp validate_keyphrase_shape(keyphrase) do
    tokens =
      keyphrase
      |> String.trim()
      |> String.split(~r/[\s\-_]+/, trim: true)

    cond do
      tokens == [] -> {:error, :empty_keyphrase}
      length(tokens) < @min_word_count -> {:error, :keyphrase_too_short}
      true -> :ok
    end
  end

  @doc """
  Returns the display handle for an `account_id`. Used by views
  that already have an `account_id` and need to render a friendly
  string (markets list, market detail, admin pages).
  """
  @spec handle_for(String.t()) :: String.t()
  def handle_for(account_id) when is_binary(account_id), do: Account.handle_for(account_id)

  @doc """
  Applies replicated WAL entries to identity-domain state on
  followers. Called by `Storage.Replicator`; mirrors
  `Markets.Facade.replicate_entries/1` and `Federation.Facade.replicate_entries/1`.

  Filters for session_created / session_revoked internally so the
  same entry list can be passed to every domain.
  """
  @spec replicate_entries([Locker.WAL.Entry.t()]) :: :ok
  defdelegate replicate_entries(entries), to: Sessions

  # --- Session Lifecycle (used by web auth + LiveView) ---

  @doc "Creates a session for the given account. See `Sessions.create/2`."
  @spec create_session(String.t(), keyword()) :: String.t()
  defdelegate create_session(account_id, opts \\ []), to: Sessions, as: :create

  @doc "Revokes a session by id. See `Sessions.revoke/1`."
  @spec revoke_session(String.t()) :: :ok
  defdelegate revoke_session(session_id), to: Sessions, as: :revoke

  @doc "Looks up a session by id; returns the bound `account_id`. See `Sessions.lookup/1`."
  @spec lookup_session(String.t()) :: {:ok, binary()} | {:error, :not_found}
  defdelegate lookup_session(session_id), to: Sessions, as: :lookup

  @doc "Looks up the BIP-340 Schnorr seckey for a session. See `Sessions.lookup_nostr_seckey/1`."
  @spec lookup_nostr_seckey(String.t()) :: {:ok, binary()} | {:error, term()}
  defdelegate lookup_nostr_seckey(session_id), to: Sessions

  @doc "PubSub topic for a session, used by LiveView mounts. See `Sessions.topic/1`."
  @spec session_topic(String.t()) :: String.t()
  defdelegate session_topic(session_id), to: Sessions, as: :topic

  @doc "Derives the venue Nostr handle for a given pubkey. See `Account.nostr_handle_for/1`."
  @spec nostr_handle_for(String.t()) :: String.t()
  defdelegate nostr_handle_for(pubkey_hex), to: Account
end
