defmodule PerpWalk.Application do
  @moduledoc false

  use Application

  alias PerpWalk.Storage.Facade, as: StorageFacade

  require Logger

  @impl true
  def start(_type, _args) do
    assert_release_env!()
    assert_no_peer_nodes_override!()
    StorageFacade.ensure_dirs!()
    check_data_dir!()

    # Boot-owned ETS tables whose lifetime must not track whichever
    # process happens to call in first. The application master lives
    # for the VM's lifetime, so tables created here never die with a
    # LiveView socket, Scheduler, or Replicator restart.
    ensure_boot_owned_tables()

    # Identity.Supervisor MUST start before `replicator_children()` so
    # that `Sessions`'s ETS table is created by (and owned by) the
    # Sessions GenServer. If the Replicator's first tick is the first
    # caller into `Identity.Sessions.replicate_entries/1`, the named
    # ETS table gets created in the Replicator's process; on any
    # subsequent Replicator restart the table dies with it, taking
    # every live session with it.
    # The Replicator runs LAST: under rest_for_one a Replicator
    # crash would otherwise restart telemetry, rate limiting, and
    # both endpoints — turning a replication hiccup into a
    # user-visible flap. Its own apply path contains failures
    # without crashing (dispatch/append errors hold the cursor and
    # retry next tick).
    children =
      [
        {Phoenix.PubSub, name: PerpWalk.PubSub},
        {Task.Supervisor, name: PerpWalk.TaskSupervisor},
        {Finch, name: PerpWalk.Finch, pools: finch_pools()},
        PerpWalk.Storage.Supervisor,
        PerpWalk.Nostr.Supervisor,
        PerpWalk.Monero.Supervisor,
        {Cartel.Supervisor, Application.get_all_env(:cartel)},
        PerpWalk.Markets.Supervisor,
        PerpWalk.Federation.Supervisor,
        PerpWalk.Reserves.Supervisor,
        PerpWalk.Identity.Supervisor
      ] ++
        [
          PerpWalk.Telemetry.Supervisor,
          PerpWalkWeb.Live.RateLimit.Shared,
          PerpWalkWeb.Endpoint,
          PerpWalkAdminWeb.Endpoint
        ] ++
        replicator_children() ++
        extra_children()

    # Explicit restart budget — financial application: 5 restarts
    # in 30 seconds before the supervisor gives up and the OS
    # restarts the BEAM. Sub-supervisors carry their own budgets
    # (Storage / Markets 10/60, Identity 3/10); this caps the root.
    opts = [
      strategy: :rest_for_one,
      name: PerpWalk.Supervisor,
      max_restarts: 5,
      max_seconds: 30
    ]

    Supervisor.start_link(children, opts)
  end

  # Both hot nodes run the Replicator in the symmetric model — each
  # pulls its peers' `:origin == peer_id` entries past the per-peer
  # cursor and applies them locally. No node is "primary"; the WALs
  # converge to the union of all origins' entries.
  #
  # `:replicator_peers` is derived in `runtime.exs` from
  # `PERPWALK_PEER_NODES`. Empty on single-node boots.
  defp replicator_children do
    peers = Application.get_env(:perpwalk, :replicator_peers, [])
    [{PerpWalk.Storage.Replicator, peers: peers}]
  end

  # Env-specific extra children appended to the root supervisor.
  # Set in `config/dev.exs` and `config/test.exs` to wire the sim
  # supervisor in; unset in production so no sim infrastructure
  # boots even if `sim/lib` were ever accidentally included in a
  # release. Production knows nothing about sim — it just appends
  # whatever the config tells it to.
  defp extra_children do
    Application.get_env(:perpwalk, :extra_children, [])
  end

  # `:perpwalk, :env` is captured at compile time from `config_env()`.
  # A release built with `MIX_ENV=dev` would carry dev-grade hardcoded
  # `secret_key_base`, `replication_secret`, and `federation_rpc_secret`
  # from `config/dev.exs` straight into whatever host runs it — and
  # runtime.exs's `if config_env() == :prod` block would also not
  # execute, so the env-var checks that gate production secrets are
  # silently skipped. Detect releases via `RELEASE_NAME` (set by
  # `mix release`) and refuse to start with any `:env` other than
  # `:prod`.
  defp assert_release_env! do
    if System.get_env("RELEASE_NAME") != nil and
         Application.get_env(:perpwalk, :env) != :prod do
      raise """
      Refusing to boot: this is a release but :perpwalk, :env is \
      #{inspect(Application.get_env(:perpwalk, :env))}. Releases must \
      be built with MIX_ENV=prod so non-production placeholder \
      secrets cannot survive into production.\
      """
    end
  end

  # `:peer_nodes_override` is a config seam that lets the Monero
  # signing backend bypass `Cartel.Supervisor.config().peer_nodes` and
  # use a caller-supplied node list instead. If accidentally set in
  # production (config drift, copy-pasted fragment, supply-chain
  # edit), every signing request would route to whatever peers the
  # override names — which could be attacker-controlled. Refuse to
  # boot in production if it is set.
  defp assert_no_peer_nodes_override! do
    override =
      Application.get_env(:perpwalk, :federation, [])
      |> Keyword.get(:peer_nodes_override)

    env = Application.get_env(:perpwalk, :env)

    # Default-deny: any env atom outside the known non-production
    # set refuses to boot with the override set. Inverting the
    # original `== :prod` check this way means a future env atom
    # introduced without updating this gate fails closed rather than
    # silently bypassing the protection.
    if override != nil and env not in [:dev, :test] do
      raise """
      Refusing to boot: :perpwalk, :federation, :peer_nodes_override \
      is set with :perpwalk, :env = #{inspect(env)} (#{inspect(override)}). \
      This config key must be nil in production. Federation peer nodes \
      are resolved from the Federation facade \
      (PerpWalk.Federation.Facade.peer_nodes/0).\
      """
    end
  end

  # Finch is the sole outbound HTTP client (currently the Monero
  # wallet RPC; future Nostr alerting routes through here too). In
  # production, external traffic routes through the Tor HTTP CONNECT
  # tunnel so the guardian's IP is never visible. The wallet
  # RPC is on loopback and MUST NOT go through the tunnel — the Tor
  # proxy's 127.0.0.1 is not our 127.0.0.1. A separate pool for the
  # wallet URL bypasses the proxy while all other requests use the
  # default (proxied) pool.
  #
  # Fail-closed: if :env is :prod and no tor tunnel is configured,
  # boot refuses to proceed.
  defp finch_pools do
    env = Application.get_env(:perpwalk, :env, :dev)
    tunnel = Application.get_env(:perpwalk, :tor_http_tunnel)
    wallet_rpc_url = Application.get_env(:darks, :wallet_rpc_url, "http://127.0.0.1:18082")

    base_opts = [
      transport_opts: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3
      ]
    ]

    case {env, tunnel} do
      {:prod, nil} ->
        raise "PerpWalk: production boot refuses clearnet egress. " <>
                "Set TOR_HTTP_TUNNEL_PORT (and optionally TOR_HTTP_TUNNEL_HOST) " <>
                "to route all outbound HTTP through Tor."

      {_, nil} ->
        %{:default => [conn_opts: base_opts]}

      {_, {host, port}} when is_binary(host) and is_integer(port) ->
        Logger.info("Application: finch routing through tor http tunnel, host=#{host}, port=#{port}")

        pools = %{
          :default => [conn_opts: [proxy: {:http, host, port, []}] ++ base_opts]
        }

        # Only add a direct (non-proxied) pool for the wallet RPC if it's on localhost.
        # Remote wallet RPC (.onion) should go through the Tor proxy like everything else.
        # Parse the URL properly so a hostname like
        # `http://127.0.0.1.attacker.example:18082` can't satisfy a
        # substring match and end up bypassing the Tor pool.
        if loopback_wallet_url?(wallet_rpc_url) do
          Map.put(pools, wallet_rpc_url, conn_opts: base_opts)
        else
          pools
        end
    end
  end

  defp loopback_wallet_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when host in ["127.0.0.1", "localhost", "::1"] -> true
      _ -> false
    end
  end

  defp loopback_wallet_url?(_), do: false

  # Verifies the base data directory is writable and locks it down
  # to owner-only (0o700). Catches deploys where the systemd unit
  # runs as a user without write access to PERPWALK_DATA_DIR before
  # the WAL machinery tries to append. Raises in production; warns
  # in non-production environments where `/tmp` semantics may not
  # warrant a hard fail.
  defp check_data_dir! do
    dir = StorageFacade.base_dir()
    env = Application.get_env(:perpwalk, :env, :dev)
    probe = Path.join(dir, ".startup_probe")

    result =
      with :ok <- File.write(probe, "ok"),
           {:ok, "ok"} <- File.read(probe),
           :ok <- File.rm(probe) do
        File.chmod(dir, 0o700)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} when env == :prod ->
        raise "Data directory #{dir} is not writable or could not be secured: #{inspect(reason)}"

      {:error, reason} ->
        Logger.warning("Application: data directory probe failed, reason=#{inspect(reason)}")
    end
  end

  # Creates ETS tables that must be owned by a process that never
  # dies. Lazy creation means the table is owned by whichever process
  # calls in first — a LiveView socket, Scheduler tick, or Replicator
  # — and dies with it, silently wiping the halt registry.
  defp ensure_boot_owned_tables do
    # The halt registry behind Guards.ensure_operational!/0 —
    # per-source halts (replication-signature tripwire, WAL replay
    # failures, halt-file errors). The lazy fallback in
    # Telemetry.Health.System covers standalone boots where this
    # application callback never ran.
    case :ets.whereis(:perpwalk_health_source_halts) do
      :undefined ->
        :ets.new(:perpwalk_health_source_halts, [
          :set,
          :public,
          :named_table,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])

      _ref ->
        :ok
    end
  end

  @doc """
  Tells Phoenix to update the endpoint configuration whenever the
  application is updated.
  """
  @impl true
  def config_change(changed, _new, removed) do
    PerpWalkWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
