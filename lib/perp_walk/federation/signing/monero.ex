defmodule PerpWalk.Federation.Signing.Monero do
  @moduledoc """
  Real Monero multisig signing backend for `Federation.Signer`.

  PERP WALK runs as a 2-of-3 federation. Every payout is a Monero
  multisig transaction that requires two of three signatures. The
  backend orchestrates that round on behalf of the storage leader's
  Signer:

  1. **Sync output state.** Each peer reports its view of unspent
     outputs via `Darks.Multisig.export_info/0`. The leader collects
     them and feeds the union into `import_info/1` so the local
     wallet sees what the federation as a whole has.
  2. **Build the unsigned tx.** `Darks.TxBuilder.build_payout/2`
     produces the params, and `Darks.Client.transfer/1` runs the
     RPC with `do_not_relay: true`. For multisig wallets the
     response carries `multisig_txset` — the partially-signed
     (1-of-3) tx blob.
  3. **Collect a peer signature.** `:rpc.call(peer, Darks.Multisig,
     :sign, [hex])` to peers in order. The first responsive peer
     wins; that one signature pushes the tx to 2-of-3 — threshold
     reached. We do NOT collect both peers' signatures; one is
     sufficient by construction. This is the anti-fragile property
     of the federation: any one peer can be down for maintenance
     and payouts keep flowing on the remaining two.
  4. **Submit.** `Darks.Multisig.submit/1` broadcasts the
     fully-signed tx and returns the on-chain txid.

  Conforms to the `signing_backend` contract expected by
  `Federation.Signer`:

      (Payout.t()) -> {:ok, txid :: String.t()} | {:error, term()}

  ## Failure modes

  - `{:error, {:export_failed, _}}` — local wallet RPC unreachable
  - `{:error, {:sync_failed, _}}` — `import_info` rejected the union
  - `{:error, :no_multisig_txset_returned}` — wallet didn't return
    multisig data; usually means the wallet isn't in multisig mode
    (federation bootstrap was never run)
  - `{:error, :no_peer_signature_available}` — every peer either
    timed out, errored, or is unreachable. Caller leaves the
    request in `:rules_passed` for the next tick — this is the
    normal "one peer is down for maintenance" path.
  - `{:error, {:submit_ambiguous, reason}}` — submit RPC returned an
    outcome we can't classify (timeout, transport error, 5xx, null
    result). The tx MAY have been broadcast. Signer transitions the
    payout to `:settlement_unknown` (no auto-retry) so an operator
    reconciles against wallet transfer history before any resend.
    Blindly retrying with a fresh coin selection here is the classic
    double-payout foot-gun.

  ## Config

  Injectable seam: `Darks` already supports `:darks, :client`
  injection for its mock client. Callers can override there;
  production runs the real `Darks.Client`.
  """

  require Logger

  alias Darks.{Client, Multisig, TxBuilder}
  alias PerpWalk.Federation.Facade, as: FederationFacade
  alias PerpWalk.Federation.{Payout, Signer}
  alias PerpWalk.Federation.RPC.{Auth, Peer}

  @export_timeout_ms 15_000
  @sign_timeout_ms 60_000

  @doc """
  Drives one multisig signing round for the given Payout.
  Returns `{:ok, txid}` on success, `{:error, reason}` otherwise.

  Idempotency: this function does not mutate request state — that
  is handled by `Federation.Signer` based on this return value.
  Re-invocation on the same request is safe; Monero's wallet
  detects double-spend at submit time.
  """
  @spec sign(Payout.t()) :: {:ok, String.t()} | {:error, term()}
  def sign(%Payout{} = request) do
    # Defensive guard. The Signer process already checks `halted?` before
    # invoking the backend, but this backend is an exposed public function:
    # any code path that reaches `sign/1` directly (mistake, refactor,
    # operator iex) MUST also honour the halt. Refuse here, fail-closed.
    #
    # Halt is re-checked between each major step so an operator halt
    # issued mid-flight still aborts before submit. The Monero
    # `submit_multisig` RPC itself is atomic on the wallet side, so
    # the last check before submit/1 is the final safe abort point.
    with :ok <- ensure_not_halted(),
         :ok <- sync_multisig_state(),
         :ok <- ensure_not_halted(),
         {:ok, unsigned_hex} <- build_unsigned_tx(request),
         :ok <- ensure_not_halted(),
         {:ok, signed_hex} <- collect_peer_signature(unsigned_hex),
         :ok <- ensure_not_halted() do
      submit(signed_hex)
    end
  end

  defp ensure_not_halted do
    # Read the halt flag via persistent_term — `Signer.halted?/0` is a
    # GenServer.call, and when this backend is invoked from inside the
    # Signer's own tick (the production path) calling back into the
    # Signer deadlocks for 5 s before timing out. The Signer publishes
    # its halt state on every halt/resume transition so this read is
    # both lock-free and accurate.
    if Signer.halted_snapshot() do
      Logger.warning("Monero: sign refused, reason=signing_halted")
      {:error, :signing_halted}
    else
      :ok
    end
  end

  # --- Multisig State Sync ---

  defp sync_multisig_state do
    case Multisig.export_info() do
      {:ok, %{info: my_info}} ->
        case Multisig.import_info([my_info]) do
          {:ok, _} ->
            import_peer_infos(collect_peer_infos())

          {:error, reason} ->
            {:error, {:sync_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:export_failed, reason}}
    end
  end

  # Peers import one blob at a time — a malformed or oversized export
  # vetoes only itself, never the whole round (a union import rejects
  # every blob when any single one is bad). Returns :ok regardless;
  # the reserves drift gate covers persistent divergence.
  defp import_peer_infos(infos) do
    Enum.each(infos, fn info ->
      case Multisig.import_info([info]) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("Monero: peer multisig info import failed, reason=#{inspect(reason)}")
      end
    end)

    :ok
  end

  defp collect_peer_infos do
    Enum.flat_map(peer_nodes(), fn peer ->
      case rpc_export_info(peer) do
        {:ok, %{info: info}} ->
          [info]

        other ->
          Logger.warning("Monero: peer export_info failed, peer=#{inspect(peer)}, reason=#{inspect(other)}")

          []
      end
    end)
  end

  # HMAC-protected variant of `:rpc.call(peer, Multisig, :export_info, [])`.
  # Routes through `Peer.export_info/1` with a signed request
  # and verifies the signed response before returning the result.
  defp rpc_export_info(peer) do
    request = Auth.sign_request(:export_info, [])

    case :rpc.call(peer, Peer, :export_info, [request], @export_timeout_ms) do
      {:ok, response} when is_map(response) ->
        case Auth.verify_response(response, :export_info, request.nonce) do
          {:ok, result} ->
            result

          {:error, reason} ->
            Logger.error(
              "Monero: peer export_info response auth failed, peer=#{inspect(peer)}, reason=#{inspect(reason)}"
            )

            {:error, {:auth_failed, reason}}
        end

      {:badrpc, reason} ->
        {:error, {:badrpc, reason}}

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected, other}}
    end
  end

  # --- Unsigned Tx ---

  defp build_unsigned_tx(%Payout{destination: dest, amount_piconeros: amt}) do
    with {:ok, params} <- TxBuilder.build_payout(dest, amt),
         {:ok, result} <- darks_client().transfer(params) do
      case result.multisig_txset do
        nil -> {:error, :no_multisig_txset_returned}
        hex when is_binary(hex) -> {:ok, hex}
      end
    else
      {:error, reason} -> classify_build_error(reason)
    end
  end

  # Wallet-side rejections at tx-build time fall into two classes:
  #
  # - **Permanent**: the destination address is invalid (typo passed
  #   the regex but fails wallet-side base58 + Keccak checksum), the
  #   amount is malformed, or the fee is impossibly low. Retrying
  #   with the same request will fail forever — a payout stuck here
  #   holds its uniqueness slot indefinitely, blocking legitimate
  #   re-issue by the source. Route to `{:permanent_failure, _}`
  #   so the Signer transitions the payout to `:failed` (terminal)
  #   instead of unbounded backoff-retry.
  # - **Transient**: wallet unreachable, output-not-yet-unlocked,
  #   temporary daemon issue. The default error passes through and
  #   the Signer records a retry with backoff.
  defp classify_build_error({:rpc_error, %{"message" => msg}} = reason)
       when is_binary(msg) do
    down = String.downcase(msg)

    cond do
      String.contains?(down, "invalid address") ->
        {:error, {:permanent_failure, {:invalid_destination, msg}}}

      String.contains?(down, "invalid_address") ->
        {:error, {:permanent_failure, {:invalid_destination, msg}}}

      String.contains?(down, "address is not") ->
        {:error, {:permanent_failure, {:invalid_destination, msg}}}

      String.contains?(down, "invalid destination") ->
        {:error, {:permanent_failure, {:invalid_destination, msg}}}

      true ->
        {:error, reason}
    end
  end

  defp classify_build_error(reason), do: {:error, reason}

  defp darks_client, do: Application.get_env(:darks, :client, Client)

  # --- Peer Signature Collection (anti-fragile) ---

  defp collect_peer_signature(unsigned_hex) do
    Enum.reduce_while(peer_nodes(), {:error, :no_peer_signature_available}, fn peer, _acc ->
      case rpc_sign(peer, unsigned_hex) do
        {:ok, signed_hex} ->
          Logger.info("Monero: peer signed, peer=#{inspect(peer)}")
          {:halt, {:ok, signed_hex}}

        {:error, reason} ->
          Logger.warning("Monero: peer sign failed, peer=#{inspect(peer)}, reason=#{inspect(reason)}")

          {:cont, {:error, :no_peer_signature_available}}
      end
    end)
  end

  # HMAC-protected variant of `:rpc.call(peer, Multisig, :sign, [hex])`.
  # The HMAC binds the unsigned_hex into the signature so a captured
  # request can't be replayed against a different unsigned tx.
  defp rpc_sign(peer, unsigned_hex) do
    request = Auth.sign_request(:sign, unsigned_hex)

    case :rpc.call(peer, Peer, :sign, [request], @sign_timeout_ms) do
      {:ok, response} when is_map(response) ->
        case Auth.verify_response(response, :sign, request.nonce) do
          {:ok, {:ok, %{tx_data_hex: signed}}} ->
            {:ok, signed}

          {:ok, {:error, reason}} ->
            {:error, reason}

          {:ok, other} ->
            {:error, {:unexpected, other}}

          {:error, reason} ->
            Logger.error("Monero: peer sign response auth failed, peer=#{inspect(peer)}, reason=#{inspect(reason)}")

            {:error, {:auth_failed, reason}}
        end

      {:badrpc, reason} ->
        {:error, {:badrpc, reason}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected, other}}
    end
  end

  # --- Submit ---
  #
  # Submit is the one-way step: once the tx blob is handed to the
  # wallet's `submit_multisig` RPC, the wallet may relay it to the
  # daemon before the caller sees the response. Any error whose
  # semantics don't unambiguously mean "the tx never left the wallet"
  # is `submit_ambiguous`. The Signer treats that as unknown-outcome
  # and refuses to auto-retry (which would build a fresh coin
  # selection and double-pay if the earlier submit did land).
  #
  # Definitive (never-broadcast, safe to retry the round):
  #   - `:auth_failed`                         — pre-send auth failure
  #   - `{:connection_error, :econnrefused}`   — daemon offline; TCP
  #                                              never established
  #   - `{:connection_error, :nxdomain}`       — DNS pre-connect
  #   - `{:http_error, s}` for s in 400..499   — wallet rejected the
  #                                              request without
  #                                              relaying
  #
  # Ambiguous (may or may not be on-chain):
  #   - `{:connection_error, :timeout}`        — RPC could have
  #                                              submitted before
  #                                              response was lost
  #   - `{:connection_error, other}`           — mid-flight transport
  #                                              faults are ambiguous
  #                                              by construction
  #   - `{:http_error, s}` for s in 500..599   — wallet may have relayed
  #                                              before erroring
  #   - `:no_txid_returned` / `:null_result`   — wallet acknowledged
  #                                              but gave no txid
  #   - `{:rpc_error, _}`                      — wallet-side RPC error;
  #                                              some codes indicate
  #                                              post-relay failures
  #                                              (fee too low observed
  #                                              only after broadcast)
  defp submit(signed_hex) do
    case Multisig.submit(signed_hex) do
      {:ok, %{tx_hash_list: [txid | _]}} when is_binary(txid) ->
        {:ok, txid}

      {:ok, _} ->
        {:error, {:submit_ambiguous, :no_txid_returned}}

      {:error, reason} ->
        classify_submit_error(reason)
    end
  end

  defp classify_submit_error(:auth_failed = reason), do: {:error, reason}

  defp classify_submit_error({:connection_error, :econnrefused} = reason),
    do: {:error, reason}

  defp classify_submit_error({:connection_error, :nxdomain} = reason),
    do: {:error, reason}

  defp classify_submit_error({:http_error, status} = reason)
       when is_integer(status) and status >= 400 and status < 500,
       do: {:error, reason}

  defp classify_submit_error(:null_result), do: {:error, {:submit_ambiguous, :null_result}}

  defp classify_submit_error(:no_txid_returned),
    do: {:error, {:submit_ambiguous, :no_txid_returned}}

  defp classify_submit_error(reason), do: {:error, {:submit_ambiguous, reason}}

  # --- Helpers ---

  defp peer_nodes, do: FederationFacade.peer_nodes()
end
