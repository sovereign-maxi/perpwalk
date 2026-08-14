defmodule PerpWalk.Monero.Facade do
  @moduledoc """
  Published Language facade for the Monero bounded context.

  The single entry point for everything that touches the wallet RPC.
  Wraps `Darks.Client` so callers depend on the PERP WALK domain
  surface, not on the underlying package — gives us a single seam
  if we ever swap RPC clients, mock for tests, or add caching.

  Crash-safe: if the wallet RPC is unreachable or `PerpWalk.Finch` isn't
  running, the calls return `{:error, reason}` instead of letting the
  exit propagate. Telemetry's `:monero_unreachable` rule polls
  `health_check/0` to surface RPC outages on the admin dashboard.
  """

  require Logger

  @doc """
  Pings the wallet RPC. Returns `:ok` if the daemon answers,
  `{:error, reason}` otherwise. Used by the Telemetry alert rule
  and by future startup checks.
  """
  @spec health_check() :: :ok | {:error, term()}
  def health_check do
    Darks.Client.health_check()
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Wallet balance for the primary account, in piconero
  (1 XMR = 1_000_000_000_000 piconero).
  """
  @spec balance() :: {:ok, %{balance: non_neg_integer(), unlocked_balance: non_neg_integer()}} | {:error, term()}
  def balance do
    Darks.Client.get_balance(0)
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Primary account address of the currently open wallet. For PERP
  WALK production this is the 2-of-3 federation multisig address;
  used by `Federation.Facade.verify_multisig_address/0` to catch
  wallet-rpc opening the wrong wallet after a reboot.
  """
  @spec address() :: {:ok, String.t()} | {:error, term()}
  def address do
    case Darks.Client.get_address(0) do
      {:ok, %{"address" => addr}} when is_binary(addr) -> {:ok, addr}
      {:ok, _} -> {:error, :unexpected_response}
      error -> error
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Creates a fresh subaddress on the primary account. Each trade
  Each trade gets its own subaddress so on-chain analysis can't
  link a user's trades by reused address.

  Returns `{:ok, %{address: String.t(), address_index: non_neg_integer()}}`
  on success.
  """
  @spec create_subaddress() ::
          {:ok, %{address: String.t(), address_index: non_neg_integer()}}
          | {:error, :not_designated_for_subaddress_allocation | term()}
  def create_subaddress do
    if PerpWalk.Role.designated_processor?() do
      do_create_subaddress()
    else
      # Subaddress allocation is monotonic per-wallet: each guardian's
      # wallet increments its own next-index counter on
      # `create_address`. Deterministic derivation means index N on
      # every guardian produces the SAME on-chain address, but if two
      # non-coordinating nodes both call `create_address` they can
      # both hand out "index N" to different quotes cluster-wide —
      # `:quote_filled` replication then collides on the same
      # subaddress index, and one payer's deposit fills another
      # user's quote. Pin allocation to the designated processor;
      # non-designated nodes refuse and callers surface the error to
      # the operator / user.
      #
      # Transparent RPC to the designated node's create_subaddress
      # is deferred follow-up scope — the immediate fix closes the
      # cluster-collision path without adding cross-node RPC surface.
      {:error, :not_designated_for_subaddress_allocation}
    end
  end

  defp do_create_subaddress do
    case Darks.Client.create_address(0) do
      {:ok, %{address_index: index} = result} ->
        # Subaddress index is monotonically increasing; surface it as
        # a gauge so the alert manager can fire when we approach the
        # practical wallet limit (Monero wallet RPC starts to slow
        # noticeably past ~1M subaddresses on commodity hardware).
        :telemetry.execute(
          [:perp_walk, :monero, :subaddress, :allocated],
          %{index: index},
          %{}
        )

        {:ok, result}

      {:error, _} = err ->
        err
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Current chain tip from the wallet's view."
  @spec block_height() :: {:ok, non_neg_integer()} | {:error, term()}
  def block_height do
    Darks.Client.get_height()
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  # --- Multisig Info Exchange ---

  @doc """
  Exports the local wallet's multisig info hex string for sharing
  with federation peers. Delegates to
  `PerpWalk.Monero.Multisig.Sync.local_export/0`.
  """
  @spec export_multisig_info() :: {:ok, String.t()} | {:error, term()}
  defdelegate export_multisig_info(), to: PerpWalk.Monero.Multisig.Sync, as: :local_export

  @doc """
  Imports a list of peer multisig info hex strings into the local
  wallet. Returns the number of outputs reconciled. Delegates to
  `PerpWalk.Monero.Multisig.Sync.apply_imports/1`.
  """
  @spec apply_multisig_imports([String.t()]) :: {:ok, non_neg_integer()} | {:error, term()}
  defdelegate apply_multisig_imports(hex_strings), to: PerpWalk.Monero.Multisig.Sync, as: :apply_imports

  @doc """
  Triggers a bidirectional multisig info sync across all federation
  peers. Delegates to `PerpWalk.Monero.Multisig.Sync.sync_with_peers/1`.

  Used by `Federation.Signer` (post-spend hook) and
  `Monero.Multisig.Scheduler` (periodic).
  """
  @spec sync_multisig_with_peers(keyword()) ::
          {:ok, %{peers_synced: non_neg_integer(), outputs_imported: non_neg_integer()}}
          | {:error, term()}
  defdelegate sync_multisig_with_peers(opts \\ []), to: PerpWalk.Monero.Multisig.Sync, as: :sync_with_peers
end
