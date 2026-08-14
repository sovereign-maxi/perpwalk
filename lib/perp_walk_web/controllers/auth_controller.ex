defmodule PerpWalkWeb.AuthController do
  @moduledoc """
  Auth controller — keyphrase generation, login, logout.

  Cookie-setting lives in a controller (not a LiveView) because
  Phoenix LiveView cannot mutate response cookies directly. The
  flow:

  - `GET /auth/login` renders the login/generate page.
  - `POST /auth/generate` mints a fresh keyphrase, sets the
    session cookie, and renders `/auth/welcome` directly with
    the display key as an assign. The keyphrase is never put
    into flash or any other cookie-borne carrier — flash on a
    signed-only session cookie is a base64 `term_to_binary`
    that any browser-disk reader can decode without a key.
  - `GET /auth/welcome` is reached only via redirect from a
    submitted welcome form (no display key) and bounces home.
    The keyphrase is shown exactly once: in the `generate/2`
    response, which is not cacheable and lives only in the
    rendered HTML.
  - `POST /auth/login` authenticates a pasted keyphrase and sets
    the session cookie.
  - `POST /auth/logout` clears the session.

  Already-logged-in users hitting `GET /auth/login` get bounced
  back to `/markets` so the page is essentially "the door" — once
  inside, the door isn't visible.
  """

  use PerpWalkWeb, :controller

  alias PerpWalk.Identity.Facade, as: Identity
  alias PerpWalkWeb.Auth
  alias PerpWalkWeb.Live.Helpers
  alias PerpWalkWeb.Messages

  # A 6-word keyphrase is well under 100 bytes. The Gate plug rate
  # limits login attempts per Tor circuit, but a per-request size
  # bound here is cheap defence-in-depth — anything over a kilobyte
  # is malformed input or probing.
  @max_keyphrase_bytes 1024

  def new(conn, _params) do
    if conn.assigns[:current_account_id] do
      redirect(conn, to: ~p"/markets")
    else
      conn
      |> assign(:health, Helpers.fetch_footer_health())
      |> render(:new)
    end
  end

  def generate(conn, _params) do
    {:ok,
     %{
       display_key: display_key,
       account_id: account_id,
       handle: handle,
       nostr_seckey: nostr_seckey
     }} = Identity.register()

    # `fetch_current_account` ran before this action saw an anonymous
    # request, so `@current_handle` is still nil from the plug. Re-assign
    # here so the page header reflects the just-minted account on the
    # very response that displays the keyphrase.
    conn
    |> Auth.log_in(account_id, nostr_seckey: nostr_seckey)
    |> assign(:current_account_id, account_id)
    |> assign(:current_handle, handle)
    |> assign(:health, Helpers.fetch_footer_health())
    |> put_resp_header("cache-control", "no-store, no-cache, must-revalidate, private")
    |> put_resp_header("pragma", "no-cache")
    |> render(:welcome, display_key: display_key, handle: handle)
  end

  def welcome(conn, _params) do
    redirect(conn, to: ~p"/markets")
  end

  def login(conn, %{"auth" => %{"keyphrase" => keyphrase}})
      when is_binary(keyphrase) and byte_size(keyphrase) <= @max_keyphrase_bytes do
    case Identity.authenticate(keyphrase) do
      {:ok, %{account_id: account_id, handle: handle, nostr_seckey: nostr_seckey}} ->
        conn
        |> Auth.log_in(account_id, nostr_seckey: nostr_seckey)
        |> put_flash(:success, Messages.logged_in_as(handle))
        |> redirect(to: ~p"/markets")

      {:error, :empty_keyphrase} ->
        conn
        |> put_flash(:error, Messages.access_code_required())
        |> redirect(to: ~p"/auth/login")

      {:error, _} ->
        conn
        |> put_flash(:error, Messages.access_code_invalid())
        |> redirect(to: ~p"/auth/login")
    end
  end

  def login(conn, %{"auth" => %{"keyphrase" => keyphrase}}) when is_binary(keyphrase) do
    # Oversized input. Same generic error as malformed — don't hint
    # to a prober whether their payload was too big or just wrong.
    conn
    |> put_flash(:error, Messages.access_code_invalid())
    |> redirect(to: ~p"/auth/login")
  end

  def login(conn, _params) do
    conn
    |> put_flash(:error, Messages.access_code_required())
    |> redirect(to: ~p"/auth/login")
  end

  def logout(conn, _params) do
    conn
    |> Auth.log_out()
    |> put_flash(:success, Messages.logged_out())
    |> redirect(to: ~p"/markets")
  end
end
