defmodule PerpWalk.Federation.Bootstrap do
  @moduledoc """
  Operator-driven Monero multisig wallet setup ceremony.

  Orchestrates the Monero multisig protocol across the federation:

    0. **create** — each guardian calls `Darks.Multisig.create_wallet/2`
       to ensure an empty wallet file exists in `--wallet-dir` and
       is the currently-open wallet on its wallet RPC. Idempotent:
       a pre-existing wallet under the same filename is accepted
       (the RPC error `-21 wallet_already_exists` is squashed to
       `:ok`), so re-running the ceremony after a partial failure
       does not require a manual `rm` per guardian.
    1. **prepare** — each guardian calls `Darks.Multisig.prepare/0`
       to produce a v1 info string (its public spend share).
    2. **make** — each guardian receives the other guardians' v1
       strings and calls `Darks.Multisig.make(2, peer_v1_infos)` to
       produce a v2 string. For a 2-of-3 wallet, an additional round
       is required because `M < N - 1`.
    3. **exchange** — each guardian receives the other guardians'
       v2 strings and calls
       `Darks.Multisig.exchange_keys(peer_v2_infos)` (the v0.18
       replacement for `finalize_multisig`). Each guardian ends up
       with the same shared address; that address is the pool
       wallet for federation outflows.

  The ceremony runs from the operator's iex session on whichever
  guardian they're on. We use `:rpc.call/4` against the other
  guardians' BEAM nodes to invoke the Darks RPC primitives on each
  guardian's wallet RPC. No new state machine — the protocol is a
  deterministic sequence of RPC calls, not a long-running coordinator.

  Run-once: Monero wallets track multisig state internally, so a
  re-run requires resetting all three wallets to a fresh state
  first. If the ceremony fails midway, the operator must wipe
  wallet state on each guardian before retrying.

  ## Usage

      iex> PerpWalk.Federation.Bootstrap.run()
      {:ok, "4ABC...shared multisig address..."}

  ## Testing

  The Darks client is swappable via `:darks, :client` config — set
  to a stub module to drive the ceremony without real wallet RPCs.
  """

  require Logger

  alias Darks.Multisig
  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents
  alias PerpWalk.Federation.RPC.{Auth, Peer}

  @doc """
  Executes the multisig setup ceremony across all guardians.

  Returns `{:ok, shared_address}` if every guardian converged on
  the same multisig address, or `{:error, reason}` describing the
  failure phase.

  Refuses to run when `n=1` (single-guardian mode) — the ceremony
  only makes sense in a federation.
  """
  @spec run() :: {:ok, String.t()} | {:error, term()}
  @spec run(keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 2)
    nodes = Keyword.get_lazy(opts, :nodes, &federation_nodes/0)
    wallet_filename = Keyword.get(opts, :wallet_filename, "perpwalk-federation")
    wallet_password = Keyword.get(opts, :wallet_password, "")

    with :ok <- refuse_if_bootstrapped(),
         :ok <- validate(nodes, threshold),
         :ok <- validate_wallet_password(wallet_password) do
      Logger.info("Bootstrap: starting ceremony, threshold=#{threshold}, nodes=#{length(nodes)}")

      with {:ok, _} <- phase_create(nodes, wallet_filename, wallet_password),
           {:ok, infos_v1} <- phase_prepare(nodes),
           {:ok, infos_v2} <- phase_make(nodes, threshold, infos_v1),
           {:ok, addresses} <- phase_exchange(nodes, infos_v2),
           {:ok, address} <- verify_convergence(addresses) do
        Logger.info("Bootstrap: ceremony complete, shared_address=#{address}")

        {:ok, address}
      end
    end
  end

  # Refuses production bootstrap with an empty wallet password. An
  # unencrypted multisig wallet file on disk means two of three
  # guardian disks (or two of three server backups, or two of three
  # inventory drives) = full custody for the attacker who holds them.
  # Enforce at bootstrap so no fresh federation gets built without
  # per-guardian at-rest encryption. Non-prod (dev/test) tolerates
  # empty for fixture simplicity.
  defp validate_wallet_password("") do
    if Application.get_env(:perpwalk, :env) == :prod do
      {:error, :wallet_password_required_in_prod}
    else
      :ok
    end
  end

  defp validate_wallet_password(pw) when is_binary(pw) and byte_size(pw) > 0, do: :ok
  defp validate_wallet_password(_), do: {:error, :invalid_wallet_password}

  # Local-node fast-path RPC in `rpc/4` skips `Peer.bootstrap_*`,
  # which is the wall that protects an already-bootstrapped node
  # from running the ceremony a second time. Re-running on a node
  # whose wallet already holds key shares would mutate that wallet
  # into an unrelated multisig state and brick the on-chain pool.
  # Mirror the same gate here so the local node refuses regardless
  # of whether the call entered via :rpc.call or direct apply.
  defp refuse_if_bootstrapped do
    case Application.get_env(:perpwalk, :multisig_address) do
      nil ->
        :ok

      addr when is_binary(addr) ->
        Logger.warning(
          "Bootstrap: refusing to run, reason=federation_already_bootstrapped, " <>
            "address=#{addr}, recovery=reset_all_wallets_and_unset_multisig_address"
        )

        {:error, {:bootstrap_complete, addr}}
    end
  end

  # --- Phases ---

  defp phase_create(nodes, filename, password) do
    Logger.info("Bootstrap: phase=create, filename=#{filename}, nodes=#{length(nodes)}")

    invoke_each(nodes, Multisig, :create_wallet, [filename, password])
    |> case do
      {:ok, results} -> {:ok, results}
      {:error, reason} -> {:error, {:create_wallet_failed, reason}}
    end
  end

  defp phase_prepare(nodes) do
    Logger.info("Bootstrap: phase=prepare, nodes=#{length(nodes)}")

    invoke_each(nodes, Multisig, :prepare, [])
    |> case do
      {:ok, results} -> {:ok, Enum.map(results, fn {_node, %{multisig_info: info}} -> info end)}
      {:error, reason} -> {:error, {:prepare_failed, reason}}
    end
  end

  defp phase_make(nodes, threshold, infos_v1) do
    Logger.info("Bootstrap: phase=make, threshold=#{threshold}")

    indexed_nodes = Enum.with_index(nodes)
    indexed_infos = Enum.with_index(infos_v1)

    args_per_node =
      Enum.map(indexed_nodes, fn {_node, idx} ->
        peer_infos = peer_strings(indexed_infos, idx)
        [threshold, peer_infos]
      end)

    invoke_each_with_args(nodes, Multisig, :make, args_per_node)
    |> case do
      {:ok, results} ->
        {:ok, Enum.map(results, fn {_node, %{multisig_info: info}} -> info end)}

      {:error, reason} ->
        {:error, {:make_failed, reason}}
    end
  end

  # M-of-N multisig setup needs `N - M` exchange rounds after make
  # for any M < N. Each round consumes peer info from the previous
  # round and may produce a non-empty address (final) or a fresh
  # `multisig_info` for the next round. We loop until every node
  # reports a non-empty address. The cap is `length(nodes)` rounds —
  # more than `N - 1` is a protocol-level bug, not a transient.
  defp phase_exchange(nodes, infos) do
    exchange_round(nodes, infos, 1, length(nodes))
  end

  defp exchange_round(_nodes, _infos, round, max_rounds) when round > max_rounds do
    {:error, {:exchange_failed, :max_rounds_exceeded}}
  end

  defp exchange_round(nodes, infos, round, max_rounds) do
    Logger.info("Bootstrap: phase=exchange, round=#{round}")

    indexed_nodes = Enum.with_index(nodes)
    indexed_infos = Enum.with_index(infos)

    args_per_node =
      Enum.map(indexed_nodes, fn {_node, idx} ->
        [peer_strings(indexed_infos, idx)]
      end)

    case invoke_each_with_args(nodes, Multisig, :exchange_keys, args_per_node) do
      {:ok, results} ->
        addresses = Enum.map(results, fn {_node, %{address: addr}} -> addr end)

        if Enum.all?(addresses, &(&1 != "")) do
          {:ok, addresses}
        else
          next_infos = Enum.map(results, fn {_node, %{multisig_info: info}} -> info end)
          exchange_round(nodes, next_infos, round + 1, max_rounds)
        end

      {:error, reason} ->
        {:error, {:exchange_failed, reason}}
    end
  end

  defp verify_convergence([first | rest] = addresses) do
    if Enum.all?(rest, &(&1 == first)) do
      {:ok, first}
    else
      Logger.error("Bootstrap: address mismatch, addresses=#{inspect(addresses)}")

      EventBus.publish(%FederationEvents.BootstrapAddressMismatch{
        addresses: addresses,
        timestamp: DateTime.utc_now()
      })

      {:error, :address_mismatch}
    end
  end

  # --- Internal Helpers ---

  defp validate(nodes, threshold) do
    cond do
      length(nodes) < 2 ->
        {:error, :single_node_mode}

      threshold < 1 or threshold > length(nodes) ->
        {:error, :invalid_threshold}

      true ->
        :ok
    end
  end

  defp federation_nodes do
    config = Cartel.Supervisor.config()

    config.peer_nodes
    |> Map.values()
    |> Enum.sort()
    |> List.insert_at(0, Node.self())
    |> Enum.uniq()
  end

  # Calls module.fun(args) on every node. Returns {:ok, [{node, result}, ...]}
  # or {:error, {:rpc, node, reason}} on the first failure.
  defp invoke_each(nodes, module, fun, args) do
    nodes
    |> Enum.reduce_while([], fn node, acc ->
      case rpc(node, module, fun, args) do
        {:ok, result} -> {:cont, [{node, result} | acc]}
        {:error, reason} -> {:halt, {:error, {:rpc, node, reason}}}
      end
    end)
    |> case do
      {:error, _} = err -> err
      results when is_list(results) -> {:ok, Enum.reverse(results)}
    end
  end

  # Like invoke_each/4 but each node gets a different argument list.
  defp invoke_each_with_args(nodes, module, fun, args_per_node) do
    nodes
    |> Enum.zip(args_per_node)
    |> Enum.reduce_while([], fn {node, args}, acc ->
      case rpc(node, module, fun, args) do
        {:ok, result} -> {:cont, [{node, result} | acc]}
        {:error, reason} -> {:halt, {:error, {:rpc, node, reason}}}
      end
    end)
    |> case do
      {:error, _} = err -> err
      results when is_list(results) -> {:ok, Enum.reverse(results)}
    end
  end

  defp rpc(node, module, fun, args) when node == node() do
    apply(module, fun, args)
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  defp rpc(node, Multisig, fun, args) do
    method = bootstrap_method(fun)
    request = Auth.sign_request(method, normalise_args(fun, args))

    case :rpc.call(node, Peer, method, [request], 30_000) do
      {:ok, response} when is_map(response) ->
        case Auth.verify_response(response, method, request.nonce) do
          {:ok, result} ->
            result

          {:error, reason} ->
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

  defp bootstrap_method(:create_wallet), do: :bootstrap_create_wallet
  defp bootstrap_method(:prepare), do: :bootstrap_prepare
  defp bootstrap_method(:make), do: :bootstrap_make
  defp bootstrap_method(:exchange_keys), do: :bootstrap_exchange_keys

  defp normalise_args(:create_wallet, [filename, password]), do: {filename, password}
  defp normalise_args(:prepare, []), do: nil
  defp normalise_args(:make, [threshold, infos]), do: {threshold, infos}
  defp normalise_args(:exchange_keys, [infos]), do: infos

  defp peer_strings(indexed_infos, exclude_idx) do
    indexed_infos
    |> Enum.reject(fn {_info, idx} -> idx == exclude_idx end)
    |> Enum.map(fn {info, _idx} -> info end)
  end
end
