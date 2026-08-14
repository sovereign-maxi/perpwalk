defmodule PerpWalkWeb.TestHelpers.AuthHelpers do
  @moduledoc """
  Test helpers for the server-side session store.

  Replaces the older pattern of `init_test_session(conn, %{Auth.session_key() => account_id})`
  which assumed the session cookie carried the account_id directly.
  Now the cookie carries an opaque `session_id` minted by
  `PerpWalk.Identity.Sessions`; the server-side row is what
  authenticates the request.
  """

  alias PerpWalk.Identity.Sessions
  alias PerpWalkWeb.Auth

  @doc """
  Logs in `account_id` on `conn` by minting a server-side session
  row and writing the resulting session_id into the test cookie.
  Equivalent to a real `Auth.log_in/2` call followed by
  `Plug.Test.init_test_session/2`.
  """
  @spec log_in_account(Plug.Conn.t(), binary()) :: Plug.Conn.t()
  def log_in_account(conn, account_id) when is_binary(account_id) do
    session_id = Sessions.create(account_id)
    # `welcomed: true` short-circuits the first-visit welcome modal
    # for logged-in test contexts — a logged-in user has by definition
    # already been through the site. Tests that specifically want to
    # exercise the welcome-modal path should build their own conn.
    Plug.Test.init_test_session(conn, %{
      Auth.session_key() => session_id,
      "welcomed" => true
    })
  end

  @doc """
  Returns a session map that pairs an `Auth.session_key()` with a
  freshly-minted session_id for `account_id`. Use when a test
  needs to drive the session map directly (e.g., LiveView mount
  tests that don't go through the conn pipeline).
  """
  @spec login_session(binary()) :: map()
  def login_session(account_id) when is_binary(account_id) do
    session_id = Sessions.create(account_id)
    %{Auth.session_key() => session_id}
  end

  @doc """
  Wipes every row from the supervised Sessions table. Test-only —
  kept here (in `test/support`) so production code never has any
  knowledge of the test environment.
  """
  @spec clear_sessions() :: :ok
  def clear_sessions do
    :ets.delete_all_objects(Sessions.table_name())
    :ok
  rescue
    ArgumentError -> :ok
  end
end
