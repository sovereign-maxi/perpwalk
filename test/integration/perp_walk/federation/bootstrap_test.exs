defmodule PerpWalk.Federation.BootstrapIntegrationTest do
  @moduledoc """
  Tests `Federation.Bootstrap.run/1` against a stub Darks client.

  We invoke the ceremony with `nodes: [self_node, self_node,
  self_node]` so the rpc helper takes the local fast-path on every
  call. The stub client tracks calls in ETS so tests can assert on
  the arguments each phase received — verifies the peer-info
  routing (each node sees the OTHER two's strings, not its own).
  """

  use PerpWalk.IntegrationCase

  alias PerpWalk.Federation.Bootstrap

  @ets PerpWalk.Federation.BootstrapIntegrationTest.Calls

  defmodule StubClient do
    @moduledoc false

    @ets PerpWalk.Federation.BootstrapIntegrationTest.Calls

    def create_wallet(filename, _password) do
      n = bump(:create)
      record_args(:create, n, filename)
      :ok
    end

    def open_wallet(_filename, _password), do: :ok

    def prepare_multisig(_enable_experimental \\ false) do
      n = bump(:prepare)
      {:ok, %{multisig_info: "v1_info_#{n}"}}
    end

    def make_multisig(threshold, peer_infos) do
      n = bump(:make)
      record_args(:make, n, {threshold, peer_infos})
      {:ok, %{address: "intermediate_addr_#{n}", multisig_info: "v2_info_#{n}"}}
    end

    def exchange_multisig_keys(peer_infos) do
      n = bump(:exchange)
      record_args(:exchange, n, peer_infos)
      {:ok, %{address: "shared_address_final"}}
    end

    defp bump(phase) do
      :ets.update_counter(@ets, phase, 1, {phase, 0})
    end

    defp record_args(phase, n, args) do
      :ets.insert(@ets, {{phase, n}, args})
    end
  end

  defmodule FailingClient do
    @moduledoc false

    def create_wallet(_filename, _password) do
      case :ets.lookup(PerpWalk.Federation.BootstrapIntegrationTest.Calls, :fail_phase) do
        [{:fail_phase, :create}] -> {:error, :wallet_dir_unwritable}
        _ -> :ok
      end
    end

    def open_wallet(_filename, _password), do: :ok

    def prepare_multisig(_enable_experimental \\ false) do
      case :ets.lookup(PerpWalk.Federation.BootstrapIntegrationTest.Calls, :fail_phase) do
        [{:fail_phase, :prepare}] -> {:error, :wallet_unreachable}
        _ -> {:ok, %{multisig_info: "v1"}}
      end
    end

    def make_multisig(_threshold, _peer_infos) do
      case :ets.lookup(PerpWalk.Federation.BootstrapIntegrationTest.Calls, :fail_phase) do
        [{:fail_phase, :make}] -> {:error, :rpc_timeout}
        _ -> {:ok, %{address: "addr", multisig_info: "v2"}}
      end
    end

    def exchange_multisig_keys(_peer_infos) do
      case :ets.lookup(PerpWalk.Federation.BootstrapIntegrationTest.Calls, :fail_phase) do
        [{:fail_phase, :exchange}] -> {:error, :wallet_busy}
        _ -> {:ok, %{address: "shared"}}
      end
    end
  end

  defmodule DivergingClient do
    @moduledoc false

    def create_wallet(_filename, _password), do: :ok
    def open_wallet(_filename, _password), do: :ok
    def prepare_multisig(_enable_experimental \\ false), do: {:ok, %{multisig_info: "v1"}}
    def make_multisig(_t, _p), do: {:ok, %{address: "intermediate", multisig_info: "v2"}}

    def exchange_multisig_keys(_peer_infos) do
      n = :ets.update_counter(PerpWalk.Federation.BootstrapIntegrationTest.Calls, :diverge, 1, {:diverge, 0})
      {:ok, %{address: "addr_#{n}"}}
    end
  end

  setup do
    case :ets.info(@ets) do
      :undefined -> :ets.new(@ets, [:set, :public, :named_table])
      _ -> :ets.delete_all_objects(@ets)
    end

    on_exit(fn ->
      Application.delete_env(:darks, :client)
    end)

    :ok
  end

  describe "validation" do
    test "refuses when running with a single node" do
      assert {:error, :single_node_mode} =
               Bootstrap.run(nodes: [Node.self()])
    end

    test "refuses an invalid threshold (zero)" do
      assert {:error, :invalid_threshold} =
               Bootstrap.run(nodes: [Node.self(), Node.self()], threshold: 0)
    end

    test "refuses a threshold larger than node count" do
      assert {:error, :invalid_threshold} =
               Bootstrap.run(nodes: [Node.self(), Node.self()], threshold: 5)
    end
  end

  describe "ceremony — happy path" do
    setup do
      Application.put_env(:darks, :client, StubClient)
      :ok
    end

    test "returns the shared address when all three nodes converge" do
      nodes = [Node.self(), Node.self(), Node.self()]

      assert {:ok, "shared_address_final"} = Bootstrap.run(nodes: nodes, threshold: 2)
    end

    test "phase 0 (create) is called once per node with the wallet filename" do
      nodes = [Node.self(), Node.self(), Node.self()]

      Bootstrap.run(nodes: nodes, threshold: 2, wallet_filename: "test-wallet")

      [{:create, count}] = :ets.lookup(@ets, :create)
      assert count == 3

      [{{:create, 1}, filename}] = :ets.lookup(@ets, {:create, 1})
      assert filename == "test-wallet"
    end

    test "phase 1 (prepare) is called once per node" do
      nodes = [Node.self(), Node.self(), Node.self()]
      Bootstrap.run(nodes: nodes, threshold: 2)

      [{:prepare, count}] = :ets.lookup(@ets, :prepare)
      assert count == 3
    end

    test "phase 2 (make) sees each node's peers — not the node's own info" do
      nodes = [Node.self(), Node.self(), Node.self()]
      Bootstrap.run(nodes: nodes, threshold: 2)

      # Each make call gets {threshold, [peer_v1_strings]}.
      # Node at index 0 should NOT see "v1_info_1" (its own).
      [{{:make, 1}, {2, peer_infos_for_node_0}}] = :ets.lookup(@ets, {:make, 1})
      assert "v1_info_1" not in peer_infos_for_node_0
      assert "v1_info_2" in peer_infos_for_node_0
      assert "v1_info_3" in peer_infos_for_node_0
      assert length(peer_infos_for_node_0) == 2
    end

    test "phase 3 (exchange) receives each node's peers' v2 strings" do
      nodes = [Node.self(), Node.self(), Node.self()]
      Bootstrap.run(nodes: nodes, threshold: 2)

      [{{:exchange, 1}, peer_infos_for_node_0}] = :ets.lookup(@ets, {:exchange, 1})
      assert "v2_info_1" not in peer_infos_for_node_0
      assert "v2_info_2" in peer_infos_for_node_0
      assert "v2_info_3" in peer_infos_for_node_0
    end
  end

  describe "ceremony — error paths" do
    test "{:error, {:create_wallet_failed, _}} when create_wallet fails" do
      Application.put_env(:darks, :client, FailingClient)
      :ets.insert(@ets, {:fail_phase, :create})

      nodes = [Node.self(), Node.self(), Node.self()]

      assert {:error, {:create_wallet_failed, {:rpc, _node, :wallet_dir_unwritable}}} =
               Bootstrap.run(nodes: nodes, threshold: 2)
    end

    test "{:error, {:prepare_failed, _}} when prepare fails" do
      Application.put_env(:darks, :client, FailingClient)
      :ets.insert(@ets, {:fail_phase, :prepare})

      nodes = [Node.self(), Node.self(), Node.self()]

      assert {:error, {:prepare_failed, {:rpc, _node, :wallet_unreachable}}} =
               Bootstrap.run(nodes: nodes, threshold: 2)
    end

    test "{:error, {:make_failed, _}} when make fails" do
      Application.put_env(:darks, :client, FailingClient)
      :ets.insert(@ets, {:fail_phase, :make})

      nodes = [Node.self(), Node.self(), Node.self()]

      assert {:error, {:make_failed, {:rpc, _node, :rpc_timeout}}} =
               Bootstrap.run(nodes: nodes, threshold: 2)
    end

    test "{:error, {:exchange_failed, _}} when exchange fails" do
      Application.put_env(:darks, :client, FailingClient)
      :ets.insert(@ets, {:fail_phase, :exchange})

      nodes = [Node.self(), Node.self(), Node.self()]

      assert {:error, {:exchange_failed, {:rpc, _node, :wallet_busy}}} =
               Bootstrap.run(nodes: nodes, threshold: 2)
    end

    test "{:error, :address_mismatch} when nodes converge on different addresses" do
      Application.put_env(:darks, :client, DivergingClient)

      nodes = [Node.self(), Node.self(), Node.self()]

      assert {:error, :address_mismatch} = Bootstrap.run(nodes: nodes, threshold: 2)
    end
  end
end
