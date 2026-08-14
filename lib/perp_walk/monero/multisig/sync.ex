defmodule PerpWalk.Monero.Multisig.Sync do
  @moduledoc """
  Bidirectional Monero multisig info exchange across federation peers.

  Monero's privacy model hides spent-output state from chain
  observers — including from other multisig participants who didn't
  sign a given transaction. To keep every guardian's wallet view
  consistent, the protocol requires periodic exchange of
  `export_multisig_info` / `import_multisig_info` hex blobs. Without
  this exchange, non-signing participants accumulate phantom
  unspent outputs from spends they didn't participate in, which
  eventually breaks proof-of-reserves attestation rounds because
  guardians can't agree on the held balance.

  This module owns the protocol mechanics: capture the local
  wallet's export, ship it to peers, ingest the peers' exports back.
  The when-to-sync triggers live elsewhere — `Federation.Signer`
  fires it post-spend, `Multisig.Scheduler` fires it periodically.

  Cross-domain access is via `PerpWalk.Monero.Facade`; this module
  itself reaches up into the federation domain only through
  `PerpWalk.Federation.Facade` (peer list + RPC transport), same
  pattern as `Reserves.Attestation.Collector`.
  """

  require Logger

  alias Darks.Multisig
  alias PerpWalk.Federation.Facade, as: FederationFacade

  @default_rpc_timeout_ms 15_000

  @typedoc "Sync trigger context — surfaced in logs for forensic correlation."
  @type trigger :: :manual | :periodic | {:post_spend, binary()}

  @typedoc "Successful sync result."
  @type result :: %{peers_synced: non_neg_integer(), outputs_imported: non_neg_integer()}

  @doc """
  Captures the local wallet's multisig info hex for sharing with
  federation peers. Wraps `Darks.Multisig.export_info/0` and
  normalises the success shape down to the raw hex string.
  """
  @spec local_export() :: {:ok, String.t()} | {:error, term()}
  def local_export do
    case Multisig.export_info() do
      {:ok, %{info: info}} when is_binary(info) -> {:ok, info}
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc """
  Imports peer multisig info hex strings into the local wallet.
  Wraps `Darks.Multisig.import_info/1` and surfaces the count of
  outputs that were reconciled.
  """
  @spec apply_imports([String.t()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def apply_imports(hex_strings) when is_list(hex_strings) do
    # Import each blob independently: the wallet rejects the whole
    # union call when any single blob is malformed, so one broken or
    # compromised peer could otherwise veto every round and stall
    # drift reconciliation until the reserves gate freezes signing.
    Enum.reduce(hex_strings, {0, 0, nil}, fn hex, {imported, failed, _last_reason} ->
      case Multisig.import_info([hex]) do
        {:ok, %{n_outputs: n}} when is_integer(n) ->
          {imported + n, failed, nil}

        {:error, reason} ->
          Logger.warning("Sync: per-peer import failed, reason=#{inspect(reason)}")
          {imported, failed + 1, reason}
      end
    end)
    |> case do
      {_imported, failed, reason} when failed > 0 and failed == length(hex_strings) ->
        # Single-blob callers get the underlying wallet reason (more
        # diagnostic); multi-blob all-fail collapses to a marker.
        if length(hex_strings) == 1, do: {:error, reason}, else: {:error, :all_imports_failed}

      {imported, 0, _last_reason} ->
        {:ok, imported}

      {imported, failed, _last_reason} ->
        Logger.warning("Sync: partial import, failed=#{failed}/#{length(hex_strings)}")
        {:ok, imported}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc """
  Bidirectional sync with every federation peer in a single round.

  Each peer receives the local export AND returns its own export in
  one RPC round-trip. The collected peer exports are then imported
  into the local wallet. Peer failures degrade gracefully — a peer
  that times out or errors is logged and skipped; the round still
  reconciles against the peers that did respond.

  Returns `{:ok, %{peers_synced: N, outputs_imported: M}}` with N
  the count of peers that successfully exchanged and M the count of
  outputs reconciled in the local wallet.

  Trigger context is surfaced in logs via the `:triggered_by` option
  so post-mortem analysis can correlate sync attempts with the event
  that fired them (post-spend, periodic, manual).
  """
  @spec sync_with_peers(keyword()) :: {:ok, result()} | {:error, term()}
  def sync_with_peers(opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, rpc_timeout_ms())
    trigger = Keyword.get(opts, :triggered_by, :manual)

    Logger.info("Sync: starting, triggered_by=#{inspect(trigger)}")

    with {:ok, our_info} <- local_export() do
      peers = FederationFacade.peer_nodes()

      peer_exports =
        peers
        |> Enum.map(fn peer -> {peer, exchange_with_peer(peer, our_info, timeout)} end)
        |> Enum.flat_map(&filter_successful/1)

      finish_round(peer_exports, length(peers), trigger)
    end
  end

  # --- Internal ---

  defp finish_round([], _peer_count, trigger) do
    Logger.warning("Sync: no peer responses, triggered_by=#{inspect(trigger)}")

    {:ok, %{peers_synced: 0, outputs_imported: 0}}
  end

  defp finish_round(peer_exports, peer_count, trigger) do
    case apply_imports(peer_exports) do
      {:ok, n_outputs} ->
        Logger.info(
          "Sync: complete, peers_synced=#{length(peer_exports)}/#{peer_count}, " <>
            "outputs_imported=#{n_outputs}, triggered_by=#{inspect(trigger)}"
        )

        {:ok, %{peers_synced: length(peer_exports), outputs_imported: n_outputs}}

      {:error, reason} = err ->
        Logger.warning(
          "Sync: import failed, peer_count=#{length(peer_exports)}, " <>
            "reason=#{inspect(reason)}, triggered_by=#{inspect(trigger)}"
        )

        err
    end
  end

  defp exchange_with_peer(peer, our_info, timeout) do
    request = FederationFacade.sign_rpc_request(:multisig_info_exchange, our_info)

    case FederationFacade.rpc_call_peer(peer, :multisig_info_exchange, request, timeout) do
      {:ok, response} ->
        unwrap_response(response, request.nonce)

      {:badrpc, reason} ->
        {:error, {:rpc_failed, reason}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_response, other}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp unwrap_response(response, nonce) do
    case FederationFacade.verify_rpc_response(response, :multisig_info_exchange, nonce) do
      {:ok, {:ok, peer_info}} when is_binary(peer_info) -> {:ok, peer_info}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, other} -> {:error, {:malformed_response, other}}
      {:error, reason} -> {:error, {:response_auth_failed, reason}}
    end
  end

  defp filter_successful({_peer, {:ok, info}}), do: [info]

  defp filter_successful({peer, {:error, reason}}) do
    Logger.info("Sync: peer exchange failed, peer=#{inspect(peer)}, reason=#{inspect(reason)}")

    []
  end

  defp rpc_timeout_ms do
    :perpwalk
    |> Application.get_env(:monero, [])
    |> Keyword.get(:multisig_sync_timeout_ms, @default_rpc_timeout_ms)
  end
end
