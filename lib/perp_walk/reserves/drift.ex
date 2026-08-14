defmodule PerpWalk.Reserves.Drift do
  @moduledoc """
  Tracks the most recent proof-of-reserves attestation round outcome
  for the federation-multisig-drift alert.

  Each round, `Reserves.Attestation.Collector` calls `record_round/2`
  with the list of peers that refused attestation due to
  `{:divergent, ...}` (i.e. peers whose local wallet view disagreed
  with the leader's snapshot). A telemetry rule polls `status/0` and
  fires the `:federation_multisig_drift` alert when the list is
  non-empty.

  ## Published surface

  `status/0` is a cross-domain read-only diagnostic — stable-shape
  map, callable from any consumer without going through
  `Reserves.Facade`. The Telemetry rule that fires
  `:federation_multisig_drift` polls this directly.

  Storage is `:persistent_term` — single writer (Collector), many
  readers (the telemetry rule, possibly admin dashboards). Read is
  lock-free and crash-safe; write is rare (once per 10-min proof
  cycle) so the persistent_term-rewrite cost is negligible.

  Distinct from peers that were *unreachable* — those are tracked
  by other alerts (`:federation_quorum_lost`, `:reserves_proof_stale`).
  Drift specifically means "the peer responded but disagreed," which
  signals stale multisig info exchange.
  """

  @key {__MODULE__, :state}

  @type peer :: atom()
  @type state :: %{
          divergent_peers: [peer()],
          observed_at: DateTime.t() | nil
        }

  @doc """
  Records the most recent proof cycle's outcome. A divergent peer
  STAYS divergent until it attests cleanly — an unreachable peer
  contributes nothing to a round, so silence must never clear the
  drift gate that halts signing.
  """
  @spec record_round([peer()], [peer()], DateTime.t()) :: :ok
  def record_round(divergent_peers, clean_peers \\ [], observed_at \\ DateTime.utc_now())
      when is_list(divergent_peers) and is_list(clean_peers) do
    sticky =
      status().divergent_peers
      |> Kernel.--(clean_peers)
      |> Kernel.++(divergent_peers)
      |> Enum.uniq()

    :persistent_term.put(@key, %{
      divergent_peers: sticky,
      observed_at: observed_at
    })

    :ok
  end

  @doc """
  Returns the most recently recorded drift state. Before any round
  has run, returns the no-data default — `observed_at: nil`,
  `divergent_peers: []` — which the telemetry rule treats as `:ok`.
  """
  @spec status() :: state()
  def status do
    :persistent_term.get(@key, %{divergent_peers: [], observed_at: nil})
  end

  @doc """
  Clears the recorded state. Test helper — not called from production
  code paths.
  """
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@key)
    :ok
  end
end
