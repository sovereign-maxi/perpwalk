defmodule PerpWalkWeb.WelcomeControllerIntegrationTest do
  @moduledoc """
  Integration tests for `PerpWalkWeb.WelcomeController` — the
  post-welcome redirect must never bounce the user off-venue.
  """

  use PerpWalkWeb.IntegrationCase

  setup %{conn: conn} do
    {:ok, conn: Plug.Test.init_test_session(conn, %{})}
  end

  describe "POST /welcome/dismiss redirect safety" do
    test "accepts a same-origin relative path", %{conn: conn} do
      conn = post(conn, "/welcome/dismiss", %{"redirect_to" => "/markets"})
      assert redirected_to(conn) == "/markets"
    end

    test "rejects a protocol-relative URL", %{conn: conn} do
      conn = post(conn, "/welcome/dismiss", %{"redirect_to" => "//evil.example"})
      assert redirected_to(conn) == "/"
    end

    test "rejects a backslash protocol-relative smuggle", %{conn: conn} do
      # WHATWG URL parsing treats "/\host" as "//host" in browsers —
      # without the backslash check this is an open redirect.
      conn = post(conn, "/welcome/dismiss", %{"redirect_to" => "/\\evil.example"})
      assert redirected_to(conn) == "/"
    end

    test "rejects an absolute external URL", %{conn: conn} do
      conn = post(conn, "/welcome/dismiss", %{"redirect_to" => "https://evil.example"})
      assert redirected_to(conn) == "/"
    end

    test "falls back to / when redirect_to is missing", %{conn: conn} do
      conn = post(conn, "/welcome/dismiss", %{})
      assert redirected_to(conn) == "/"
    end
  end
end
