defmodule PerpWalk.Reserves.Attestation.Collector do
  @moduledoc """
  `Vault.AttestationCollector` implementation for PERP WALK.

  Each reserve proof cycle the local `Vault.Generator` captures a
  snapshot and calls `collect/1`. This module sends an HMAC-protected
  RPC to each federation peer (taken from `Cartel.Supervisor.config().peer_nodes`),
  verifies the returned attestation cryptographically, and returns
  the list of valid attestations.

  A peer that observes divergent values refuses to attest (see
  `PerpWalk.Federation.RPC.Peer.attest_snapshot/1`). A peer that
  is unreachable contributes nothing. A peer that returns a forged
  attestation fails the self-consistency check and is dropped with a
  warning log.

  ## Verification chain

  No pre-shared per-peer pubkey config is needed. Each peer response
  carries the responding guardian's Ed25519 pubkey alongside the
  attestation. The collector then checks:

    1. **HMAC binding** — the response came from a node holding
       `:federation_rpc_secret` (transport-layer trust).
    2. **Self-consistency** — `SHA-256(pubkey)[0..15] == attestation.guardian_id`
       (the attestation was signed by the key matching the claimed
       guardian id).
    3. **Signature validity** — `Ed25519.verify(payload, signature, pubkey)`
       passes (the attestation was actually signed by the matching
       private key).

  A compromised peer with the shared secret could publish dishonest
  attestations using its own keypair, but cannot impersonate another
  guardian without that guardian's private key.

  ## Configuration

      config :perpwalk, :reserves,
        attestation_rpc_timeout_ms: 8_000

  Peer node atoms come from `PerpWalk.Federation.Facade.peer_nodes/0`
  (the federation domain owns peer knowledge; this module does not
  reach across to Cartel directly). Tests override via
  `config :perpwalk, :federation, peer_nodes_override: [Node.self()]`.
  """

  @behaviour Vault.AttestationCollector

  require Logger

  alias PerpWalk.Federation.Facade, as: FederationFacade
  alias PerpWalk.Reserves.Drift
  alias Vault.{Attestation, Snapshot}

  @default_timeout_ms 8_000
  @guardian_id_bytes 16

  @impl Vault.AttestationCollector
  def collect(%Snapshot{} = snapshot) do
    peers = peer_nodes()
    timeout = timeout_ms()

    Logger.info("Collector: starting attestation round, peers=#{length(peers)}, peer_list=#{inspect(peers)}")

    results = Enum.map(peers, fn peer -> {peer, attest_one(peer, snapshot, timeout)} end)

    attestations = Enum.flat_map(results, &filter_valid_attestation/1)
    divergent_peers = Enum.flat_map(results, &filter_divergent_peer/1)

    # A peer clears prior divergence ONLY by attesting cleanly. An
    # unreachable peer is neither clean nor divergent this round — its
    # last divergence stays on record until it answers cleanly, so a
    # divergent-then-dark peer can't release the signing halt by
    # disappearing.
    clean_peers =
      Enum.flat_map(results, fn {peer, result} ->
        if filter_valid_attestation({peer, result}) != [], do: [peer], else: []
      end)

    Drift.record_round(divergent_peers, clean_peers)

    Logger.info("Collector: round complete, collected=#{length(attestations)}, peers=#{length(peers)}")

    {:ok, attestations}
  end

  # --- Internal ---

  defp filter_valid_attestation({peer, {:ok, %{attestation: %Attestation{} = att, pubkey: pubkey}}})
       when is_binary(pubkey) do
    cond do
      not pinned_guardian?(pubkey) ->
        # Without a pinned registry a compromised peer could
        # mint N Ed25519 keypairs, sign N attestations from itself,
        # and inflate `attestation_count` to fake the quorum. Pin
        # the pubkey set to the federation's pre-configured
        # guardians so only those keys count.
        Logger.warning("Collector: peer attestation pubkey not in pinned guardian registry, peer=#{inspect(peer)}")

        []

      not guardian_id_matches?(att, pubkey) ->
        Logger.warning("Collector: peer attestation guardian_id does not match pubkey hash, peer=#{inspect(peer)}")

        []

      match?({:ok, _}, Attestation.verify(att, pubkey)) ->
        [att]

      true ->
        Logger.warning("Collector: peer attestation failed signature verification, peer=#{inspect(peer)}")

        []
    end
  end

  defp filter_valid_attestation({peer, {:ok, _bad_shape}}) do
    Logger.warning("Collector: peer returned malformed attestation payload, peer=#{inspect(peer)}")

    []
  end

  defp filter_valid_attestation({peer, {:error, reason}}) do
    Logger.info("Collector: peer #{inspect(peer)} did not attest, reason=#{inspect(reason)}")

    []
  end

  # Divergence (peer responded but disagreed) is the signal for the
  # `:federation_multisig_drift` telemetry rule. Unreachable peers
  # are tracked separately by `:federation_quorum_lost` and
  # `:reserves_proof_stale` — they're a different failure class.
  defp filter_divergent_peer({peer, {:error, {:divergent, _details}}}), do: [peer]
  defp filter_divergent_peer(_), do: []

  defp guardian_id_matches?(%Attestation{guardian_id: gid}, pubkey) when is_binary(pubkey) do
    Plug.Crypto.secure_compare(
      binary_part(:crypto.hash(:sha256, pubkey), 0, @guardian_id_bytes),
      gid
    )
  end

  # Pinned guardian pubkeys come from `:perpwalk, :reserves,
  # :guardian_pubkeys` — a list of Ed25519 public-key binaries the
  # federation operator explicitly ceremony'd in. Empty list = pinning
  # disabled (single-node dev/test); this must be non-empty in prod.
  # Comparison is constant-time via secure_compare.
  defp pinned_guardian?(pubkey) when is_binary(pubkey) do
    case pinned_guardian_pubkeys() do
      [] -> true
      keys -> Enum.any?(keys, fn pinned -> Plug.Crypto.secure_compare(pinned, pubkey) end)
    end
  end

  defp pinned_guardian_pubkeys do
    :perpwalk
    |> Application.get_env(:reserves, [])
    |> Keyword.get(:guardian_pubkeys, [])
  end

  defp attest_one(peer, snapshot, timeout) do
    request = FederationFacade.sign_rpc_request(:attest_snapshot, snapshot)

    case FederationFacade.rpc_call_peer(peer, :attest_snapshot, request, timeout) do
      {:ok, response} ->
        unwrap_response(response, request.nonce)

      {:badrpc, reason} ->
        {:error, {:rpc_failed, reason}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_response, other}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp unwrap_response(response, nonce) do
    case FederationFacade.verify_rpc_response(response, :attest_snapshot, nonce) do
      {:ok, {:ok, payload}} -> {:ok, payload}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, {:response_auth_failed, reason}}
    end
  end

  defp peer_nodes, do: FederationFacade.peer_nodes()

  defp timeout_ms do
    :perpwalk
    |> Application.get_env(:reserves, [])
    |> Keyword.get(:attestation_rpc_timeout_ms, @default_timeout_ms)
  end
end
