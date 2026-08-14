import Config

config :logger, level: :warning

# Tests don't need Argon2id brute-force resistance; they need
# speed. Locksmith.Key reads these opts at hash time, so
# overriding here drops per-derivation cost from ~500ms to
# ~5ms. Production defaults are in Locksmith.Key itself.
config :locksmith, :argon2_opts,
  t_cost: 1,
  m_cost: 12,
  parallelism: 1,
  hashlen: 32,
  format: :raw_hash,
  argon2_type: 2

# Tests do not start the web endpoint
config :perpwalk, PerpWalkWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4202],
  secret_key_base: "test_secret_key_base_test_only_64_chars_yyyyyyyyyyyyyyyyyyyyyyyyy",
  server: false

config :perpwalk, PerpWalkAdminWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4203],
  secret_key_base: "test_secret_key_base_test_only_64_chars_yyyyyyyyyyyyyyyyyyyyyyyyy",
  server: false

# Effectively never tick automatically — tests drive the scheduler
# explicitly via Markets.Scheduler.run_now/0 to keep them deterministic.
config :perpwalk, :markets_scheduler,
  tick_interval_ms: 3_600_000,
  pending_window_seconds: 86_400,
  # dispute_window_seconds: 0 disables the settle-time gate for
  # tests that immediately settle after submit_resolution. Individual
  # tests exercising the dispute-window enforcement path override
  # this via Application.put_env per test.
  dispute_window_seconds: 0,
  auto_void_grace_seconds: 86_400

# Pool depth is derived from `deposit / unit_size` under the LP-
# capital model. 1 XMR deposit ÷ 0.01 XMR unit_size = 100/100 depth,
# which is what the AMM tests + fixtures assume. Unit size + resolution
# window match production defaults so test economics aren't off by an
# order of magnitude.
config :perpwalk, :markets,
  unit_size_piconeros: 10_000_000_000,
  resolution_window_seconds: 86_400

# Tests don't want a live wallet poll loop — the Poller's logic is
# exercised by sending it messages directly via handle_info, with
# start_darks: false to skip the embedded Darks.Poller.
config :perpwalk, :monero_poller, enabled: false

# Tests don't want a live multisig sync loop — no wallet RPC, no
# federation peers. Exercise the sync logic directly via the
# `Monero.Multisig.Sync` API in tests.
config :perpwalk, :monero, multisig_scheduler_enabled: false

# Test env writes under the OS tmp dir so each session begins from
# zero — no replayed WAL entries, no accumulated DETS state, no
# Cartel key shares left over. Wiping at config-load time (before
# the application boots) means the storage Supervisor's ensure_dirs!
# call lands in a fresh tree. With a clean slate every run we keep
# prod's `halt_on_corrupt: true` posture instead of hiding bugs
# behind a tolerant WAL replay.
test_tmp = Path.join(System.tmp_dir!(), "perpwalk_test")
File.rm_rf!(test_tmp)
File.mkdir_p!(test_tmp)

config :perpwalk, :data_dir, Path.join(test_tmp, "perpwalk")

config :cartel,
  node_passphrase: "perpwalk-test-cartel-passphrase-deterministic!",
  data_dir: Path.join(test_tmp, "cartel")

# Federation Signer ticks effectively never in tests — tests
# drive ticks via Federation.Signer.run_now/0 for determinism.
config :perpwalk, :federation_signer, tick_interval_ms: 3_600_000

# Replication HMAC shared secret — fixed string for tests so
# every node in a test run signs and verifies with the same key.
config :perpwalk,
       :replication_secret,
       "test-replication-secret-please-do-not-use-in-production-32++chars"

# Inter-guardian RPC HMAC shared secret — different from
# replication_secret on purpose. A leak of one must not compromise
# the other.
config :perpwalk,
       :federation_rpc_secret,
       "test-federation-rpc-secret-please-do-not-use-in-production-32++"

# Storage Checkpointer effectively never ticks in tests — tests
# drive checkpoints via Storage.Checkpointer.run_now/0 for determinism.
config :perpwalk, :storage_checkpointer, interval_ms: 3_600_000

# Telemetry alert evaluator effectively never ticks in tests. The
# default 15s tick fires alerts mid-suite based on fixture state
# (orphan deposits, bootstrap mismatches, etc.) and leaks active
# alerts into later tests asserting an empty dashboard. Alert tests
# drive evaluation explicitly.
config :perpwalk, :telemetry, alert_interval_ms: 3_600_000

# Sim infrastructure under one supervisor so sim unit tests
# (`Metrics`, `Subaddresses`) and any test that exercises the
# event-driven invariants find their dependencies running.
config :perpwalk, :extra_children, [PerpWalk.Sim.Supervisor]

# Inbox unit tests drive `ingest/1` with synthetic market_ids that
# don't exist in `Markets.Store`. Disable the production existence
# check; an explicit integration test asserts the production-mode
# behaviour separately.
config :perpwalk, :inbox, require_market_existence: false
