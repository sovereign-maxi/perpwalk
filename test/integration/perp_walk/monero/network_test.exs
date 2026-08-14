defmodule PerpWalk.Monero.NetworkIntegrationTest do
  @moduledoc "Integration tests for `PerpWalk.Monero.Network` — reads application config."

  use PerpWalk.IntegrationCase

  alias PerpWalk.Monero.Network

  describe "current/0" do
    test "defaults to :mainnet when unset" do
      Application.delete_env(:perpwalk, :network)
      assert Network.current() == :mainnet
    end

    test "returns :stagenet when configured" do
      Application.put_env(:perpwalk, :network, :stagenet)
      assert Network.current() == :stagenet
      Application.delete_env(:perpwalk, :network)
    end

    test "returns :testnet when configured" do
      Application.put_env(:perpwalk, :network, :testnet)
      assert Network.current() == :testnet
      Application.delete_env(:perpwalk, :network)
    end
  end
end
