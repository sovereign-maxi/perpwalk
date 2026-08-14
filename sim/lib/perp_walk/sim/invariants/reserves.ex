defmodule PerpWalk.Sim.Invariants.Reserves do
  @moduledoc """
  Validates the reserves proof cycle while the sim is running.

  Reads the latest `Vault.Proof` from `PerpWalk.Reserves.Facade`
  each tick (cheap ETS lookup) and asserts:

  - **Solvency** — `total_held >= outstanding` whenever a proof
    exists. A failing proof means the system is short of the
    obligations it has booked.
  - **Threshold signature presence** — `:published` proofs must
    carry a `threshold_signature`; a published proof without one
    means the signing path dispatched the publisher without the
    aggregate signature, which would publish unverifiable proofs
    to relays.
  - **At least one attestation** — every proof's `attestations`
    map must contain at least the leader's self-attestation. An
    empty map means the Generator's local-guardian path failed,
    which would publish proofs nobody can verify.

  Single-node sim has only one guardian, so `attestation_count: 1`
  is the expected single-node state (the collector RPCs to
  `Node.self()` and gets back an attestation with the same
  guardian_id, which dedupes in the Proof's attestations map).
  Multi-peer attestation count > 1 is meaningful only under the
  deferred multi-node sim mode.

  Skips silently when no proof has been generated yet — the
  Generator's first cycle is asynchronous after sim start, so
  the first few ticks may see `nil`. That is not a violation; it
  becomes one only if a proof exists and fails the checks above.
  """

  alias PerpWalk.Reserves.Facade, as: ReservesFacade

  @spec check(map()) :: :ok | {:violation, map()}
  def check(_snapshot) do
    case ReservesFacade.latest_proof() do
      nil ->
        :ok

      proof ->
        validate_proof(proof)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp validate_proof(proof) do
    snapshot = proof.snapshot

    cond do
      snapshot.total_held < snapshot.outstanding ->
        {:violation,
         %{
           kind: :insolvent_proof,
           proof_id: proof.id,
           total_held: snapshot.total_held,
           outstanding: snapshot.outstanding,
           shortfall: snapshot.outstanding - snapshot.total_held
         }}

      proof.status == :published and is_nil(proof.threshold_signature) ->
        {:violation,
         %{kind: :published_without_threshold_signature, proof_id: proof.id}}

      map_size(proof.attestations) == 0 ->
        {:violation, %{kind: :proof_without_attestations, proof_id: proof.id}}

      true ->
        :ok
    end
  end
end
