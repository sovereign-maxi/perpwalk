defmodule PerpWalk.Federation.Supervisor do
  @moduledoc """
  Supervises the Federation domain.

  Boots `Federation.Store` (durable Payout persistence)
  and `Federation.Signer` (per-node ticker that drives requests
  through the state machine). The operator Console
  is iex-driven and doesn't need supervision.

  `one_for_one` so a single-component crash doesn't take the
  whole tree down.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Verify local Ed25519 signing key against pinned participant
    # registry BEFORE any signing-capable child starts. Pinned-but-
    # mismatched or pinned-but-missing halts via source_halt so the
    # venue refuses to write until an operator triages.
    :ok = PerpWalk.Federation.Keys.verify_local_key_pinning()

    children = [
      PerpWalk.Federation.Store,
      PerpWalk.Federation.Health.Bridge,
      PerpWalk.Federation.Signer,
      PerpWalk.Federation.Multisig.Guard,
      PerpWalk.Federation.Signing.Peer.Throttle,
      PerpWalk.Federation.Alerter,
      PerpWalk.Federation.Checkpointer
    ]

    # Budget raised from the OTP default (3 in 5s) to match Markets
    # and Storage. Federation children include Tor-mediated peer RPCs
    # via Signer and the wallet-RPC check in Multisig.Guard; flaky
    # network conditions can produce serial transient crashes that the
    # tighter budget would cascade into the root `:rest_for_one` and
    # crater the whole BEAM.
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end
end
