defmodule PerpWalkWeb.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :perpwalk

  # `secure: false` because the user endpoint serves .onion (HTTP)
  # only — Tor provides transport encryption at the network layer.
  # `secure: true` would prevent the cookie from being sent at all,
  # breaking sessions and LiveView CSRF.
  #
  # max_age is set explicitly to match the server-side ETS session
  # TTL — without it Plug emits a session-cookie (no expiry) and
  # client behaviour across non-Tor-Browser stacks is undefined.
  # Aligning the two means a captured cookie can't outlive the
  # server's view of the session.
  @session_max_age_seconds 30 * 24 * 60 * 60
  @session_options [
    store: :cookie,
    key: "_perpwalk_key",
    signing_salt: "perpwalk_s",
    same_site: "Strict",
    http_only: true,
    max_age: @session_max_age_seconds,
    secure: false
  ]

  # `compress: true` enables WebSocket permessage-deflate (RFC 7692).
  # LiveView diffs are JSON; on the chatty path that means ~70% smaller
  # frames on every market update, position render, TVL refresh, and
  # event push. On a Tor circuit (the only path that matters here) the
  # bandwidth saved per frame is the dominant latency factor — every
  # byte that doesn't ship saves a multiplexed-circuit round trip
  # window. CPU cost is negligible at our message rate.
  # `heartbeat_interval` defaults to nil server-side (the client drives
  # cadence). `timeout: 120_000` matches the client's bumped
  # `heartbeatIntervalMs: 60000` (assets/js/app.js) — server tolerates
  # one missed heartbeat with network jitter before dropping the
  # connection. Default 60_000 would equal the heartbeat interval and
  # any jitter would kill live sessions over Tor.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [session: @session_options],
      max_frame_size: 131_072,
      compress: true,
      timeout: 120_000
    ]

  # `immutable` is correct in prod (where `mix phx.digest` stamps a
  # content hash into the asset path, so a changed file gets a new
  # URL). In dev the path stays `/assets/app.css` forever, and
  # `immutable` would tell the browser to never even ask if it
  # changed — defeating live-reload. Compile-time env keeps prod
  # cache-aggressive while dev revalidates via ETag.
  plug Plug.Static,
    at: "/",
    from: :perpwalk,
    gzip: true,
    only: PerpWalkWeb.static_paths(),
    cache_control_for_etags: Application.compile_env(:perpwalk, :static_cache_control)

  # Serve Blueprint design system assets (CSS + fonts) from the blueprint dependency.
  # `gzip: true` requires `.gz` siblings in the dep's own priv/static
  # (phx.digest only touches the app's priv/static, not deps).
  #
  # Fonts get the long-lived immutable cache; blueprint.css stays on
  # ETag revalidation because it is undigested — immutable would
  # strand clients on stale CSS. Font files are content-stable (a
  # change means a new filename). ETag-only fonts made every revisit
  # revalidate over Tor and broke Chromium's preload matching
  # ("preloaded but not used" console warnings).
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
  plug PerpWalkWeb.Router
end
