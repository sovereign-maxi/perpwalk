defmodule PerpWalk.Reserves.Attestation.CollectorIntegrationTest do
  @moduledoc """
  Integration tests for the peer-attestation collector — drives a
  real `:rpc.call` round-trip against `PerpWalk.Federation.RPC.Peer`
  on `Node.self()` and verifies returned attestations.

  Peer nodes come from `PerpWalk.Federation.Facade.peer_nodes/0` in
  production; tests use the shared `:federation` `:peer_nodes_override`
  config switch so they can target `Node.self()` without needing a
  real multi-node cluster.

  Pubkey trust is by self-consistency:
  `SHA-256(pubkey)[0..15] == attestation.guardian_id`, plus an
  Ed25519 signature check. No pre-shared pubkey config is needed —
  each peer response carries its own pubkey, and the HMAC layer
  ensures the response itself came from a federation peer.
  """

  use PerpWalk.IntegrationCase

  alias PerpWalk.Federation.Signing.Peer.Throttle
  alias PerpWalk.Reserves.Attestation.Collector
  alias PerpWalk.Reserves.Drift

  setup do
    # Same Throttle-reset rationale as peer_test / monero_test —
    # attest_snapshot doesn't go through Throttle but the file may
    # later grow tests that do.
    Throttle.reset()

    # Squeeze the peer-side attestation retry budget so divergence
    # paths don't spend the full 6s budget.
    Application.put_env(:perpwalk, :reserves,
      attestation_max_attempts: 1,
      attestation_retry_interval_ms: 0
    )

    # Drift state from prior tests would bleed into the new round's
    # assertions; reset so each test starts from no-data defaults.
    Drift.reset()

    on_exit(fn ->
      Application.delete_env(:perpwalk, :reserves)
      Application.delete_env(:perpwalk, :federation)
      Drift.reset()
    end)

    :ok
  end

  describe "collect/1" do
    test "returns an empty list when no peers are reachable" do
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [])

      snapshot = Vault.Snapshot.capture(PerpWalk.Reserves.Source)

      assert {:ok, []} = Collector.collect(snapshot)
    end

    test "collects a valid attestation from a peer whose values match" do
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [Node.self()])

      snapshot = Vault.Snapshot.capture(PerpWalk.Reserves.Source)

      assert {:ok, [%Vault.Attestation{} = att]} = Collector.collect(snapshot)
      assert att.snapshot_id == snapshot.id
      assert att.total_held == snapshot.total_held
      assert att.outstanding == snapshot.outstanding
    end

    test "rejects attestations from pubkeys not in the pinned guardian registry" do
      # Without pinning, a compromised peer could mint arbitrary
      # keypairs and inflate `attestation_count` to fake the quorum.
      # Pin a bogus set that DOES NOT include the local guardian's
      # pubkey, then confirm no attestation makes it through.
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [Node.self()])

      # Any 32-byte value that isn't the local guardian's real pubkey.
      Application.put_env(:perpwalk, :reserves,
        attestation_rpc_timeout_ms: 8_000,
        guardian_pubkeys: [:crypto.strong_rand_bytes(32)]
      )

      on_exit(fn ->
        Application.put_env(:perpwalk, :reserves, attestation_rpc_timeout_ms: 8_000)
      end)

      snapshot = Vault.Snapshot.capture(PerpWalk.Reserves.Source)

      assert {:ok, []} = Collector.collect(snapshot)
    end

    test "accepts attestation when the local guardian's pubkey IS in the pinned registry" do
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [Node.self()])

      {:ok, local_pubkey} = Vault.Generator.guardian_pubkey()

      Application.put_env(:perpwalk, :reserves,
        attestation_rpc_timeout_ms: 8_000,
        guardian_pubkeys: [local_pubkey]
      )

      on_exit(fn ->
        Application.put_env(:perpwalk, :reserves, attestation_rpc_timeout_ms: 8_000)
      end)

      snapshot = Vault.Snapshot.capture(PerpWalk.Reserves.Source)

      assert {:ok, [%Vault.Attestation{}]} = Collector.collect(snapshot)
    end

    test "skips peers that refuse with :divergent" do
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [Node.self()])

      # Build a snapshot with bogus values — the peer (Node.self())
      # captures its own from the live source, sees a mismatch, refuses.
      base = Vault.Snapshot.capture(PerpWalk.Reserves.Source)
      bogus = %{base | total_held: base.total_held + 999_000_000_000}

      assert {:ok, []} = Collector.collect(bogus)
    end

    test "skips peers whose node is unreachable" do
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [:nodedown@nohost])

      snapshot = Vault.Snapshot.capture(PerpWalk.Reserves.Source)

      assert {:ok, []} = Collector.collect(snapshot)
    end

    test "collects from the reachable subset when a mix of reachable + unreachable peers is configured" do
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [:nodedown@nohost, Node.self()])

      snapshot = Vault.Snapshot.capture(PerpWalk.Reserves.Source)

      assert {:ok, [%Vault.Attestation{}]} = Collector.collect(snapshot)
    end
  end

  describe "drift state recording" do
    test "records empty divergent list on a clean attestation round" do
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [Node.self()])

      snapshot = Vault.Snapshot.capture(PerpWalk.Reserves.Source)
      assert {:ok, [_]} = Collector.collect(snapshot)

      assert %{divergent_peers: [], observed_at: %DateTime{}} = Drift.status()
    end

    test "records divergent peers when peer refuses with structured divergence" do
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [Node.self()])

      base = Vault.Snapshot.capture(PerpWalk.Reserves.Source)
      bogus = %{base | total_held: base.total_held + 999_000_000_000}

      assert {:ok, []} = Collector.collect(bogus)

      assert %{divergent_peers: peers, observed_at: %DateTime{}} = Drift.status()
      assert Node.self() in peers
    end

    test "does NOT record unreachable peers as divergent (different failure class)" do
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [:nodedown@nohost])

      snapshot = Vault.Snapshot.capture(PerpWalk.Reserves.Source)
      assert {:ok, []} = Collector.collect(snapshot)

      # nodedown@nohost responded with :rpc_failed, not :divergent.
      # That's tracked by :federation_quorum_lost / :reserves_proof_stale,
      # NOT by :federation_multisig_drift.
      assert %{divergent_peers: []} = Drift.status()
    end

    test "subsequent clean round clears prior divergent state" do
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [Node.self()])

      base = Vault.Snapshot.capture(PerpWalk.Reserves.Source)
      bogus = %{base | total_held: base.total_held + 999_000_000_000}

      # First round diverges.
      assert {:ok, []} = Collector.collect(bogus)
      assert %{divergent_peers: [_ | _]} = Drift.status()

      # Second round is clean — drift state should reset.
      assert {:ok, [_]} = Collector.collect(base)
      assert %{divergent_peers: []} = Drift.status()
    end
  end
end
