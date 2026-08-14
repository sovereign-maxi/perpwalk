import Config

config :logger, level: :debug

# Stable dev passphrase so KeyStore-encrypted data persists across
# restarts. Production sets this via runtime env. The 32-byte minimum
# is a Cartel.Config validation requirement.
config :cartel,
  node_passphrase: "perpwalk-dev-cartel-passphrase-stable-across-runs"

# User-facing endpoint — dev runs the server with code reloading
config :perpwalk, PerpWalkWeb.Endpoint,
  server: true,
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  secret_key_base: "dev_secret_key_base_dev_only_64_chars_xxxxxxxxxxxxxxxxxxxxxxxxxx",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:perpwalk, ~w(--minify --sourcemap=inline --watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/perp_walk_web/(controllers|live|components|layouts)/.*(ex|heex)$"
    ]
  ]

# Admin endpoint — same dev conveniences (server + reloader), bound
# to a separate port so both surfaces are reachable locally.
config :perpwalk, PerpWalkAdminWeb.Endpoint,
  server: true,
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  secret_key_base: "dev_secret_key_base_dev_only_64_chars_xxxxxxxxxxxxxxxxxxxxxxxxxx",
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/perp_walk_admin_web/(live|components|layouts)/.*(ex|heex)$"
    ]
  ]

# Sim/dev subaddress provider so the Trade panel renders without
# a live `monero-wallet-rpc`. Returns a deterministic-but-unique
# stub address each call, valid against the
# `Federation.Rules.destination_sanity` regex. Lives in `sim/lib`
# (excluded from `:prod` elixirc_paths). Production uses
# `PerpWalk.Monero.Facade.create_subaddress/0` (the default when
# this key is unset).
config :perpwalk,
       :subaddress_provider,
       {PerpWalk.Sim.Subaddresses, :next, []}

# Sim infrastructure (subaddress allocator, metrics, event-driven
# invariants) appended as the final root-supervisor child. Lives in
# `sim/lib/` and is excluded from `:prod` elixirc_paths, so this
# config key is intentionally only set in non-prod environments.
config :perpwalk, :extra_children, [PerpWalk.Sim.Supervisor]

# Dev replication HMAC secret — stable string so a 3-node dev
# cluster started locally can replicate without coordination.
# Production sets this via PERPWALK_REPLICATION_SECRET in runtime.exs.
config :perpwalk,
       :replication_secret,
       "dev-replication-secret-stable-across-runs-32+++bytes-padding"

# Dev inter-guardian RPC secret — same stability rationale. Distinct
# from replication_secret so a leak doesn't compromise both planes.
config :perpwalk,
       :federation_rpc_secret,
       "dev-federation-rpc-secret-stable-across-runs-32+++bytes-pad"

# Dev boots against on-disk WAL that may carry corrupt entries from
# previous experiments. Production halts on corruption; dev tolerates
# it so the shell stays usable while the operator triages.
config :perpwalk, :wal, halt_on_corrupt: false
