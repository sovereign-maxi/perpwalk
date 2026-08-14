defmodule PerpWalkWeb.Auth do
  @moduledoc """
  Session-backed authentication for the public web surface.

  PERP WALK's identity model is keyphrase-as-account (see
  `PerpWalk.Identity`). This module is the seam between that pure
  domain logic and the Phoenix conn/socket world.

  ## Session model — server-side revocable

  Phoenix signed cookies are stateless: the server trusts any
  cookie that carries a valid signature, no matter what the client
  has done with it. That's a problem for logout — without a
  server-side check, a stolen cookie stays useful until it expires.

  We close that gap by binding each cookie to an opaque `session_id`
  (32 random bytes, base64 encoded) that's also stored in
  `PerpWalk.Identity.Sessions`. Every request looks the
  session_id up. `log_out/1` revokes the row, so a captured cookie
  stops working the moment the legit user logs out.

  - `log_in/2` mints a fresh session_id, binds it to `account_id`,
    and puts the id into the signed cookie.
  - `log_out/1` revokes the server-side session and clears the
    cookie.
  - `fetch_current_account/2` is a plug that reads the session_id
    from the cookie, looks it up server-side, and assigns
    `:current_account_id` and `:current_handle` onto the conn.
    Cookies with no server-side row are treated as logged out
    (revoked, never minted, or pre-revocation legacy).
  - `on_mount/4` does the same for LiveView so every view in a
    `live_session` opts into authenticated assigns.
  """

  import Plug.Conn

  alias PerpWalk.Identity.Facade, as: Identity

  @session_key :session_id

  # `account_id` is the Locksmith Argon2id raw hash, lowercase
  # hex — 64 chars across the entire system. Anything else is a
  # programming error (handle / keyphrase / "" passed by mistake).
  # Pinning the shape here means a future caller cannot bind a
  # session against a misshapen value and have the bug surface only
  # at the next ownership check.
  @account_id_pattern ~r/^[0-9a-f]{64}$/

  @doc "Returns `true` if `account_id` matches the Locksmith tag shape."
  @spec valid_account_id?(term()) :: boolean()
  def valid_account_id?(account_id) when is_binary(account_id),
    do: Regex.match?(@account_id_pattern, account_id)

  def valid_account_id?(_), do: false

  # --- Conn Helpers (controllers) ---

  @doc """
  Mints a server-side session, stores `account_id` against it, and
  puts the session_id in the cookie. Replaces any previously
  stored session_id on the conn.

  Raises if `account_id` is not a 64-char lowercase hex string —
  see `valid_account_id?/1` for the rationale.
  """
  @spec log_in(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  @spec log_in(Plug.Conn.t(), String.t(), keyword()) :: Plug.Conn.t()
  def log_in(conn, account_id, opts \\ []) when is_binary(account_id) do
    unless valid_account_id?(account_id) do
      raise ArgumentError,
            "Auth.log_in/2: expected a 64-char lowercase hex account_id, got #{inspect(account_id)}"
    end

    # Revoke any prior session bound to this conn — prevents an
    # orphan row when a user re-logs without explicitly logging
    # out first.
    case get_session(conn, @session_key) do
      sid when is_binary(sid) -> Identity.revoke_session(sid)
      _ -> :ok
    end

    # The per-venue Nostr seckey is HKDF-derived from the user's
    # keyphrase by Identity.Facade.authenticate/1 (or .register/0)
    # and threaded through the controller. It lives in the in-memory
    # Sessions table only — never persisted to disk, gone on logout
    # or BEAM restart. Optional so callers (older tests, future
    # paths) that don't have a keyphrase in hand can still log in.
    session_opts =
      case Keyword.get(opts, :nostr_seckey) do
        sk when is_binary(sk) and byte_size(sk) == 32 -> [nostr_seckey: sk]
        _ -> []
      end

    session_id = Identity.create_session(account_id, session_opts)

    conn
    # `:renew` signals "this is a privilege boundary — rotate the
    # session blob". For cookie-backed sessions the blob already
    # rotates because the session_id we put below is fresh; renew
    # is defence-in-depth against any future scenario where the
    # server-side blob structure changes such that an old cookie
    # could still validate against new contents.
    |> configure_session(renew: true)
    |> put_session(@session_key, session_id)
  end

  @doc """
  Revokes the current session_id server-side and clears the
  cookie. After this, any captured copy of the original cookie is
  rejected by `fetch_current_account/2` as logged out.

  Drops the whole session blob (`configure_session(drop: true)`),
  not just the `:session_id` key. `delete_session/2` would leave
  the cookie alive with any other keys present (CSRF token, flash,
  anything future code adds), so a captured cookie could still
  carry useful state. Dropping forces the browser to receive a
  cookie-clearing Set-Cookie header.
  """
  @spec log_out(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out(conn) do
    case get_session(conn, @session_key) do
      sid when is_binary(sid) -> Identity.revoke_session(sid)
      _ -> :ok
    end

    # `delete_session/2` clears the key for any in-conn reader that
    # runs before the response is built (controller assertions,
    # downstream plugs). `configure_session(drop: true)` is what
    # actually wipes the cookie blob on the response. Both are
    # required: drop alone leaves the in-memory session map
    # populated, delete alone leaves the rest of the blob intact.
    conn
    |> delete_session(@session_key)
    |> configure_session(drop: true)
  end

  @doc """
  Plug. Reads `session_id` from the cookie, resolves it through
  the Sessions, and assigns the resulting `:current_account_id`
  and `:current_handle`. Always assigns — `nil` when no user is
  logged in or the session was revoked — so views can pattern-match
  safely.
  """
  @spec fetch_current_account(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_current_account(conn, _opts) do
    account_id = resolve_session(get_session(conn, @session_key))
    assign_account(conn, account_id)
  end

  defp resolve_session(nil), do: nil

  defp resolve_session(session_id) when is_binary(session_id) do
    case Identity.lookup_session(session_id) do
      {:ok, account_id} -> account_id
      {:error, :not_found} -> nil
    end
  end

  defp resolve_session(_), do: nil

  defp assign_account(conn, nil) do
    conn
    |> assign(:current_account_id, nil)
    |> assign(:current_handle, nil)
  end

  defp assign_account(conn, account_id) when is_binary(account_id) do
    conn
    |> assign(:current_account_id, account_id)
    |> assign(:current_handle, Identity.handle_for(account_id))
  end

  # --- LiveView On_mount ---

  @doc """
  LiveView `on_mount` callback. Reads the session_id from the
  session map and resolves it through the Sessions, so a
  LiveView mounted from a revoked cookie sees `nil` accounts —
  matching the controller plug.

  Subscribes to `Identity.session_topic(session_id)` on connected sockets
  and attaches a `:handle_info` hook that redirects to `/auth/login`
  on `{:session_revoked, _}`. Without this, "log me out everywhere"
  would only block new HTTP requests — already-mounted LiveViews
  would keep their authenticated assigns until the WebSocket
  closes.
  """
  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, session, socket) do
    session_id = session[Atom.to_string(@session_key)] || session[@session_key]
    account_id = resolve_session(session_id)

    socket =
      socket
      |> assign_socket(account_id)
      |> attach_revoke_listener(session_id)

    {:cont, socket}
  end

  defp assign_socket(socket, nil) do
    socket
    |> Phoenix.Component.assign(:current_account_id, nil)
    |> Phoenix.Component.assign(:current_handle, nil)
  end

  defp assign_socket(socket, account_id) when is_binary(account_id) do
    socket
    |> Phoenix.Component.assign(:current_account_id, account_id)
    |> Phoenix.Component.assign(:current_handle, Identity.handle_for(account_id))
  end

  defp attach_revoke_listener(socket, session_id) when is_binary(session_id) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(PerpWalk.PubSub, Identity.session_topic(session_id))
    end

    socket
    |> Phoenix.Component.assign(:session_id, session_id)
    |> Phoenix.LiveView.attach_hook(
      :perpwalk_session_revoked,
      :handle_info,
      &handle_session_revoked/2
    )
  end

  defp attach_revoke_listener(socket, _), do: socket

  defp handle_session_revoked({:session_revoked, sid}, socket) do
    if socket.assigns[:session_id] == sid do
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:info, PerpWalkWeb.Messages.session_revoked())
       |> Phoenix.LiveView.redirect(to: "/auth/login")}
    else
      {:cont, socket}
    end
  end

  defp handle_session_revoked(_msg, socket), do: {:cont, socket}

  @doc "Session cookie key. Exposed for tests."
  @spec session_key() :: atom()
  def session_key, do: @session_key
end
