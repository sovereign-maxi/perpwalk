defmodule PerpWalk.Federation.Signing.Peer.Policy do
  @moduledoc """
  Per-peer policy gate evaluated by a guardian BEFORE it co-signs an
  unsigned multisig transaction proposed by a peer (typically the
  storage leader). "Per-peer" because the policy lives on the
  receiving guardian and runs once per inbound sign request.

  The HMAC layer in `PerpWalk.Federation.RPC.Auth` proves the
  request was sent by *someone* who holds the federation secret;
  it does NOT prove the request is policy-legitimate. Without this
  module, a compromised leader (or any guardian that has obtained
  the RPC secret) could ask peers to sign an unsigned tx with
  arbitrary destinations and amounts; the receiving guardian would
  forward to its wallet RPC blindly because `Darks.Multisig.sign/1`
  does not inspect what it is signing.

  This module gives each receiving guardian a domain-level check:
  parse the unsigned multisig tx via `Darks.Multisig.describe/1`,
  then refuse to sign if any of the policy rules below reject it.

  ## Rules

  1. **destination_sanity** — every recipient address must be a
     well-formed Monero standard / subaddress / integrated address.
     Same regex used by `PerpWalk.Federation.Rules` on the leader.
  2. **per_recipient_cap** — no single recipient can receive more
     than `max_recipient_piconeros` (default 50 XMR). All recipient
     amounts must be positive integers. Defense against a
     compromised leader trying to sweep the wallet in one transaction.
  3. **total_outflow_cap** — sum of all recipient amounts must not
     exceed `max_total_piconeros` (default 100 XMR). Caps the
     blast radius of a single signing round even when the
     destination passes regex.

  Pure module — no state, no IO except the `describe/1` call that
  the caller makes before invoking `evaluate/1`.

  Time-window rate limiting across multiple signing rounds is
  enforced separately by `PerpWalk.Federation.Signing.Peer.Throttle`,
  which the `RPC.Peer.sign/1` pipeline invokes immediately after
  this policy passes.
  """

  alias PerpWalk.Monero.Address

  # Defaults: 50 XMR per recipient, 100 XMR total. Wallets routinely
  # hold much more than this; the cap exists to bound the damage
  # of a single mis-issued sign request, not to gate legitimate
  # payouts. Operators tune via config when daily volume warrants.
  @default_max_recipient_piconeros 50 * 1_000_000_000_000
  @default_max_total_piconeros 100 * 1_000_000_000_000

  @type description :: %{
          required(:recipients) => [%{address: String.t(), amount: non_neg_integer()}],
          required(:fee) => non_neg_integer(),
          optional(:change_address) => String.t() | nil,
          optional(:change_amount) => non_neg_integer(),
          optional(:unlock_time) => non_neg_integer(),
          optional(atom()) => any()
        }

  @type result :: :ok | {:reject, String.t()}

  @doc """
  Evaluates the policy rules against a `Darks.Multisig.describe/1`
  result. `describe/1` returns a list of transactions — this venue
  builds one-payment-per-round via `transfer/2`, so any set with
  more than one transaction is refused outright. The previous
  behaviour parsed only `desc[0]`, letting a compromised builder
  smuggle unbounded outflows past the per-tx cap by prepending a
  decoy first transaction to a `transfer_split` set.

  Returns `:ok` when every rule passes against the single
  transaction, or the first rejection as `{:reject, reason}`.

  Configuration is read from `:perpwalk, :peer_signing_policy`:

      config :perpwalk, :peer_signing_policy,
        max_recipient_piconeros: 50 * 1_000_000_000_000,
        max_total_piconeros: 100 * 1_000_000_000_000
  """
  @spec evaluate([description()] | description()) :: result()
  def evaluate(descs) when is_list(descs) do
    case descs do
      [] ->
        {:reject, "empty_txset: describe returned no transactions"}

      [_only_one] ->
        evaluate_single(hd(descs))

      _many ->
        {:reject, "multi_tx_txset: this venue builds single-payment rounds; refusing #{length(descs)}-tx set"}
    end
  end

  # Legacy single-map shape — kept so unit tests and any downstream
  # caller still pass a map through without switching signatures.
  def evaluate(%{recipients: _} = single), do: evaluate_single(single)
  def evaluate(_), do: {:reject, "describe_transfer returned malformed payload"}

  defp evaluate_single(%{recipients: []}),
    do: {:reject, "no_recipients: signing refused on zero-recipient tx"}

  defp evaluate_single(%{recipients: recipients} = desc) when is_list(recipients) do
    with :ok <- destination_sanity(recipients),
         :ok <- per_recipient_cap(recipients),
         :ok <- change_sanity(desc),
         :ok <- unlock_time_zero(desc) do
      total_outflow_cap(recipients)
    end
  end

  defp evaluate_single(_), do: {:reject, "describe_transfer entry missing recipients"}

  # --- Rules ---

  defp destination_sanity(recipients) do
    Enum.reduce_while(recipients, :ok, fn %{address: addr}, _acc ->
      cond do
        not is_binary(addr) ->
          {:halt, {:reject, "destination_sanity: address must be a string"}}

        byte_size(addr) > Address.max_input_length() ->
          {:halt, {:reject, "destination_sanity: address too long (#{byte_size(addr)} bytes)"}}

        not Address.valid?(addr) ->
          {:halt, {:reject, "destination_sanity: not a well-formed Monero address"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp per_recipient_cap(recipients) do
    cap = config_value(:max_recipient_piconeros, @default_max_recipient_piconeros)

    if Enum.all?(recipients, fn %{amount: amt} -> is_integer(amt) and amt > 0 end) do
      case Enum.find(recipients, fn %{amount: amt} -> amt > cap end) do
        nil ->
          :ok

        %{address: addr, amount: amt} ->
          {:reject, "per_recipient_cap: #{amt} piconeros to #{shorten(addr)} exceeds cap #{cap}"}
      end
    else
      {:reject, "per_recipient_cap: every recipient amount must be a positive integer"}
    end
  end

  # Change MUST come back to the venue's own multisig wallet, not
  # some other well-formed Monero address. Stock `monero-wallet-rpc`
  # transfers can't set an arbitrary change_address, but a
  # hand-crafted txset (custom tooling + the shared secret) could
  # pay a legitimate `:rules_passed` recipient+amount — passing C2's
  # ledger_binding — while redirecting the rest of the wallet
  # balance as "change" to an attacker's own valid address. The
  # per-recipient/total caps don't gate change because change is
  # not a recipient in the describe payload.
  #
  # `Application.get_env(:perpwalk, :multisig_address)` returns nil
  # pre-bootstrap (before the ceremony has produced the multisig
  # wallet). In that state the venue can't legitimately be signing
  # payouts anyway, so we still require well-formedness but skip
  # the equality gate — the sign path itself is refused elsewhere
  # in that phase (see `RPC.Peer.bootstrap_gate/0`).
  defp change_sanity(%{change_address: nil}), do: :ok

  defp change_sanity(%{change_address: addr}) when is_binary(addr) do
    cond do
      not Address.valid?(addr) ->
        {:reject, "change_sanity: change_address is not a well-formed Monero address"}

      not change_address_is_venue?(addr) ->
        {:reject,
         "change_sanity: change_address is not the venue multisig address " <>
           "(destination=#{shorten(addr)}) — refusing to route change to a foreign wallet"}

      true ->
        :ok
    end
  end

  defp change_sanity(_desc), do: :ok

  defp change_address_is_venue?(addr) do
    case Application.get_env(:perpwalk, :multisig_address) do
      venue when is_binary(venue) -> Plug.Crypto.secure_compare(addr, venue)
      _no_bootstrap -> true
    end
  end

  # `unlock_time > 0` locks the outputs (recipient can't spend for
  # N blocks/timestamp). No legitimate payout this venue builds
  # uses unlock_time; a non-zero value is a compromised-builder
  # signal (delay a peer's recognition; grief the recipient).
  defp unlock_time_zero(%{unlock_time: 0}), do: :ok

  defp unlock_time_zero(%{unlock_time: t}) when is_integer(t) and t > 0 do
    {:reject, "unlock_time_nonzero: refusing to sign locked payout (unlock_time=#{t})"}
  end

  defp unlock_time_zero(_desc), do: :ok

  defp total_outflow_cap(recipients) do
    cap = config_value(:max_total_piconeros, @default_max_total_piconeros)
    total = Enum.reduce(recipients, 0, fn %{amount: amt}, acc -> acc + amt end)

    if total <= cap do
      :ok
    else
      {:reject, "total_outflow_cap: sum #{total} exceeds cap #{cap}"}
    end
  end

  # --- Helpers ---

  defp config_value(key, default) do
    Application.get_env(:perpwalk, :peer_signing_policy, [])
    |> Keyword.get(key, default)
  end

  # Don't dump the full 95-char address into every log line — short
  # prefix is enough for the operator to identify which destination
  # was rejected.
  defp shorten(addr) when is_binary(addr) and byte_size(addr) > 12,
    do: binary_part(addr, 0, 12) <> "..."

  defp shorten(addr) when is_binary(addr), do: addr
  defp shorten(_), do: "<invalid>"
end
