defmodule PerpWalk.Reserves.SupervisorIntegrationTest do
  @moduledoc """
  Integration tests for `PerpWalk.Reserves.Supervisor`.

  The supervisor wires `PerpWalk.Reserves.Attestation.Collector`
  into the `Vault.Generator`'s `:attestation_collector` opt so every
  proof cycle includes a peer-attestation collection pass. Without
  this wiring every proof would publish at `attestation_count: 1`
  (the guardian's self-attestation only) regardless of how many
  peers were running — which would silently degrade the federation's
  proof-of-reserves guarantee.

  This test pins the wiring against regression: a future refactor
  that drops the line in supervisor.ex fails here, loudly, instead
  of at the next production proof cycle.
  """

  use PerpWalk.IntegrationCase

  test "Vault.Generator runs with PerpWalk.Reserves.Attestation.Collector as its attestation_collector" do
    state = :sys.get_state(Vault.Generator)
    assert state.attestation_collector == PerpWalk.Reserves.Attestation.Collector
  end
end
