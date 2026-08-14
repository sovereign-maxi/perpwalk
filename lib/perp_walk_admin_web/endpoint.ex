defmodule PerpWalkAdminWeb.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :perpwalk

  # Admin is Tor-only by hard invariant (see OnionOnly plug below
  # and project_perp_walk_admin_tor_only). `secure: false` is
  # correct unconditionally — `.onion` is HTTP, and there is no
  # clearnet branch to defend against.
  @session_options [
    store: :cookie,
    key: "_perpwalk_admin_key",
    signing_salt: "perpwalk_admin_s",
    same_site: "Strict",
    secure: false
  ]

  # See PerpWalkWeb.Endpoint — same permessage-deflate + heartbeat
  # tolerance rationale.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [session: @session_options],
      max_frame_size: 16_384,
      compress: true,
      timeout: 120_000
    ]

  # OnionOnly runs first so static asset paths (`/assets/*`,
  # `/favicon.*`, `/robots.txt`) cannot be served to a request
  # whose Host header is not the configured admin .onion. Plug.Static
  # short-circuits on match, so placing it before the gate would
  # let a misconfigured listener (reverse proxy, sidecar, accidental
  # 0.0.0.0 bind) leak digested-asset hashes and confirm the admin
  # endpoint exists at a given host/port.
  plug PerpWalkAdminWeb.Plugs.OnionOnly

  # See PerpWalkWeb.Endpoint — same dev/prod cache-control split.
  plug Plug.Static,
    at: "/",
    from: :perpwalk,
    gzip: true,
    only: PerpWalkAdminWeb.static_paths(),
    cache_control_for_etags: Application.compile_env(:perpwalk, :static_cache_control)

  # See PerpWalkWeb.Endpoint — same immutable-fonts / etag-css split.
  plug Plug.Static,
    at: "/",
    from: {:blueprint, "priv/static"},
    gzip: true,
    only: ~w(assets)

  plug Plug.Static,
    at: "/",
    from: {:blueprint, "priv/static"},
    gzip: true,
    only: ~w(fonts),
    cache_control_for_etags: Application.compile_env(:perpwalk, :static_cache_control)

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["text/plain"],
    json_decoder: Phoenix.json_library(),
    length: 1_000_000

  plug Plug.Session, @session_options
  plug PerpWalkWeb.Plugs.SecurityHeaders
  plug PerpWalkAdminWeb.Router
end
