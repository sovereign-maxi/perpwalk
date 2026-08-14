import Config

# Runtime configuration loaded at boot from environment variables.
# All required env vars MUST be checked here so the app fails fast at
# boot rather than at first use.

# --- Data directory ---

if data_dir = System.get_env("PERPWALK_DATA_DIR") do
  config :perpwalk, :data_dir, data_dir
end

# --- At-rest encryption ---

if key = System.get_env("PERPWALK_ENCRYPTION_KEY") do
  config :perpwalk, :encryption_key, key
end

# --- Monero network ---
#
# PERP WALK runs against one Monero network at a time. The active
# network drives address validation (mainnet/stagenet/testnet have
# distinct address prefixes) and may eventually drive confirmation
# thresholds, block-explorer URLs, and other surfaces. Selected at
# boot from PERPWALK_NETWORK; defaults to :mainnet when unset.

network =
  case System.get_env("PERPWALK_NETWORK") do
    "stagenet" -> :stagenet
    "testnet" -> :testnet
    _ -> :mainnet
  end

config :perpwalk, :network, network

# --- Production-only required env ---

if config_env() == :prod do
  # Sanity assertion: `:perpwalk, :env` MUST be `:prod` here. Various
  # defence-in-depth plugs (e.g. `PerpWalkAdminWeb.Plugs.OnionOnly`)
  # consult this value at runtime to decide whether to enforce host
  # checks. A misconfigured runtime.exs override (or future code that
  # mutates it) silently turns those defences off. Fail fast at boot
  # so the misconfig surfaces as "service refused to start", not as
  # "admin onion accepts any host header".
  case Application.get_env(:perpwalk, :env) do
    :prod ->
      :ok

    other ->
      raise """
      :perpwalk, :env is #{inspect(other)} in a production release.
      Expected :prod. Refusing to boot — env-gated defences (OnionOnly,
      tor-only checks) would silently no-op.
      """
  end

  # SECRET_KEY_BASE — Phoenix session/CSRF signing. Applied to
  # both endpoints so the dev placeholder cannot survive into a
  # prod release.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE environment variable is required in production"

  # PORT / ADMIN_PORT — listener ports. Defaults match config.exs
  # (4000 user, 4001 admin); Ansible can override per host.
  port = String.to_integer(System.get_env("PORT") || "4000")
  admin_port = String.to_integer(System.get_env("ADMIN_PORT") || "4001")

  # TOR_ONION_HOSTNAME / TOR_ADMIN_ONION_HOSTNAME — the .onion
  # hostnames the endpoints expect to be reached through. Both
  # endpoints bind to loopback and are exposed by Tor's
  # HiddenServicePort mapping; pinning the hosts here gates
  # LiveView WebSocket origin checks (`check_origin`) and the
  # admin endpoint's `OnionOnly` plug. Without this wiring,
  # `check_origin` would default to comparing against
  # `url: [host: "localhost"]` from `config.exs` — fine for HTTP
  # but breaks .onion sessions and weakens CSRF protection on
  # cross-origin WebSocket handshakes.
  # Tor-only: both user and admin endpoints serve `.onion` hidden
  # services. See project_perp_walk_admin_tor_only.
  user_onion =
    System.get_env("TOR_ONION_HOSTNAME") ||
      raise "TOR_ONION_HOSTNAME environment variable is required in production"

  admin_onion =
    System.get_env("TOR_ADMIN_ONION_HOSTNAME") ||
      raise "TOR_ADMIN_ONION_HOSTNAME environment variable is required in production"

  # `check_origin` pins each endpoint's WebSocket handshake to the
  # exact .onion host its users reach it through. The Phoenix
  # `:conn` shorthand only compares against the *current* request's
  # host, which a direct loopback caller can spoof via a forged
  # Host header; the explicit list below is true cross-origin
  # protection. The HiddenServicePort mapping makes both endpoints
  # appear at HTTP scheme on the .onion despite TLS-equivalent
  # encryption inside the Tor circuit.
  # PHX_SERVER — gates the endpoint acceptors at runtime. Followers
  # (custody-only nodes) set this to false: they participate in the
  # federation mesh and replicate the WAL but do not serve user
  # traffic. `prod.exs` sets `server: true` at compile time; this
  # block overrides at boot when PHX_SERVER says otherwise.
  phx_server = System.get_env("PHX_SERVER", "true") == "true"

  # `compress: true` on the http opts is Plug.Cowboy's shorthand for
  # prepending `:cowboy_compress_h` to the default stream handlers.
  # That gives us gzip/deflate on dynamic HTML responses (first paint,
  # full LiveView mounts, controller renders) — the second-biggest
  # bandwidth saving on a Tor venue after WebSocket compression. Static
  # assets are precompressed via Plug.Static's `gzip:` flag, so this
  # only applies to dynamic responses.
  config :perpwalk, PerpWalkWeb.Endpoint,
    server: phx_server,
    http: [ip: {127, 0, 0, 1}, port: port, compress: true],
    url: [host: user_onion, scheme: "http"],
    check_origin: ["http://#{user_onion}"],
    secret_key_base: secret_key_base

  config :perpwalk, PerpWalkAdminWeb.Endpoint,
    server: phx_server,
    http: [ip: {127, 0, 0, 1}, port: admin_port, compress: true],
    url: [host: admin_onion, scheme: "http"],
    check_origin: ["http://#{admin_onion}"],
    secret_key_base: secret_key_base

  # OnionOnly plug consults `:tor_hostnames` to verify the Host
  # header matches the configured admin .onion exactly.
  config :perpwalk, :tor_hostnames, %{user: user_onion, admin: admin_onion}

  # TOR_HTTP_TUNNEL_HOST / TOR_HTTP_TUNNEL_PORT — outbound HTTP
  # must route through Tor. Configured on the Tor side via
  # HTTPTunnelPort in torrc; consumed by `PerpWalk.Application`
  # when it builds the `PerpWalk.Finch` pools. Production refuses
  # to boot without the port — shipping clearnet outbound would
  # deanonymize the federation node on every wallet RPC call.
  tor_tunnel_host = System.get_env("TOR_HTTP_TUNNEL_HOST") || "127.0.0.1"

  tor_tunnel_port =
    System.get_env("TOR_HTTP_TUNNEL_PORT") ||
      raise "TOR_HTTP_TUNNEL_PORT environment variable is required in production. " <>
              "Refusing to boot — production must not make clearnet HTTP calls."

  config :perpwalk,
         :tor_http_tunnel,
         {tor_tunnel_host, String.to_integer(tor_tunnel_port)}

  # Per-host label surfaced in Nostr alert prefixes so a single
  # operator client can distinguish prod (N1/N2/N3) from staging
  # (S1/S2/S3) at a glance. Ansible derives the value from the
  # inventory hostname suffix; unset falls back to `N<cartel node_id>`
  # inside the publisher for backward compatibility.
  if node_label = System.get_env("NODE_LABEL") do
    config :perpwalk, :node_label, node_label
  end

  # NOSTR_RELAYS — comma-separated list of `wss://` relay URLs.
  # Drives both outbound (market lifecycle publisher, reserve-proof
  # publisher, user comment fan-out via Composer) and inbound
  # (Nostr.Relay.Subscriber pool that feeds Comments.Inbox). Every
  # WS connection routes through TOR_HTTP_TUNNEL_PORT — there is no
  # clearnet egress path for relay traffic.
  #
  # Empty / unset is non-fatal: the venue still serves markets and
  # signs / verifies comments locally, but neither distributes nor
  # ingests over the network. We log a warning rather than raise
  # so an operator can boot a fresh node without relays for sanity
  # checks before opening the firehose.
  #
  # Each entry is validated to start with `wss://` — Nostr is
  # WebSocket-only and the Tor tunnel publisher / subscriber only
  # ever speak TLS. Malformed entries are skipped with a logged
  # warning rather than crashing the release.
  nostr_relays =
    case System.get_env("NOSTR_RELAYS") do
      nil ->
        []

      "" ->
        []

      csv ->
        csv
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.filter(fn url ->
          if String.starts_with?(url, "wss://") do
            true
          else
            IO.warn("NOSTR_RELAYS: ignoring non-wss:// entry #{inspect(url)}")
            false
          end
        end)
    end

  if nostr_relays == [] do
    IO.warn(
      "NOSTR_RELAYS is empty in production — venue will not distribute or ingest " <>
        "Nostr events. Set NOSTR_RELAYS to a comma-separated list of wss:// URLs."
    )
  end

  config :perpwalk, :nostr_relays, nostr_relays

  # NOSTR_OPERATOR_PUBKEY — 64-char hex x-only pubkey of the operator
  # Nostr identity that receives encrypted alert DMs (NIP-17 gift-
  # wrapped). A single operator npub can receive alerts from every
  # venue the operator runs by reusing this env var name across
  # products — no account switching needed. Unset is non-fatal: the
  # publisher logs a warning and stays subscribed-but-silent until
  # the variable is populated.
  nostr_operator_pubkey =
    case System.get_env("NOSTR_OPERATOR_PUBKEY") do
      nil ->
        nil

      "" ->
        nil

      hex when is_binary(hex) ->
        String.trim(hex)
    end

  # NOSTR_ALERT_SEVERITIES — comma-separated list of severities to
  # publish, e.g. "emergency,critical,warning". Defaults to that
  # set. Set to e.g. "critical,emergency" to suppress warnings
  # during a noisy window without taking the publisher down.
  nostr_alert_severities =
    case System.get_env("NOSTR_ALERT_SEVERITIES") do
      nil ->
        [:emergency, :critical, :warning]

      "" ->
        [:emergency, :critical, :warning]

      csv ->
        csv
        |> String.split(",", trim: true)
        |> Enum.map(&(&1 |> String.trim() |> String.downcase() |> String.to_atom()))
        |> Enum.filter(&(&1 in [:emergency, :critical, :warning, :info]))
    end

  # HEARTBEAT_ENABLED (default true) + HEARTBEAT_INTERVAL_HOURS (default 24)
  # control the periodic proof-of-life DM. Absence of the expected heartbeat
  # is a signal something is wrong, so keep it enabled unless you have a
  # specific reason to disable.
  heartbeat_enabled =
    case System.get_env("HEARTBEAT_ENABLED") do
      "false" -> false
      "0" -> false
      _ -> true
    end

  heartbeat_interval_hours =
    case Integer.parse(System.get_env("HEARTBEAT_INTERVAL_HOURS") || "24") do
      {h, ""} when h > 0 and h <= 168 -> h
      _ -> 24
    end

  config :perpwalk, :nostr,
    relays: nostr_relays,
    operator_pubkey: nostr_operator_pubkey,
    alert_severities: nostr_alert_severities,
    heartbeat: [
      enabled: heartbeat_enabled,
      interval_ms: heartbeat_interval_hours * 60 * 60 * 1000
    ]

  # PERPWALK_ENCRYPTION_KEY — at-rest encryption master key.
  # Must be at least 32 bytes; shorter inputs would be HKDF-derived
  # to a 32-byte AES key but the effective key strength would
  # collapse to whatever entropy the operator typed. Match the same
  # floor used by the replication and federation RPC secrets so
  # operator memory is consistent across the three.
  case System.get_env("PERPWALK_ENCRYPTION_KEY") do
    nil ->
      raise "PERPWALK_ENCRYPTION_KEY environment variable is required in production"

    s when byte_size(s) < 32 ->
      raise "PERPWALK_ENCRYPTION_KEY must be at least 32 bytes"

    _ ->
      :ok
  end

  # PERPWALK_REPLICATION_SECRET — HMAC key for inter-node WAL
  # replication RPC. Must match across every node in the federation
  # so leader and follower sign and verify with the same key.
  case System.get_env("PERPWALK_REPLICATION_SECRET") do
    nil ->
      raise "PERPWALK_REPLICATION_SECRET environment variable is required in production"

    s when byte_size(s) < 32 ->
      raise "PERPWALK_REPLICATION_SECRET must be at least 32 bytes"

    s ->
      config :perpwalk, :replication_secret, s
  end

  # PERPWALK_FEDERATION_RPC_SECRET — HMAC key for inter-guardian
  # Monero signing RPC. Must match across every guardian node.
  # Distinct from replication_secret so a leak of one cannot drain
  # the other.
  case System.get_env("PERPWALK_FEDERATION_RPC_SECRET") do
    nil ->
      raise "PERPWALK_FEDERATION_RPC_SECRET environment variable is required in production"

    s when byte_size(s) < 32 ->
      raise "PERPWALK_FEDERATION_RPC_SECRET must be at least 32 bytes"

    s ->
      config :perpwalk, :federation_rpc_secret, s
  end

  # PERPWALK_RESERVES_GUARDIAN_PUBKEYS — Ed25519 pubkeys of the
  # federation guardians that may sign proof-of-reserves
  # attestations. Comma-separated hex, one entry per guardian
  # (typically 3). The Reserves.Attestation.Collector pins accepted
  # attestations to this set — a compromised peer generating
  # additional keypairs cannot inflate `attestation_count` to fake
  # the 2-of-3 quorum without a pinned pubkey.
  #
  # An empty / unset registry silently disables pinning (the
  # dev-mode escape hatch inside the Collector); refuse to boot in
  # prod without it.
  case System.get_env("PERPWALK_RESERVES_GUARDIAN_PUBKEYS") do
    nil ->
      raise """
      PERPWALK_RESERVES_GUARDIAN_PUBKEYS environment variable is required in production.
      Comma-separated hex-encoded Ed25519 pubkeys (32 bytes each) of every
      guardian in the federation registry. Without this, Reserves attestation
      pinning is disabled and a compromised peer can mint extra keypairs to
      fake the 2-of-3 quorum.
      """

    s when byte_size(s) == 0 ->
      raise "PERPWALK_RESERVES_GUARDIAN_PUBKEYS must not be empty in production"

    s ->
      pubkeys =
        s
        |> String.split(",", trim: true)
        |> Enum.map(fn hex ->
          case Base.decode16(String.trim(hex), case: :mixed) do
            {:ok, <<_::binary-size(32)>> = key} ->
              key

            _ ->
              raise """
              PERPWALK_RESERVES_GUARDIAN_PUBKEYS entry is not a 32-byte hex-encoded pubkey: #{inspect(hex)}
              """
          end
        end)

      existing = Application.get_env(:perpwalk, :reserves, [])
      config :perpwalk, :reserves, Keyword.put(existing, :guardian_pubkeys, pubkeys)
  end

  # PERPWALK_DATA_DIR — base directory for all on-disk state.
  # Required in production: Storage.Paths, Reserves, Identity, and
  # Cartel's data_dir are all derived from it. Releasing against the
  # bare default of "data/" leaves files in the working directory,
  # which is service-runtime-dependent.
  data_dir =
    System.get_env("PERPWALK_DATA_DIR") ||
      raise "PERPWALK_DATA_DIR environment variable is required in production"

  config :perpwalk, :data_dir, data_dir

  # Market economics dials — tune the creator's deposit bounds and AMM
  # unit-size per deployment. Compile-time defaults (1 / 100 / 0.01 XMR)
  # target mainnet. Staging typically drops all three to fit stagenet
  # faucet cadence. Deposits fall back to min when the caller omits an
  # amount; Maker.ex enforces deposit ∈ [min, max] and deposit %
  # unit_size == 0 at create time.
  put_piconeros = fn acc, key, env ->
    case System.get_env(env) do
      s when is_binary(s) and s != "" -> [{key, String.to_integer(s)} | acc]
      _ -> acc
    end
  end

  markets_config =
    []
    |> put_piconeros.(:min_deposit_piconeros, "PERPWALK_MIN_DEPOSIT_PICONEROS")
    |> put_piconeros.(:max_deposit_piconeros, "PERPWALK_MAX_DEPOSIT_PICONEROS")
    |> put_piconeros.(:unit_size_piconeros, "PERPWALK_UNIT_SIZE_PICONEROS")
    |> put_piconeros.(:deposit_step_piconeros, "PERPWALK_DEPOSIT_STEP_PICONEROS")

  if markets_config != [] do
    config :perpwalk, :markets, markets_config
  end

  # PERPWALK_MULTISIG_ADDRESS — pinned shared address produced by the
  # bootstrap ceremony. Vaulted, rendered into env. Federation.Facade
  # checks the wallet's `get_address` against this at boot — a
  # mismatch means wallet-rpc opened the wrong wallet (or a tampered
  # one) and the operator must intervene. Optional: unset until the
  # ceremony has run. Empty string is treated as unset because the env
  # template always emits the line (with empty value) before bootstrap.
  case System.get_env("PERPWALK_MULTISIG_ADDRESS") do
    addr when addr in [nil, ""] -> :ok
    addr -> config :perpwalk, :multisig_address, addr
  end

  # --- Cartel federation runtime config ---
  #
  # Cartel.Supervisor reads `:cartel` app config to build its Config
  # struct at boot. The dev/test single-node defaults from config.exs
  # (n=1, t=1, node_id=1) are overridden here with the production
  # topology. Missing or malformed entries raise — production must
  # not boot into a federation it cannot describe.

  cartel_node_id =
    System.get_env("PERPWALK_NODE_ID") ||
      raise "PERPWALK_NODE_ID environment variable is required in production"

  # NODE_LABEL carries the environment prefix (`N` prod / `S` staging)
  # plus the node index (`1`/`2`/`3`) — set by Ansible from the
  # inventory hostname suffix. Required in prod for the participant
  # atom and peer-origin derivations below.
  node_label =
    System.get_env("NODE_LABEL") ||
      raise "NODE_LABEL environment variable is required in production"

  # `PerpWalk.Role.participant_id/0` reads `:perpwalk, :participant_id`
  # to stamp WAL entries with their originating node and to gate the
  # designated-processor code paths (Monero credit writes, payout
  # signing-loop drive). Derived from NODE_LABEL so staging federations
  # stamp `:s1`/`:s2`/`:s3` and prod stamps `:p1`/`:p2`/`:p3` — the
  # WAL origin is legible at a glance and can never collide across envs.
  config :perpwalk, :participant_id, :"#{String.downcase(node_label)}"

  cartel_n =
    System.get_env("PERPWALK_FEDERATION_N") ||
      raise "PERPWALK_FEDERATION_N environment variable is required in production"

  cartel_t =
    System.get_env("PERPWALK_FEDERATION_T") ||
      raise "PERPWALK_FEDERATION_T environment variable is required in production"

  # PERPWALK_NODE_PASSPHRASE — per-guardian passphrase for Cartel key
  # derivation. Each guardian MUST have a unique passphrase; Cartel
  # derives the signing + encryption keys via PBKDF2 (600K iterations)
  # then discards the raw passphrase. This env var is the only
  # ingress point for the secret. Env-var name mirrors Cartel's
  # upstream `:node_passphrase` config key (per AGENT.md rulebook
  # rule 7: pass-through env vars mirror the primitive's naming).
  cartel_node_passphrase =
    case System.get_env("PERPWALK_NODE_PASSPHRASE") do
      nil ->
        raise "PERPWALK_NODE_PASSPHRASE environment variable is required in production"

      s when byte_size(s) < 32 ->
        raise "PERPWALK_NODE_PASSPHRASE must be at least 32 bytes (256 bits)"

      s ->
        s
    end

  # PERPWALK_PEER_NODES — comma-separated `id=nodename` entries for
  # the OTHER federation peers. Cartel uses these atoms for BEAM
  # distribution routing.
  #
  # Format: "2=perpwalk@10.0.0.2,3=perpwalk@10.0.0.3"
  cartel_peer_nodes =
    case System.get_env("PERPWALK_PEER_NODES") do
      nil ->
        raise "PERPWALK_PEER_NODES environment variable is required in production"

      raw ->
        raw
        |> String.split(",", trim: true)
        |> Map.new(fn entry ->
          case String.split(entry, "=", parts: 2) do
            [id_str, node_str] ->
              {String.to_integer(id_str), String.to_atom(node_str)}

            _ ->
              raise "PERPWALK_PEER_NODES entry must be 'id=nodename', got: #{inspect(entry)}"
          end
        end)
    end

  # PERPWALK_PEER_PUBLIC_KEYS — comma-separated `id=hex64` entries
  # for each peer's Ed25519 public key (32 bytes, hex-encoded).
  # Exchanged out-of-band during federation setup. Cartel validates
  # length and refuses to boot on mismatch.
  #
  # Format: "2=ab12...64chars,3=cd34...64chars"
  cartel_peer_public_keys =
    case System.get_env("PERPWALK_PEER_PUBLIC_KEYS") do
      nil ->
        raise "PERPWALK_PEER_PUBLIC_KEYS environment variable is required in production"

      raw ->
        raw
        |> String.split(",", trim: true)
        |> Map.new(fn entry ->
          case String.split(entry, "=", parts: 2) do
            [id_str, hex_key] ->
              id = String.to_integer(id_str)

              case Base.decode16(hex_key, case: :mixed) do
                {:ok, key_bin} when byte_size(key_bin) == 32 ->
                  {id, key_bin}

                _ ->
                  raise "PERPWALK_PEER_PUBLIC_KEYS[#{id}] must be a 32-byte hex-encoded Ed25519 public key"
              end

            _ ->
              raise "PERPWALK_PEER_PUBLIC_KEYS entry must be 'id=hex_key', got: #{inspect(entry)}"
          end
        end)
    end

  # Cartel.Cluster consumes `:peers` (list of atoms) to drive
  # `Node.connect/1`; Cartel.Config consumes `:peer_nodes` (map of
  # id → atom) for transport routing. The list and the map are
  # the same set of peers in two shapes.
  cartel_peers = Map.values(cartel_peer_nodes)

  # `PerpWalk.Storage.Replicator` pulls each peer's `:origin == peer_id`
  # WAL entries past the local cursor. The Replicator's peer schema
  # pairs the perpwalk-domain origin atom with the BEAM node name it
  # RPCs into. All peers in a federation share the local node's env
  # prefix (`n` prod / `s` staging) — federations don't span prod and
  # staging — so we combine the local prefix with each peer's integer id.
  peer_prefix = String.downcase(String.first(node_label))

  replicator_peers =
    Enum.map(cartel_peer_nodes, fn {id, node} ->
      %{origin: :"#{peer_prefix}#{id}", node: node}
    end)

  config :perpwalk, :replicator_peers, replicator_peers

  config :cartel,
    n: String.to_integer(cartel_n),
    t: String.to_integer(cartel_t),
    node_id: String.to_integer(cartel_node_id),
    node_passphrase: cartel_node_passphrase,
    peers: cartel_peers,
    peer_nodes: cartel_peer_nodes,
    peer_public_keys: cartel_peer_public_keys,
    data_dir: Path.join(data_dir, "cartel")
end
