defmodule PerpWalkWeb.ReservesController do
  @moduledoc """
  Public proof-of-reserves endpoint. Returns the latest reserve
  proof — outstanding liabilities (worst-case payout obligations
  from non-terminal positions) and held assets (federation
  multisig wallet balance).

  Read-only. No authentication. No user-identifying data — only
  platform-aggregate state. Mounted under the `:api` pipeline so
  the request gate (Tor circuit ID + rate limiting) still applies.

  All `_piconeros`-suffixed values are atomic units of XMR
  (1 XMR = 1_000_000_000_000 piconero).
  """

  use PerpWalkWeb, :controller

  alias PerpWalk.Nostr.Facade, as: NostrFacade
  alias PerpWalk.Reserves.Facade, as: ReservesFacade
  alias PerpWalk.Reserves.Snapshot

  @doc "GET /api/reserves — latest proof."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    proof = format_proof(ReservesFacade.latest_proof())

    conn
    |> put_status(:ok)
    |> json(Map.merge(proof, verifier_keys()))
  end

  @doc "GET /api/reserves/history — paginated history."
  @spec history(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def history(conn, params) do
    limit = parse_limit(params)
    proofs = ReservesFacade.proof_history(limit)

    conn
    |> put_status(:ok)
    |> json(
      Map.merge(
        %{
          proofs: Enum.map(proofs, &format_proof/1),
          limit: limit,
          cursor: nil
        },
        verifier_keys()
      )
    )
  end

  # --- Private Helpers ---

  defp format_proof(nil) do
    piconeros = Snapshot.to_piconeros(nil)

    %{
      ratio: format_ratio(piconeros.ratio),
      held_piconeros: piconeros.held_piconeros,
      outstanding_piconeros: piconeros.outstanding_piconeros,
      proof: nil,
      attestation_count: 0,
      threshold_signature: nil,
      nostr_event_id: nil,
      timestamp: DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp format_proof(%Vault.Proof{snapshot: snap} = proof) do
    piconeros = Snapshot.to_piconeros(snap)

    %{
      ratio: format_ratio(piconeros.ratio),
      held_piconeros: piconeros.held_piconeros,
      outstanding_piconeros: piconeros.outstanding_piconeros,
      proof: safe_hex(proof.id),
      attestation_count: map_size(proof.attestations),
      threshold_signature: format_threshold_signature(proof),
      nostr_event_id: safe_hex(proof.publish_ref),
      timestamp: DateTime.to_iso8601(snap.captured_at)
    }
  end

  # Two pubkeys, two curves, two purposes. Calling them out
  # explicitly so a verifier never tries to validate the Ed25519
  # threshold_signature with the secp256k1 nostr pubkey (or vice
  # versa). Each is hex-encoded; nil if the corresponding key is
  # not yet loaded (pre-first-cycle boot).
  defp verifier_keys do
    %{
      verifier: %{
        nostr_publisher_pubkey: hex_or_nil(NostrFacade.venue_pubkey()),
        nostr_pubkey_curve: "secp256k1-bip340",
        guardian_signer_pubkey: hex_or_nil(ReservesFacade.guardian_pubkey()),
        guardian_pubkey_curve: "ed25519",
        threshold_signature_input: "Vault.Proof.canonical_bytes/1"
      }
    }
  end

  defp hex_or_nil({:ok, hex}), do: hex
  defp hex_or_nil({:error, _}), do: nil

  defp format_ratio(:infinity), do: 1.0
  defp format_ratio(ratio) when is_number(ratio), do: ratio

  defp format_threshold_signature(%{threshold_signature: nil}), do: nil

  defp format_threshold_signature(%{threshold_signature: sig}) do
    Base.encode16(sig, case: :lower)
  end

  defp safe_hex(nil), do: nil
  defp safe_hex(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)
  defp safe_hex(other), do: to_string(other)

  defp parse_limit(params) do
    case Map.get(params, "limit") do
      nil ->
        20

      val when is_binary(val) ->
        case Integer.parse(val) do
          {n, ""} -> min(max(n, 1), 100)
          _ -> 20
        end

      val when is_integer(val) ->
        min(max(val, 1), 100)

      _ ->
        20
    end
  end
end
