defmodule PerpWalk.Federation.Multisig.Guard do
  @moduledoc """
  Periodically verifies the open Monero wallet matches the
  configured multisig address.

  Catches the failure mode where wallet-rpc opens the wrong wallet
  after a reboot — either because the launch wrapper switched modes
  unexpectedly, the wallet file was swapped, or `xmr_wallet_open_file`
  drifted out of sync with the actual ceremony output. A silent
  mis-open here means subsequent balance reads and signing
  operations target the wrong key share, so the guard's job is to
  surface that immediately.

  No-ops before the bootstrap ceremony has run — only enforces
  when `:perpwalk, :multisig_address` is configured.
  """

  use GenServer

  require Logger

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents
  alias PerpWalk.Federation.{Facade, Signer}

  @initial_delay_ms 5_000
  @check_interval_ms 60_000
  @wallet_retry_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  True if the wallet address has been verified against the configured
  multisig address at least once. Returns `true` immediately when no
  multisig address is configured (pre-ceremony — nothing to verify).

  Read by `Federation.Signer.drive_writes?/1` so signing waits for the
  first successful check before the auto-loop drives any payout. Read
  via persistent_term so the check is lock-free and safe inside the
  Signer's tick.
  """
  @spec verified?() :: boolean()
  def verified? do
    case Facade.expected_multisig_address() do
      nil -> true
      _addr -> :persistent_term.get({__MODULE__, :verified}, false)
    end
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :check, @initial_delay_ms)
    {:ok, %{last_status: :pending}}
  end

  @impl true
  def handle_info(:check, state) do
    {result, next_delay} = do_check()
    Process.send_after(self(), :check, next_delay)
    {:noreply, %{state | last_status: result}}
  end

  defp do_check do
    case Facade.verify_multisig_address() do
      :ok ->
        if Facade.expected_multisig_address() do
          Logger.info("Guard: wallet address verified")
        end

        # Publish a "wallet has been verified at least once" flag so
        # the Signer can refuse to drive its tick until this gate has
        # confirmed the open wallet matches config. Without this, the
        # first Signer tick (default 5s) and first Guard check (also
        # 5s) race; if Signer wins, a WAL-recovered :rules_passed
        # payout could sign against a mis-opened wallet before Guard
        # surfaces the mismatch. persistent_term is the lock-free
        # carrier for this cross-process flag.
        :persistent_term.put({__MODULE__, :verified}, true)

        {:ok, @check_interval_ms}

      {:error, {:wallet_unavailable, reason}} ->
        Logger.warning("Guard: wallet rpc unavailable, reason=#{inspect(reason)}")

        {:wallet_unavailable, @wallet_retry_ms}

      {:error, {:address_mismatch, expected: expected, actual: actual}} ->
        Logger.error(
          "Guard: address mismatch, cause=wallet_rpc_opened_wrong_wallet, " <>
            "action=halting_signer, expected=#{expected}, actual=#{actual}"
        )

        EventBus.publish(%FederationEvents.MultisigAddressMismatch{
          expected: expected,
          actual: actual,
          timestamp: DateTime.utc_now()
        })

        # Drop the verified flag before halting so an operator-initiated
        # `Signer.resume()` cannot re-enable signing until the next
        # successful Guard check re-asserts the wallet identity.
        # Without this, `Signer.drive_writes?/1` would consult a stale
        # `true` from the prior good check and sign against the wrong
        # wallet for up to one check interval.
        :persistent_term.put({__MODULE__, :verified}, false)

        # Address mismatch means subsequent signing operations would
        # target the wrong key share — funds could move from a wallet
        # the operator did not intend. Auto-halt so signing stops even
        # when the operator is asleep / offline; they resume manually
        # after verifying the wallet configuration.
        halt_signer_safely()

        {:mismatch, @check_interval_ms}
    end
  end

  defp halt_signer_safely do
    Signer.halt()

    # Mirror the Poller's pattern: every cross-domain halt is written
    # to the durable operator audit log so a forensic review at 4am
    # can distinguish operator-initiated from auto-initiated halts
    # and identify which subsystem requested it.
    PerpWalk.Federation.Audit.record(:signing_halted_by_guard, %{
      reason: :multisig_address_mismatch,
      at: DateTime.utc_now()
    })
  rescue
    err ->
      Logger.error("Guard: signer halt raised, reason=#{inspect(err)}")
  catch
    :exit, reason ->
      Logger.error("Guard: signer halt exited, reason=#{inspect(reason)}")
  end
end
