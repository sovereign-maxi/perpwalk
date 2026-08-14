defmodule PerpWalk.Sim.Boot do
  @moduledoc """
  Shared boot helpers for the sim Mix tasks (`sim.events`,
  `sim.hammer`, and any future scenario driver).

  The sim owns three responsibilities before the application
  starts:

  1. Wipe the on-disk data directory so prior-run WAL entries
     and DETS state don't leak into the fresh run.
  2. Disable both Phoenix HTTP endpoints (user-facing and admin)
     plus their esbuild watchers, LiveReload watchers, and code
     reloader so the sim task doesn't spin up web servers, rebuild
     static assets, or race with dev filesystem watchers.
  3. Install sim-mode overrides on the neutral config seams
     prod exposes (reserves source, federation signing backend).

  Extracted so the two Mix tasks don't duplicate the sequence.

  CRITICAL: callers must invoke `prepare!/0` BEFORE any
  `Mix.Task.run("app.start")` or `Application.ensure_all_started/1`.
  Booting the app first means the endpoints, esbuild watchers, and
  production signing backend all start up with prod defaults, leak
  TIME_WAIT ports + orphaned persistent_term entries + WAL entries
  written by production-backend failure paths, and pollute every
  subsequent sim run.
  """

  # --- Public API ---

  @doc """
  Runs the full pre-`app.start` sequence:

      wipe_data_dir!()
      suppress_web_endpoints!()
      install_overrides!()

  Callers still invoke `Mix.Task.run("app.start")` themselves —
  this helper stops just short of booting so the caller controls
  timing (e.g. tests that want to swap additional config first).
  """
  @spec prepare!() :: :ok
  def prepare! do
    wipe_data_dir!()
    suppress_web_endpoints!()
    install_overrides!()
    :ok
  end

  @doc """
  Removes the data directory the app boots against so prior WAL
  entries, DETS orphan records, and reserves proof history don't
  bleed into the fresh sim run.

  Resolves the data directory the SAME way the running app does:
  `Application.get_env(:perpwalk, :data_dir)`, which `runtime.exs`
  populates from `PERPWALK_DATA_DIR` at boot. Falls back to the env
  var directly for the case where the app is stopped and its env
  may have been unloaded.

  Safety: refuses to wipe values that could destroy the host
  filesystem (`nil`, empty string, `/`, `.`). The earlier "must be
  inside cwd" check silently no-op'd on production hardware where
  `PERPWALK_DATA_DIR` is an absolute path outside the working tree
  — which caused sim runs to accumulate stale WAL, DETS, and
  reserves state across the entire tier progression. If you're
  reading this and considering re-adding a cwd check, don't.
  """
  @spec wipe_data_dir!() :: :ok
  def wipe_data_dir! do
    dir =
      Application.get_env(:perpwalk, :data_dir) ||
        System.get_env("PERPWALK_DATA_DIR") ||
        "data"

    if dir in [nil, "", "/", "."] do
      raise "Boot.wipe_data_dir!: refusing to wipe data_dir=#{inspect(dir)}"
    end

    if File.exists?(dir) do
      require Logger
      Logger.info("Boot: wiping data_dir=#{dir}")
      File.rm_rf!(dir)
    end

    :ok
  end

  @doc """
  Disables both Phoenix HTTP endpoints and clears every dev-mode
  supervision knob that would otherwise stand up ports, filesystem
  watchers, or asset-rebuild processes during a sim run. The sim
  drives the Markets / Federation / Reserves Facades directly and
  never serves a request; leaving these on causes:

  - `server: true` binds a real HTTP port (defaults to :4000 /
    :4001), which enters TIME_WAIT after `Application.stop/1` and
    can collide with the next sim run's boot.
  - `watchers: [esbuild, tailwind]` rebuilds `priv/static/assets/`
    on every sim invocation and dirties the working tree.
  - `code_reloader: true` and `live_reload: [...]` install
    filesystem watchers that race with the sim's data-dir wipe.

  Applied to both `PerpWalkWeb.Endpoint` (user-facing) and
  `PerpWalkAdminWeb.Endpoint` (admin dashboard). Missing one
  leaves that endpoint fully running during sim runs.
  """
  @spec suppress_web_endpoints!() :: :ok
  def suppress_web_endpoints! do
    for endpoint <- [PerpWalkWeb.Endpoint, PerpWalkAdminWeb.Endpoint] do
      endpoint_config =
        Application.get_env(:perpwalk, endpoint, [])
        |> Keyword.put(:server, false)
        |> Keyword.put(:watchers, [])
        |> Keyword.put(:code_reloader, false)
        |> Keyword.put(:live_reload, [])

      Application.put_env(:perpwalk, endpoint, endpoint_config)
    end

    :ok
  end

  @doc """
  Installs the sim's overrides on the neutral config seams prod
  code exposes. Each override targets a config key the runtime
  already reads, so no lib/ code change is required.

  Sim-specific bindings:

  - `:reserves.source` — `PerpWalk.Sim.Reserves.Source`
    (bookkeeping-derived `total_held` instead of a wallet RPC read).
  - `:federation_signer.signing_backend` —
    `{PerpWalk.Sim.Signing.Backend, :sign}` (synthetic hex txid so
    payouts complete `:signing → :submitted → :paid_out` without a
    real Monero multisig coordinator).

  Both target modules live under `sim/lib/`, excluded from `:prod`
  elixirc_paths — production releases never see them loaded.
  """
  @spec install_overrides!() :: :ok
  def install_overrides! do
    reserves = Application.get_env(:perpwalk, :reserves, [])

    Application.put_env(
      :perpwalk,
      :reserves,
      Keyword.put(reserves, :source, PerpWalk.Sim.Reserves.Source)
    )

    signer = Application.get_env(:perpwalk, :federation_signer, [])

    Application.put_env(
      :perpwalk,
      :federation_signer,
      Keyword.put(signer, :signing_backend, {PerpWalk.Sim.Signing.Backend, :sign})
    )

    :ok
  end
end
