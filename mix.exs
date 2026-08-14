defmodule PerpWalk.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :perpwalk,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: test_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      aliases: aliases(),
      deps: deps(),
      releases: [
        perpwalk: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent],
          validate_compile_env: true
        ]
      ],
      name: "PerpWalk",
      description: "Markets Without Permission",
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :inets, :ssl],
      mod: {PerpWalk.Application, []}
    ]
  end

  # `sim/lib` carries the simulation harness — actor processes,
  # scenarios, invariant validators, the `mix sim.events` task.
  # Compiled in :dev (so iex can drive sims interactively) and
  # :test (so the harness self-tests can run) but NEVER in :prod
  # — a release must not ship sim code or its supervisor children.
  defp elixirc_paths(:prod), do: ["lib"]
  defp elixirc_paths(:test), do: ["lib", "test/support", "sim/lib"]
  defp elixirc_paths(_), do: ["lib", "sim/lib"]

  defp test_paths(:test), do: ["test", "sim/test"]
  defp test_paths(_), do: ["test"]

  defp deps do
    [
      # Web
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:plug_cowboy, "~> 2.8"},
      {:jason, "~> 1.4"},

      # HTTP client (Nostr relay publishing, oracle sources if/when needed)
      {:finch, "~> 0.21"},

      # WebSocket client for Nostr relays (NIP-01)
      {:mint_web_socket, "~> 1.0"},

      # Common design system (CSS + LiveView components)
      {:blueprint, path: "../blueprint"},

      # Anti-sybil: PoW challenges, rate limiting, circuit extraction
      {:seer, path: "../seer"},

      # Storage primitives: WAL, atomic counters, pluggable backends
      {:locker, path: "../locker"},

      # Reserve proof generation, attestation, deficit detection
      {:vault, path: "../vault"},

      # secp256k1 NIF: BIP-340 Schnorr signing for Nostr event publication
      {:cashew, path: "../cashew"},

      # Monero integration: monerod RPC, subaddresses, withdrawals
      {:darks, path: "../darks"},

      # Federation runtime: cluster mesh, encrypted key store, signed
      # transport, peer health monitoring. Used in :none signing-backend
      # mode since PERP WALK signs via Darks.Multisig (Monero-native),
      # not Hydra/FROST.
      {:cartel, path: "../cartel"},

      # Keyphrase-only auth — keyphrase IS the account, no email,
      # password, or recovery. SHA-256 hash of the normalized keyphrase
      # is the only persistent identifier.
      {:locksmith, path: "../locksmith"},

      # Persistent key-value store
      {:cubdb, "~> 2.0"},

      # QR code rendering — pure Elixir, returns SVG. Used by the
      # market detail Trade panel to render deposit-subaddress QRs.
      {:eqrcode, "~> 0.2"},

      # Structured logging (prod)
      {:logger_json, "~> 6.2"},

      # Telemetry
      {:telemetry, "~> 1.3"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},

      # Asset bundling
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},

      # Dev & Test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: :test},
      {:mox, "~> 1.2", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "esbuild.install --if-missing"],
      test: ["test"],
      "assets.deploy": [
        "esbuild perpwalk --minify",
        "phx.digest"
      ]
    ]
  end
end
