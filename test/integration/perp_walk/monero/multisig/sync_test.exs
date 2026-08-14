defmodule PerpWalk.Monero.Multisig.SyncIntegrationTest do
  @moduledoc """
  Integration tests for the Monero multisig sync protocol.

  Uses a Darks stub client to avoid talking to a real wallet RPC.
  Drives real `:rpc.call` round-trips against
  `PerpWalk.Federation.RPC.Peer.multisig_info_exchange/1` on
  `Node.self()` via the `:peer_nodes_override` config switch, the
  same pattern as the attestation collector tests.

  The focus is the protocol mechanics (collect peer exports,
  reconcile local imports, degrade gracefully on peer failures),
  not the underlying multisig math which is owned by the Darks
  package + monero-wallet-rpc.
  """

  use PerpWalk.IntegrationCase

  alias PerpWalk.Monero.Multisig.Sync

  defmodule StubClient do
    @moduledoc false

    def export_multisig_info, do: {:ok, %{info: "export-hex-#{:erlang.unique_integer([:positive])}"}}

    def import_multisig_info(info_list) when is_list(info_list) do
      {:ok, %{n_outputs: length(info_list)}}
    end
  end

  defmodule ExportFailingClient do
    @moduledoc false
    def export_multisig_info, do: {:error, :wallet_unreachable}
    def import_multisig_info(_info), do: {:ok, %{n_outputs: 0}}
  end

  defmodule ImportFailingClient do
    @moduledoc false
    def export_multisig_info, do: {:ok, %{info: "export-hex"}}
    def import_multisig_info(_info), do: {:error, :corrupt_info}
  end

  setup do
    Application.put_env(:darks, :client, StubClient)

    on_exit(fn ->
      Application.delete_env(:darks, :client)
      Application.delete_env(:perpwalk, :federation)
    end)

    :ok
  end

  describe "local_export/0" do
    test "returns the wallet's exported multisig info hex" do
      assert {:ok, hex} = Sync.local_export()
      assert is_binary(hex)
      assert String.starts_with?(hex, "export-hex-")
    end

    test "surfaces wallet RPC errors" do
      Application.put_env(:darks, :client, ExportFailingClient)
      assert {:error, :wallet_unreachable} = Sync.local_export()
    end
  end

  describe "apply_imports/1" do
    test "returns the count of outputs reconciled" do
      assert {:ok, 2} = Sync.apply_imports(["peer-1-hex", "peer-2-hex"])
    end

    test "handles empty input" do
      assert {:ok, 0} = Sync.apply_imports([])
    end

    test "surfaces wallet RPC errors" do
      Application.put_env(:darks, :client, ImportFailingClient)
      assert {:error, :corrupt_info} = Sync.apply_imports(["any-hex"])
    end
  end

  describe "sync_with_peers/1" do
    test "returns zero counts when no peers are configured" do
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [])

      assert {:ok, %{peers_synced: 0, outputs_imported: 0}} = Sync.sync_with_peers()
    end

    test "exchanges with a reachable peer and imports its export" do
      # Targeting Node.self() drives a real :rpc round-trip through
      # the peer endpoint and back. The stub client returns a unique
      # info hex per call so the peer's export ≠ our export.
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [Node.self()])

      assert {:ok, %{peers_synced: 1, outputs_imported: 1}} = Sync.sync_with_peers()
    end

    test "degrades gracefully when all peers are unreachable" do
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [:nodedown@nohost])

      assert {:ok, %{peers_synced: 0, outputs_imported: 0}} = Sync.sync_with_peers()
    end

    test "reconciles from the reachable subset when mixed with unreachable peers" do
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [:nodedown@nohost, Node.self()])

      assert {:ok, %{peers_synced: 1, outputs_imported: 1}} = Sync.sync_with_peers()
    end

    test "surfaces local export failure before contacting peers" do
      Application.put_env(:darks, :client, ExportFailingClient)
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [Node.self()])

      assert {:error, :wallet_unreachable} = Sync.sync_with_peers()
    end

    test "degrades to zero-peer success when peer-side import fails on all peers" do
      # ImportFailingClient fails import on BOTH ends (same Darks
      # config) — so each peer responds with the failure error, the
      # leader's filter_successful skips them, and we land in the
      # "no peer responses" path. The local-side import error path
      # is covered by the `apply_imports/1` tests directly.
      Application.put_env(:darks, :client, ImportFailingClient)
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [Node.self()])

      assert {:ok, %{peers_synced: 0, outputs_imported: 0}} = Sync.sync_with_peers()
    end

    test "accepts a custom trigger context for log correlation" do
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [])

      assert {:ok, _} = Sync.sync_with_peers(triggered_by: {:post_spend, "req-abc-123"})
      assert {:ok, _} = Sync.sync_with_peers(triggered_by: :periodic)
      assert {:ok, _} = Sync.sync_with_peers(triggered_by: :manual)
    end
  end
end
