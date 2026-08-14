defmodule PerpWalkWeb.AuthControllerIntegrationTest do
  @moduledoc """
  Integration tests for the keyphrase auth flow — generate,
  login, welcome screen, logout, and the on_mount LiveView assign.
  """

  use PerpWalkWeb.IntegrationCase

  import Plug.Conn, only: [get_session: 2]

  alias PerpWalk.Identity.Facade, as: Identity
  alias PerpWalk.Identity.Sessions
  alias PerpWalkWeb.Auth
  alias PerpWalkWeb.TestHelpers.AuthHelpers

  setup %{conn: conn} do
    {:ok, conn: Plug.Test.init_test_session(conn, %{})}
  end

  describe "GET /auth/login" do
    test "renders the access page with both paths", %{conn: conn} do
      conn = get(conn, "/auth/login")
      html = html_response(conn, 200)

      assert html =~ "Login / Register"
      assert html =~ ~s(name="auth[keyphrase]")
      assert html =~ "Login"
      assert html =~ "Generate"
      assert html =~ ~s(formaction="/auth/generate")
    end

    test "redirects logged-in users to /markets", %{conn: conn} do
      {:ok, %{account_id: account_id}} = Identity.register()

      conn =
        conn
        |> AuthHelpers.log_in_account(account_id)
        |> get("/auth/login")

      assert redirected_to(conn) == "/markets"
    end
  end

  describe "POST /auth/generate" do
    test "mints a fresh keyphrase, logs in, and renders it directly", %{conn: conn} do
      conn = post(conn, "/auth/generate", %{})

      # The keyphrase is rendered in the same response — no redirect,
      # no flash. Routing through flash on a signed-only session
      # cookie would put the plaintext keyphrase into a base64
      # term_to_binary that any reader of the cookie can decode.
      html = html_response(conn, 200)
      assert html =~ "Save your access code"
      assert html =~ ~r/[A-Z]+-[A-Z]+-[A-Z]+-[A-Z]+-[A-Z]+-[A-Z]+/
      assert html =~ ~r/[a-z]+-[a-z]+-\d{4}/

      # And the cache headers prevent any intermediary or browser-back
      # from re-showing the keyphrase.
      assert Plug.Conn.get_resp_header(conn, "cache-control") == [
               "no-store, no-cache, must-revalidate, private"
             ]

      # Cookie now carries an opaque session_id, not the raw account_id.
      # The session_id resolves to a real account in Sessions.
      session_id = get_session(conn, Auth.session_key())
      assert is_binary(session_id) and byte_size(session_id) > 0
      assert {:ok, account_id} = Sessions.lookup(session_id)
      assert account_id =~ ~r/^[0-9a-f]{64}$/
    end
  end

  describe "GET /auth/welcome" do
    test "always redirects to /markets — keyphrase only ever shows once on the generate response", %{conn: conn} do
      conn = get(conn, "/auth/welcome")
      assert redirected_to(conn) == "/markets"
    end
  end

  describe "POST /auth/login" do
    test "logs in with a valid keyphrase", %{conn: conn} do
      {:ok, %{display_key: keyphrase, account_id: account_id}} = Identity.register()

      conn = post(conn, "/auth/login", %{"auth" => %{"keyphrase" => keyphrase}})

      assert redirected_to(conn) == "/markets"

      # The cookie holds a session_id; Sessions.lookup ties it to
      # the account that just authenticated.
      session_id = get_session(conn, Auth.session_key())
      assert {:ok, ^account_id} = Sessions.lookup(session_id)
    end

    test "lowercases and whitespace-tolerant input still authenticates", %{conn: conn} do
      {:ok, %{display_key: keyphrase, account_id: account_id}} = Identity.register()

      conn =
        post(conn, "/auth/login", %{
          "auth" => %{"keyphrase" => "  " <> String.downcase(keyphrase) <> "  "}
        })

      session_id = get_session(conn, Auth.session_key())
      assert {:ok, ^account_id} = Sessions.lookup(session_id)
    end

    test "rejects empty input with a flash error", %{conn: conn} do
      conn = post(conn, "/auth/login", %{"auth" => %{"keyphrase" => ""}})

      assert redirected_to(conn) == "/auth/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Enter your access code"
      assert get_session(conn, Auth.session_key()) == nil
    end
  end

  describe "POST /auth/logout" do
    test "clears the session cookie", %{conn: conn} do
      {:ok, %{account_id: account_id}} = Identity.register()

      conn =
        conn
        |> AuthHelpers.log_in_account(account_id)
        |> post("/auth/logout", %{})

      assert redirected_to(conn) == "/markets"
      assert get_session(conn, Auth.session_key()) == nil
    end

    test "revokes the server-side session_id (replay defence)", %{conn: conn} do
      # Threat model: an attacker captures a logged-in cookie. After
      # the legit user logs out, the attacker tries to replay the
      # cookie. Server must reject because the session_id row is gone.
      {:ok, %{account_id: account_id}} = Identity.register()

      logged_in =
        conn
        |> AuthHelpers.log_in_account(account_id)

      stolen_session_id = get_session(logged_in, Auth.session_key())
      assert {:ok, ^account_id} = Sessions.lookup(stolen_session_id)

      # User logs out
      _logged_out = post(logged_in, "/auth/logout", %{})

      # Sessions no longer knows about that session_id
      assert {:error, :not_found} =
               Sessions.lookup(stolen_session_id)

      # Replay: build a fresh conn carrying the stolen session_id and
      # hit a public LiveView. fetch_current_account must NOT bind it
      # to the original account.
      replay_conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{Auth.session_key() => stolen_session_id})

      {:ok, view, _html} = live(replay_conn, "/markets")
      assert :sys.get_state(view.pid).socket.assigns.current_account_id == nil
    end
  end

  describe "LiveView on_mount assigns" do
    test "current_handle is nil when not logged in", %{conn: conn} do
      {:ok, view, html} = live(conn, "/markets")

      assert html =~ "Log in"
      refute html =~ "Log out"
      assert :sys.get_state(view.pid).socket.assigns.current_account_id == nil
      assert :sys.get_state(view.pid).socket.assigns.current_handle == nil
    end

    test "current_handle is the derived handle when logged in", %{conn: conn} do
      {:ok, %{account_id: account_id, handle: handle}} = Identity.register()

      conn =
        conn
        |> AuthHelpers.log_in_account(account_id)

      {:ok, view, html} = live(conn, "/markets")

      assert html =~ handle
      assert html =~ "Log out"
      assert :sys.get_state(view.pid).socket.assigns.current_account_id == account_id
      assert :sys.get_state(view.pid).socket.assigns.current_handle == handle
    end
  end
end
