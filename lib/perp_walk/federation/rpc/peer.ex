defmodule PerpWalk.Federation.RPC.Peer do
  @moduledoc """
  HMAC-protected RPC surface that runs on every guardian.

  The Monero signing path (`PerpWalk.Federation.Signing.Monero`)
  used to call `Darks.Multisig.export_info/0` and
  `Darks.Multisig.sign/1` directly via `:rpc.call/4`. Anyone with
  the BEAM cookie could do the same, drain key-share metadata, or
  obtain a 2-of-3 signature on an arbitrary unsigned tx.

  This module replaces the direct `:rpc.call(peer, Darks.Multisig,
  ...)` with `:rpc.call(peer, __MODULE__, ...)` carrying a signed
  request. Each entrypoint:

  1. Verifies the HMAC + freshness via `RPC.Auth.verify_request/1`.
     Rejects on any failure.
  2. Calls the corresponding `Darks.Multisig` function.
  3. Wraps the result in a signed response that binds back to the
     request's nonce, so the caller can verify it really came from
     a guardian holding the shared secret AND that the response was
     made for the specific request just sent.

  Pure delegation — no state. The endpoint exists only because
  `Darks.Multisig` is a shared dependency we don't own; we can't
  add HMAC checks to its public API directly. So we sit in front
  of it.

  Module name uses `Peer` because that's the angle every caller
  takes — they call this module *on a peer*. From the receiver's
  perspective the same code is "the local guardian's RPC handler."
  """

  require Logger

  alias Darks.Multisig
  alias PerpWalk.Federation.Payout
  alias PerpWalk.Federation.RPC.Auth
  alias PerpWalk.Federation.Signing.Peer.{Policy, Throttle}
  alias PerpWalk.Federation.Store, as: FederationStore
  alias PerpWalk.Monero.Facade, as: MoneroFacade
  alias PerpWalk.Reserves.Facade, as: ReservesFacade

  # Peer attestation verification budget. The proof-generation cycle
  # is 60s; verification must fit comfortably inside that. Three
  # attempts spaced 2s apart gives chain-sync laggers ~6s to catch
  # up before we declare divergence. Overridable via
  # `config :perpwalk, :reserves, attestation_max_attempts: N`
  # and `attestation_retry_interval_ms: N` so tests don't pay the
  # full retry budget on divergence-path assertions.
  @default_attestation_max_attempts 3
  @default_attestation_retry_interval_ms 2_000

  @doc """
  Verifies the request, calls `Darks.Multisig.export_info/0`,
  returns a signed response.
  """
  @spec export_info(Auth.request()) :: {:ok, Auth.response()} | {:error, term()}
  def export_info(request) do
    handle(request, :export_info, fn _args -> Multisig.export_info() end)
  end

  @doc """
  Verifies the request, inspects the unsigned multisig tx via
  `Darks.Multisig.describe/1`, applies the per-peer policy gate
  (`PerpWalk.Federation.Signing.Peer.Policy.evaluate/1`), and only
  on policy approval signs via `Darks.Multisig.sign/1`. Returns a
  signed response.

  The `:args` field of the request must be a binary unsigned-tx hex
  string; anything else is rejected. Policy rejections return
  `{:error, {:policy_rejected, reason}}` and are logged so the
  operator can see a peer refusing a suspicious tx.
  """
  @spec sign(Auth.request()) :: {:ok, Auth.response()} | {:error, term()}
  def sign(request) do
    handle(request, :sign, fn
      unsigned_hex when is_binary(unsigned_hex) ->
        sign_with_policy(unsigned_hex)

      other ->
        {:error, {:bad_args, other}}
    end)
  end

  # Sign pipeline:
  #
  #   1. describe the unsigned tx (parse recipients + amounts)
  #   2. Peer.Policy: per-transaction caps and address sanity (pure)
  #   3. Peer.Throttle: per-peer sliding-window cap on total outflow (stateful)
  #   4. wallet sign
  #
  # The Throttle reservation happens BEFORE the wallet sign call —
  # if the wallet sign subsequently fails, the reservation stays
  # against the window for its lifetime. That's deliberate: the
  # window is a defense-in-depth cap, not a fairness accountant.
  # A failed sign attempt that would have drained 100 XMR still
  # represents a request the peer was asked to authorise; counting
  # it bounds the rate at which a compromised leader can probe.
  defp sign_with_policy(unsigned_hex) do
    with {:ok, descriptions} <- describe(unsigned_hex),
         :ok <- Policy.evaluate(descriptions),
         # Policy refuses non-singleton lists, so this is total.
         [single] <- descriptions,
         :ok <- ledger_binding(single),
         :ok <- Throttle.reserve(total_outflow(single)) do
      Multisig.sign(unsigned_hex)
    else
      {:reject, reason} ->
        Logger.warning("Peer: signing refused, reason=#{reason}")

        {:error, {:policy_rejected, reason}}

      {:error, reason} ->
        Logger.warning("Peer: describe_transfer failed, reason=#{inspect(reason)}")

        {:error, {:describe_failed, reason}}
    end
  end

  # A signing request is only legitimate if the local guardian holds
  # a `:rules_passed` payout whose destination + amount match the
  # unsigned tx's single recipient. Without this check, the HMAC on
  # the sign RPC only proves "someone holding the shared secret sent
  # this" — not "this tx corresponds to any business event."
  #
  # Every guardian sees every payout via WAL replication, so the
  # legitimate leader's `:rules_passed` entry is always locally
  # visible by the time it asks peers to sign. A compromised leader
  # (or anyone who stole the RPC secret) that hasn't first inserted
  # a matching payout via the WAL — which requires the same round-
  # trip through Federation.Rules on every replica — cannot pass
  # this gate.
  defp ledger_binding(%{recipients: [%{address: addr, amount: amount}]}) do
    # At least one local :rules_passed payout matching
    # destination + amount is the security property we need — it
    # proves the leader is asking to sign against SOME approved
    # business event, not an out-of-band destination. Which specific
    # payout it corresponds to is the leader's concern; the peer's
    # job is to refuse arbitrary destinations. Identical payouts
    # (same user winning twice for the same amount) are legitimate
    # and must not deadlock the signing path.
    matched? =
      :rules_passed
      |> FederationStore.list_payouts_by_status()
      |> Enum.any?(fn %Payout{destination: dest, amount_piconeros: amt} ->
        dest == addr and amt == amount
      end)

    if matched? do
      :ok
    else
      {:reject,
       "no_matching_payout: no local :rules_passed payout matches this tx " <>
         "(recipient=#{shorten(addr)}, amount=#{amount})"}
    end
  end

  defp ledger_binding(_other),
    do: {:reject, "unexpected_shape: cannot bind ledger check on non-singleton recipients"}

  defp shorten(addr) when is_binary(addr) and byte_size(addr) > 12,
    do: binary_part(addr, 0, 12) <> "..."

  defp shorten(addr) when is_binary(addr), do: addr
  defp shorten(_), do: "<invalid>"

  defp describe(unsigned_hex) do
    Multisig.describe(unsigned_hex)
  end

  defp total_outflow(%{recipients: recipients}) when is_list(recipients) do
    Enum.reduce(recipients, 0, fn %{amount: amt}, acc when is_integer(amt) -> acc + amt end)
  end

  @doc """
  HMAC-protected wrapper around `Darks.Multisig.create_wallet/2`.
  Refused once `:multisig_address` is configured (bootstrap is
  complete) — see `bootstrap_gate/0`.
  """
  @spec bootstrap_create_wallet(Auth.request()) :: {:ok, Auth.response()} | {:error, term()}
  def bootstrap_create_wallet(request) do
    with :ok <- bootstrap_gate() do
      handle(request, :bootstrap_create_wallet, fn
        {filename, password} when is_binary(filename) and is_binary(password) ->
          Multisig.create_wallet(filename, password)

        other ->
          {:error, {:bad_args, other}}
      end)
    end
  end

  @doc """
  HMAC-protected wrapper around `Darks.Multisig.prepare/0`. Refused
  once `:multisig_address` is configured — see `bootstrap_gate/0`.
  """
  @spec bootstrap_prepare(Auth.request()) :: {:ok, Auth.response()} | {:error, term()}
  def bootstrap_prepare(request) do
    with :ok <- bootstrap_gate() do
      handle(request, :bootstrap_prepare, fn _args -> Multisig.prepare() end)
    end
  end

  @doc """
  HMAC-protected wrapper around `Darks.Multisig.make/2`. Refused
  once `:multisig_address` is configured — see `bootstrap_gate/0`.
  """
  @spec bootstrap_make(Auth.request()) :: {:ok, Auth.response()} | {:error, term()}
  def bootstrap_make(request) do
    with :ok <- bootstrap_gate() do
      handle(request, :bootstrap_make, fn
        {threshold, infos}
        when is_integer(threshold) and is_list(infos) ->
          Multisig.make(threshold, infos)

        other ->
          {:error, {:bad_args, other}}
      end)
    end
  end

  @doc """
  HMAC-protected wrapper around `Darks.Multisig.exchange_keys/1`.
  Refused once `:multisig_address` is configured — see
  `bootstrap_gate/0`.
  """
  @spec bootstrap_exchange_keys(Auth.request()) :: {:ok, Auth.response()} | {:error, term()}
  def bootstrap_exchange_keys(request) do
    with :ok <- bootstrap_gate() do
      handle(request, :bootstrap_exchange_keys, fn
        infos when is_list(infos) ->
          Multisig.exchange_keys(infos)

        other ->
          {:error, {:bad_args, other}}
      end)
    end
  end

  @doc """
  Verifies the request, independently captures the local guardian's
  reserves snapshot, and either endorses the leader's snapshot with
  a `Vault.Attestation` or refuses with a structured divergence
  report. Returns a signed response either way.

  The args field must be a `%Vault.Snapshot{}` from the requesting
  guardian. Verification semantics (Option B independent verification):

    1. Capture local snapshot via `PerpWalk.Reserves.Source`.
    2. If our chain height lags the leader's, retry up to
       `@attestation_max_attempts` times with `@attestation_retry_interval_ms`
       between attempts — the lag is almost certainly chain-sync
       catching up.
    3. If our chain height is caught up AND total_held + outstanding
       match exactly, call `Vault.Generator.attest_snapshot/2` to
       endorse the leader's snapshot with the local guardian key.
    4. If values diverge after the retry budget elapses, return
       `{:error, {:divergent, ours: %{...}, theirs: %{...}}}` so the
       caller (collector) can surface the disagreement and the
       operator can investigate. We deliberately do not sign a
       snapshot whose values we cannot independently confirm.

  This is the load-bearing piece of the federation's proof-of-reserves
  guarantee: each guardian's attestation means "I independently
  observed the same total_held / outstanding," not "I rubber-stamped
  the leader."
  """
  @spec attest_snapshot(Auth.request()) :: {:ok, Auth.response()} | {:error, term()}
  def attest_snapshot(request) do
    handle(request, :attest_snapshot, fn
      %Vault.Snapshot{} = leader_snapshot ->
        verify_and_attest(leader_snapshot, 1, attestation_params())

      other ->
        {:error, {:bad_args, other}}
    end)
  end

  @doc """
  Bidirectional multisig info exchange. Receives the caller's
  exported multisig info hex, imports it into the local wallet, and
  returns the local wallet's freshly-exported info for the caller to
  import on its side. One RPC round-trip reconciles both directions.

  Args: the caller's multisig info hex string (output of
  `Darks.Multisig.export_info/0`).

  Used to defeat the multisig spend-state drift that breaks
  proof-of-reserves attestation when guardians don't all participate
  in every spend. See `PerpWalk.Monero.Multisig.Sync` for the
  protocol-level rationale.
  """
  @spec multisig_info_exchange(Auth.request()) :: {:ok, Auth.response()} | {:error, term()}
  def multisig_info_exchange(request) do
    handle(request, :multisig_info_exchange, fn
      peer_info when is_binary(peer_info) ->
        with {:ok, _} <- MoneroFacade.apply_multisig_imports([peer_info]) do
          MoneroFacade.export_multisig_info()
        end

      other ->
        {:error, {:bad_args, other}}
    end)
  end

  # On chain-height lag we retry unconditionally (within budget); on
  # value mismatch we retry only if attempts remain — the leader could
  # be observing a transient on-chain change that our follower hasn't
  # yet seen. Refuses with structured divergence info when the budget
  # is spent.
  defp verify_and_attest(leader_snapshot, attempt, %{
         max_attempts: max,
         retry_interval_ms: interval
       }) do
    ours = ReservesFacade.capture_snapshot()

    cond do
      chain_behind?(ours, leader_snapshot) and attempt < max ->
        Process.sleep(interval)
        verify_and_attest(leader_snapshot, attempt + 1, %{max_attempts: max, retry_interval_ms: interval})

      values_match?(ours, leader_snapshot) ->
        sign_with_pubkey(leader_snapshot)

      attempt < max ->
        Process.sleep(interval)
        verify_and_attest(leader_snapshot, attempt + 1, %{max_attempts: max, retry_interval_ms: interval})

      true ->
        report_divergence(ours, leader_snapshot)
    end
  end

  # Bundle the attestation with the local guardian's pubkey in the
  # response so the collector can verify the attestation signature
  # without a pre-shared guardian-pubkey registry. The HMAC layer
  # already binds the response to "some guardian holding the shared
  # secret"; including the pubkey here lets the caller cryptographically
  # confirm that the attestation was signed by the key that hashes
  # (SHA-256, first 16 bytes) to the attestation's guardian_id —
  # making per-guardian attribution rest on Ed25519 instead of
  # static config.
  defp sign_with_pubkey(snapshot) do
    with {:ok, attestation} <- Vault.Generator.attest_snapshot(snapshot),
         {:ok, pubkey} <- Vault.Generator.guardian_pubkey() do
      {:ok, %{attestation: attestation, pubkey: pubkey}}
    end
  end

  defp attestation_params do
    cfg = Application.get_env(:perpwalk, :reserves, [])

    %{
      max_attempts: Keyword.get(cfg, :attestation_max_attempts, @default_attestation_max_attempts),
      retry_interval_ms: Keyword.get(cfg, :attestation_retry_interval_ms, @default_attestation_retry_interval_ms)
    }
  end

  defp chain_behind?(ours, leader) do
    our_h = chain_height(ours)
    their_h = chain_height(leader)
    is_integer(our_h) and is_integer(their_h) and our_h < their_h
  end

  defp values_match?(ours, leader) do
    ours.total_held == leader.total_held and ours.outstanding == leader.outstanding
  end

  defp chain_height(%Vault.Snapshot{metadata: meta}) when is_map(meta),
    do: Map.get(meta, :chain_height)

  defp chain_height(_), do: nil

  defp report_divergence(ours, leader) do
    Logger.warning(
      "Peer: refused attestation, reason=divergent, " <>
        "ours_held=#{ours.total_held} ours_outstanding=#{ours.outstanding} " <>
        "theirs_held=#{leader.total_held} theirs_outstanding=#{leader.outstanding}"
    )

    {:error,
     {:divergent,
      ours: %{
        total_held: ours.total_held,
        outstanding: ours.outstanding,
        chain_height: chain_height(ours)
      },
      theirs: %{
        total_held: leader.total_held,
        outstanding: leader.outstanding,
        chain_height: chain_height(leader)
      }}}
  end

  # Bootstrap RPCs are HMAC-protected, but the secret is enough to
  # call them — and once the multisig is established, any further
  # `make_multisig` / `exchange_keys` could replace or corrupt the
  # active wallet state. Gate by `:multisig_address` config: present
  # means the ceremony has run and these methods must not fire.
  #
  # An earlier version also OR'd in a `Cartel.connected_count() > 0`
  # check as defense-in-depth against runtime config wipe. The signal
  # is false on a *first* bootstrap by construction — cartel
  # transport connects at boot regardless of ceremony state — so the
  # check refused every legitimate initial bootstrap. The threat it
  # defended against (attacker with the federation RPC secret who has
  # also gained the BEAM access to `Application.put_env/3` the
  # multisig address to nil) is host-level compromise; at that point
  # the multisig key shares themselves are exposed and the gate is no
  # longer the load-bearing defense. A persistent on-disk marker
  # written at ceremony completion would let us reinstate the
  # defense-in-depth without breaking first-bootstrap; not implemented.
  defp bootstrap_gate do
    case Application.get_env(:perpwalk, :multisig_address) do
      addr when is_binary(addr) ->
        Logger.warning("Peer: bootstrap RPC refused — multisig already configured, address=#{addr}")
        {:error, :bootstrap_complete}

      _ ->
        :ok
    end
  end

  # --- Internal ---

  defp handle(request, expected_method, fun) do
    case Auth.verify_request(request) do
      {:ok, ^expected_method, args, nonce} ->
        result = fun.(args)
        {:ok, Auth.sign_response(expected_method, result, nonce)}

      {:ok, other_method, _args, _nonce} ->
        Logger.warning("Peer: method mismatch, got=#{inspect(other_method)}, expected=#{inspect(expected_method)}")

        {:error, :method_mismatch}

      {:error, reason} = err ->
        Logger.warning("Peer: rejecting request, method=#{inspect(expected_method)}, reason=#{inspect(reason)}")

        err
    end
  end
end
