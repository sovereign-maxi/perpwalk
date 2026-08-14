defmodule PerpWalk.Scenarios.CartelBootTest do
  @moduledoc """
  Smoke test for the Cartel federation runtime inside PERP WALK's
  supervision tree. Cartel is chain-agnostic; PERP WALK signs via
  `Darks.Multisig` on top of it.
  """

  use ExUnit.Case, async: false

  @moduletag :scenario

  test "Cartel.Supervisor is running under PerpWalk.Application" do
    assert Process.whereis(Cartel.Supervisor)
  end

  test "config/0 reflects PERP WALK's single-node defaults" do
    config = Cartel.Supervisor.config()

    assert config.product_module == PerpWalk.Federation.Product
    assert config.n == 1
    assert config.t == 1
    assert config.node_id == 1
  end

  test "the runtime children that PERP WALK relies on are alive" do
    assert Process.whereis(Cartel.Key.Store)
    assert Process.whereis(Cartel.Health.Monitor)
    assert Process.whereis(Cartel.Adapters.Transport.Nonce)
    assert Process.whereis(Cartel.Bootstrap)
  end

  test "quorum?/0 returns true for n=1 single-node" do
    assert Cartel.quorum?()
  end

  test "PerpWalk.Federation.Product implements the Cartel.Product behaviour" do
    assert Code.ensure_loaded?(PerpWalk.Federation.Product)
    assert function_exported?(PerpWalk.Federation.Product, :handle_mesh_message, 3)
  end
end
