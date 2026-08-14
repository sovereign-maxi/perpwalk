defmodule PerpWalk.Monero.FacadeIntegrationTest do
  @moduledoc """
  Crash-safety tests for Monero.Facade.

  Tests run with no monero-wallet-rpc actually listening on
  localhost:18082, so every Facade call should return
  `{:error, _}` rather than letting an exit propagate. Crash
  safety is the contract — Telemetry's `:monero_unreachable`
  rule depends on it.
  """

  use PerpWalk.IntegrationCase

  alias PerpWalk.Monero.Facade

  test "health_check/0 returns {:error, _} when wallet RPC is unreachable" do
    assert {:error, _reason} = Facade.health_check()
  end

  test "balance/0 returns {:error, _} when wallet RPC is unreachable" do
    assert {:error, _reason} = Facade.balance()
  end

  test "create_subaddress/0 returns {:error, _} when wallet RPC is unreachable" do
    assert {:error, _reason} = Facade.create_subaddress()
  end

  test "block_height/0 returns {:error, _} when wallet RPC is unreachable" do
    assert {:error, _reason} = Facade.block_height()
  end

  describe "create_subaddress/0 designated-processor gate" do
    setup do
      previous = Application.get_env(:perpwalk, :participant_id)

      on_exit(fn ->
        if previous == nil do
          Application.put_env(:perpwalk, :participant_id, :p1)
        else
          Application.put_env(:perpwalk, :participant_id, previous)
        end
      end)

      :ok
    end

    test "non-designated nodes REFUSE the local wallet allocation" do
      # Cluster-wide invariant: subaddress allocation is a monotonic
      # per-wallet operation. If two nodes independently call
      # wallet-rpc create_address they can both hand out "index N"
      # to different quotes — the deterministic derivation then
      # collides at the storage layer. Pin allocation to the
      # designated processor so index space stays coherent.
      Application.put_env(:perpwalk, :participant_id, :p2)

      # :p2 is NOT in the default designated set [:p1, :s1] and no
      # runtime promotion has landed.
      assert {:error, :not_designated_for_subaddress_allocation} =
               Facade.create_subaddress()
    end

    test "designated processor calls through to the local wallet (returns wallet-rpc error since RPC is not up in tests)" do
      Application.put_env(:perpwalk, :participant_id, :p1)

      # :p1 IS designated, so it doesn't short-circuit — instead it
      # tries the local wallet-rpc, which isn't listening, so we get
      # the transport error rather than the designated-refusal.
      assert {:error, reason} = Facade.create_subaddress()
      refute reason == :not_designated_for_subaddress_allocation
    end
  end
end
