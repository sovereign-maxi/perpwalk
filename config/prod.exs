import Config

# Production compile-time configuration. Runtime configuration
# (env-driven secrets, hostnames, ports) lives in runtime.exs.
#
# `server: true` is required on both endpoints so a `mix release`
# starts the listeners. config.exs has `server: false` (test
# default); dev.exs flips it for `mix phx.server`; this file is
# the prod toggle.

# `cache_static_manifest` points Phoenix at the digest table produced
# by `mix phx.digest`. Without it, `~p"/assets/app.css"` renders the
# unhashed path; with it, Phoenix rewrites to the content-addressed
# `app-<sha>.css` filename. That's what makes the `immutable, max-age=1y`
# cache-control safe — every content change ships under a new URL, so a
# cached client never sees stale bytes. The path is relative to the
# application's `priv_dir`, which in a release is
# `<release>/lib/perpwalk-<version>/priv/`.
config :perpwalk, PerpWalkWeb.Endpoint,
  server: true,
  cache_static_manifest: "priv/static/cache_manifest.json"

config :perpwalk, PerpWalkAdminWeb.Endpoint,
  server: true,
  cache_static_manifest: "priv/static/cache_manifest.json"

# Darks defaults to monero-wallet-rpc on 18082, but monerod's ZMQ pub
# endpoint already occupies that port on a colocated install. Point
# Darks at our wallet-rpc on 18083 (the monerod Ansible role default).
config :darks, wallet_rpc_url: "http://127.0.0.1:18083"

config :logger, level: :info, utc_log: true

# Structured JSON logging via LoggerJSON 6.x deferred — the new
# `:logger.handlers` API differs from the legacy `backends:` config
# and needs careful migration. Default console logger handles logs
# until structured JSON is reconfigured against the current API.

# Production signing — drives 2-of-3 Monero multisig rounds via
# Cartel + Darks. Dev and test stay on the stub (configured via
# default in PerpWalk.Federation.Signer) so no payout signs unless
# explicitly opted in.
config :perpwalk, :federation_signer, signing_backend: {PerpWalk.Federation.Signing.Monero, :sign}

# Aggressive immutable cache for static assets — safe in prod
# because `mix phx.digest` stamps a content hash into the asset
# path, so a changed file gets a new URL. Dev leaves this nil so
# the browser revalidates via ETag and live-reload works.
config :perpwalk, :static_cache_control, "public, max-age=31536000, immutable"

# Per-mount disk monitoring. Root holds OS housekeeping (logs, packages,
# the LUKS file itself); /data is the LUKS-mounted volume holding the
# pruned Monero chain, multisig wallets, WAL, ETS snapshots, and Cartel
# state. Different failure modes get different thresholds — /data fills
# unpredictably with chain growth and warrants action before critical.
config :perpwalk, :disk_mounts, [
  {"/", %{high: 90, critical: 95}},
  {"/data", %{high: 80, critical: 90}}
]
