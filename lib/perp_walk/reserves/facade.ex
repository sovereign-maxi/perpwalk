defmodule PerpWalk.Reserves.Facade do
  @moduledoc """
  Published Language facade for the Reserves bounded context.

  All `_piconeros`-suffixed values are atomic units of XMR
  (1 XMR = 1_000_000_000_000 piconero). Internally this layer reads
  Vault types whose field names use the legacy `_sats` suffix —
  the integer math is identical; only the suffix is unit-specific.
  Translation to piconero-named keys happens here at the public
  boundary so callers never see the misleading sats naming.

  ## Surfaces

  Three independent verification paths:

    - `/api/reserves` HTTP endpoint — current proof, queryable
      anytime via Tor
    - Nostr NIP-33 replaceable events (kind 30078) — tamper-evident
      historical record, published to configured relays each cycle
    - On-chain federation multisig wallet — the ground truth for
      asset balance
  """

  alias PerpWalk.Markets.Facade, as: MarketsFacade
  alias PerpWalk.Reserves.Snapshot
  alias PerpWalk.Reserves.Source

  @type solvency_status :: :active | :pending

  @type solvency :: %{
          status: solvency_status(),
          pct: non_neg_integer(),
          held_piconeros: non_neg_integer(),
          outstanding_piconeros: non_neg_integer(),
          delta_piconeros: integer(),
          title: String.t()
        }

  @doc """
  Returns the current solvency snapshot. `:pending` until the first
  proof is generated; `:active` thereafter with held / outstanding /
  delta in piconeros.

  Both the admin dashboard and the public reserves controller call
  this same function.
  """
  @spec solvency() :: solvency()
  def solvency do
    proof = latest_proof()
    snapshot = if proof, do: proof.snapshot, else: nil
    piconeros = Snapshot.to_piconeros(snapshot)

    if snapshot do
      pct = Snapshot.solvency_pct(piconeros)

      %{
        status: :active,
        pct: pct,
        held_piconeros: piconeros.held_piconeros,
        outstanding_piconeros: piconeros.outstanding_piconeros,
        delta_piconeros: piconeros.delta_piconeros,
        title: "Solvency: #{pct}%"
      }
    else
      pending_solvency("awaiting first proof")
    end
  rescue
    _ -> pending_solvency("unavailable")
  end

  defp pending_solvency(suffix) do
    %{
      status: :pending,
      pct: 0,
      held_piconeros: 0,
      outstanding_piconeros: 0,
      delta_piconeros: 0,
      title: "Solvency: #{suffix}"
    }
  end

  @doc "Returns the latest reserve proof, or `nil` if none generated yet."
  @spec latest_proof() :: Vault.Proof.t() | nil
  def latest_proof do
    Vault.Generator.latest()
  end

  @doc "Returns up to `limit` recent proofs, most recent first."
  @spec proof_history(pos_integer()) :: [Vault.Proof.t()]
  def proof_history(limit) when is_integer(limit) and limit > 0 do
    Vault.Generator.history(limit)
  end

  @doc """
  Cumulative platform revenue (slashed dispute stakes + forfeited
  creator deposits). Surfaced alongside reserves for completeness on
  admin dashboards.
  """
  @spec platform_revenue_piconeros() :: non_neg_integer()
  def platform_revenue_piconeros do
    MarketsFacade.federation_ledger().total_piconeros
  end

  @doc """
  Captures the current reserves snapshot — held vs outstanding
  piconeros as observed by this guardian. Cross-domain callers
  (federation RPC peer verification, attestation collection) reach
  the snapshot capture through this facade instead of touching
  `Vault.Snapshot` or `Reserves.Source` directly.
  """
  @spec capture_snapshot() :: Vault.Snapshot.t()
  def capture_snapshot do
    Vault.Snapshot.capture(Source)
  end

  @doc """
  Returns the hex-encoded Ed25519 guardian pubkey of the issuing
  node — the one whose private half signs each proof's
  `threshold_signature` field over `Vault.Proof.canonical_bytes/1`.
  This is a different curve and a different key from the Nostr
  publishing pubkey; the two surfaces serve different verification
  paths and should never be confused.
  """
  @spec guardian_pubkey() :: {:ok, String.t()} | {:error, :not_available}
  def guardian_pubkey do
    case Vault.Generator.guardian_pubkey() do
      {:ok, pub} when is_binary(pub) -> {:ok, Base.encode16(pub, case: :lower)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :not_available}
  end
end
