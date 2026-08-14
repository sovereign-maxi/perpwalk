import Config

config :perpwalk, env: config_env()

# Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Phoenix's default request logger emits `Parameters: %{...}` at INFO
# on every controller dispatch with `[\"password\"]` as the only filter.
# PERP WALK's auth uses a `keyphrase` field that is the credential AND
# the account id; logging it once anywhere is irreversible takeover.
# Dropping the params line entirely is the only safe posture for an
# anonymous Tor-only platform — we don't want IPs, headers, or any
# request shape leaking to disk either.
config :phoenix, :filter_parameters, {:keep, []}

# Monero wallet RPC — see darks for full surface. Default points at
# the local monerod-wallet-rpc bound to loopback; production overrides
# via runtime config (or an Ansible-rendered prod.exs) on the
# wallet host.
config :darks,
  wallet_rpc_url: "http://127.0.0.1:18082",
  finch_name: PerpWalk.Finch

# Federation runtime via Cartel. PERP WALK runs in :none signing-backend
# mode — Cartel provides the cluster mesh, encrypted KeyStore, signed
# transport, and peer health monitoring; signing happens via
# Darks.Multisig (Monero native) in PerpWalk.Federation.Signer.
#
# Production overrides n=3, t=2, node_id, peers, peer_public_keys, and
# node_passphrase via Ansible-rendered runtime config. Single-node
# defaults here let dev/test boot without coordinating peers.
config :cartel,
  product_module: PerpWalk.Federation.Product,
  n: 1,
  t: 1,
  node_id: 1,
  data_dir: "data/cartel"

# Esbuild — JS bundling (standalone binary, no node.js required)
config :esbuild,
  version: "0.21.5",
  perpwalk: [
    args: ~w(js/app.js --bundle --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# User-facing endpoint — markets UI + LiveView (port 4000)
config :perpwalk, PerpWalkWeb.Endpoint,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  render_errors: [
    formats: [html: PerpWalkWeb.ErrorHTML, json: PerpWalkWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: PerpWalk.PubSub,
  live_view: [signing_salt: "perpwalk_lv"],
  server: false,
  drainer: [shutdown: 30_000]

# Admin endpoint — read-only operator dashboard (port 4001).
# Bound to its own .onion in production. No write endpoints.
config :perpwalk, PerpWalkAdminWeb.Endpoint,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4001],
  render_errors: [
    formats: [html: PerpWalkWeb.ErrorHTML, json: PerpWalkWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: PerpWalk.PubSub,
  live_view: [signing_salt: "perpwalk_admin_lv"],
  server: false,
  drainer: [shutdown: 30_000]

import_config "#{config_env()}.exs"
