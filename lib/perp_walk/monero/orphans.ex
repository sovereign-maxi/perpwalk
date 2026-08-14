defmodule PerpWalk.Monero.Orphans do
  @moduledoc """
  DETS-backed ledger of confirmed Monero deposits that landed on a
  subaddress whose owning record (Quote / Dispute / Market deposit)
  no longer exists or doesn't match the deposited amount.

  Without this, the deposit poller silently logs and the operator
  has no actionable record — funds sit in the federation custody
  unattributed and the user has no UI signal.

  Each orphan entry captures the txid, amount, and the lookup key
  that failed. An operator reviews via `Federation.Console` and
  either refunds via the federation withdrawal flow or marks the
  entry as resolved.

  This is a low-volume table (ideally always empty in steady state)
  so a single DETS file with no ETS mirror is sufficient.
  """

  use GenServer

  require Logger

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents

  @table __MODULE__

  @type kind ::
          :unknown_quote
          | :unknown_dispute
          | :unknown_market_deposit
          | :unmatched_subaddress
          | :overpayment
          | :underpayment
          | :fill_failed
          | :crediting_failed
          | :dispute_confirm_failed
          | :dispute_late_deposit
          | :duplicate_dispute_deposit
  @type orphan :: %{
          txid: String.t(),
          amount_piconeros: pos_integer(),
          kind: kind(),
          key: term(),
          confirmations: non_neg_integer(),
          observed_at: DateTime.t(),
          status: :open | :resolved
        }

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records an orphan deposit. Re-recording an open orphan refreshes
  the row (the poller may observe the same tx across multiple
  confirmation thresholds). A `:resolved` row is NEVER reopened —
  re-fires of an already-handled deposit must not re-page the
  operator into a second refund.

  Returns `:ok`, or `{:error, {:orphan_persist_failed, reason}}` when
  the DETS write failed — the row may be the only record of
  custody-held funds, so persistence failures stay loud.
  """
  @spec record(kind(), String.t(), pos_integer(), term(), non_neg_integer()) ::
          :ok | {:error, term()}
  def record(kind, txid, amount_piconeros, key, confirmations)
      when kind in [
             :unknown_quote,
             :unknown_dispute,
             :unknown_market_deposit,
             :unmatched_subaddress,
             :overpayment,
             :underpayment,
             :fill_failed,
             :crediting_failed,
             :dispute_confirm_failed,
             :dispute_late_deposit,
             :duplicate_dispute_deposit
           ] and
             is_binary(txid) and is_integer(amount_piconeros) and amount_piconeros > 0 and
             is_integer(confirmations) and confirmations >= 0 do
    GenServer.call(__MODULE__, {:record, kind, txid, amount_piconeros, key, confirmations})
  end

  @spec list() :: [orphan()]
  def list do
    :dets.foldl(fn {_txid, orphan}, acc -> [orphan | acc] end, [], @table)
  rescue
    ArgumentError -> []
  end

  @doc """
  Counts orphans still awaiting operator action (`status: :open`).
  Resolved entries stay in DETS as an audit trail but drop out of
  this count — otherwise the `:orphan_deposits_pending` alert would
  keep firing on historical underpayments the auto-refund pipeline
  has already handled.
  """
  @spec count() :: non_neg_integer()
  def count do
    :dets.foldl(
      fn
        {_txid, %{status: :open}}, acc -> acc + 1
        _, acc -> acc
      end,
      0,
      @table
    )
  rescue
    ArgumentError -> 0
  end

  @spec mark_resolved(String.t()) :: :ok | :not_found
  def mark_resolved(txid) when is_binary(txid) do
    GenServer.call(__MODULE__, {:resolve, txid})
  end

  @doc "Wipes every orphan row. Test-only — the runtime never resets."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  # --- GenServer ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    path =
      Keyword.get_lazy(opts, :path, fn ->
        PerpWalk.Storage.Facade.monero_orphans_path()
      end)

    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(@table,
           file: String.to_charlist(path),
           type: :set,
           auto_save: 1000
         ) do
      {:ok, _} -> {:ok, %{path: path}}
      {:error, reason} -> {:stop, {:dets_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:record, kind, txid, amount, key, confs}, _from, state) do
    case :dets.lookup(@table, txid) do
      [{^txid, %{status: :resolved}}] ->
        # A resolved orphan must NEVER resurrect: re-fires (wallet
        # rescan, eviction overlap) of an already-handled deposit would
        # otherwise re-open the row and re-page the operator into a
        # second, manual refund of money already returned.
        Logger.info("Orphans: ignoring re-fire of resolved orphan, txid=#{txid}, kind=#{kind}")
        {:reply, :ok, state}

      _ ->
        record_fresh(kind, txid, amount, key, confs, state)
    end
  end

  def handle_call({:resolve, txid}, _from, state) do
    case :dets.lookup(@table, txid) do
      [{^txid, orphan}] ->
        :dets.insert(@table, {txid, %{orphan | status: :resolved}})
        {:reply, :ok, state}

      [] ->
        {:reply, :not_found, state}
    end
  end

  def handle_call(:clear, _from, state) do
    :dets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  defp record_fresh(kind, txid, amount, key, confs, state) do
    orphan = %{
      txid: txid,
      amount_piconeros: amount,
      kind: kind,
      key: key,
      confirmations: confs,
      observed_at: DateTime.utc_now(),
      status: :open
    }

    case :dets.insert(@table, {txid, orphan}) do
      :ok ->
        EventBus.publish(%MarketsEvents.OrphanDepositObserved{
          txid: txid,
          amount_piconeros: amount,
          kind: kind,
          key: key,
          timestamp: orphan.observed_at
        })

        Logger.error(
          "Orphans: recorded orphan deposit, kind=#{kind} txid=#{txid} " <>
            "amount=#{amount} key=#{inspect(key)} — operator review required"
        )

        {:reply, :ok, state}

      {:error, reason} ->
        # The orphan row may be the ONLY record of custody-held funds.
        # Surface the failure honestly (error tuple + telemetry) so it
        # can't vanish silently.
        Logger.error("Orphans: DETS insert failed, txid=#{txid}, reason=#{inspect(reason)}")

        :telemetry.execute([:perpwalk, :monero, :orphans, :record_failed], %{count: 1}, %{})

        {:reply, {:error, {:orphan_persist_failed, reason}}, state}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.sync(@table)
    :dets.close(@table)
    :ok
  rescue
    _ -> :ok
  end
end
