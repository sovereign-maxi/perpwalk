defmodule PerpWalk.Storage.WAL.Replay do
  @moduledoc """
  Shared invariant-check helpers for WAL replay + replication apply.

  Each domain store handles `Locker.WAL.Entry` values from both the
  cold-boot replay path (rebuilding ETS from the local WAL) and the
  replication apply path (folding a peer's entries into local state).
  Entries whose `:type` belongs to *another* domain pass through the
  catch-all silently — that's correct routing.

  Entries whose `:type` belongs to *this* domain but whose payload
  shape doesn't match any specific `apply_entry/1` clause are
  MALFORMED. Cold-boot: WAL corruption or a bug in a prior release
  wrote garbage. Replication: a compromised peer sent structurally
  valid but semantically broken data past the signature check
  (e.g. by holding a legitimate key and publishing junk). Either
  way, applying an unknown-shape entry silently would let the venue
  drift out of sync with its own history — fail-closed via
  `Telemetry.Health.System.set_source_halt/2` and let the operator
  triage.
  """

  alias Locker.WAL.Entry
  alias PerpWalk.Federation.Keys
  alias PerpWalk.Storage.WAL.Signing
  alias PerpWalk.Telemetry.Health.System, as: HealthSystem

  require Logger

  @doc """
  Halts the venue with a "malformed WAL entry" reason and returns
  `:ok`. Call from a domain store's catch-all `apply_entry/1` when
  the entry's type is domain-owned but the payload shape doesn't
  match any specific clause.

  `owner` is a short label identifying the owning subsystem (e.g.
  `:markets`, `:federation`, `:identity_sessions`) — used in the
  halt reason and log lines.
  """
  @spec halt_on_malformed(atom(), Entry.t()) :: :ok
  def halt_on_malformed(owner, %Entry{type: type, payload: payload}) when is_atom(owner) do
    keys = payload_keys(payload)
    reason = "malformed WAL entry: owner=#{owner}, type=#{type}"

    Logger.error(reason <> ", payload_keys=#{inspect(keys)}")
    HealthSystem.set_source_halt(:"wal_replay_#{owner}", reason)

    :ok
  end

  @doc """
  Applies `apply_fn` to each entry, short-circuiting the moment
  `halt_on_malformed/2` fires for this owner. Replay + replicate loops
  should use this instead of raw `Enum.each/2` so a single malformed
  entry doesn't smuggle the rest of the batch into ETS after the
  auto-halt is set. Also refuses any `:bad_signature` entry at boot —
  unsigned / missing-origin remain grandfathered per `Signing`
  moduledoc.
  """
  @spec each_or_halt([Entry.t()], atom(), (Entry.t() -> any())) :: :ok
  def each_or_halt(entries, owner, apply_fn)
      when is_list(entries) and is_atom(owner) and is_function(apply_fn, 1) do
    marker = "malformed WAL entry: owner=#{owner}"

    _ =
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        cond do
          malformed_for?(owner, marker) ->
            {:halt, :ok}

          bad_signature?(entry, owner) ->
            {:halt, :ok}

          true ->
            apply_fn.(entry)

            if malformed_for?(owner, marker), do: {:halt, :ok}, else: {:cont, :ok}
        end
      end)

    :ok
  end

  @doc """
  Boot-time authenticity gate for a single WAL entry. Returns true
  when the entry must NOT be applied (bad/forged signature for the
  current signing mode); a sticky source halt is recorded so writes
  stay blocked until an operator investigates. `:checkpoint` entries
  are exempt — they bypass the Sealer by design (unsigned, origin-less,
  seq-less), so a naive enforcement pass would halt on every one.

  Enforcement keys on `boot_enforced?/0`: a production node with a
  provisioned signing key signs every entry it writes, so unsigned or
  unknown-origin entries on its disk are anomalous. Non-prod boots and
  single-node keyless deployments legitimately carry unsigned entries —
  the halt is recorded but replay continues.

  Callers decide the failure posture: raise on true (production boot
  replay) or skip-with-warning (non-prod fixtures).
  """
  @spec halt_entry?(Entry.t(), atom()) :: boolean()
  def halt_entry?(%Entry{type: :checkpoint}, _owner), do: false

  def halt_entry?(entry, owner) do
    case Signing.verify_entry(entry) do
      :ok ->
        false

      {:error, :bad_signature} ->
        halt_replay(owner, entry.type, :bad_signature)

      {:error, reason} when reason in [:unsigned, :missing_origin, :unknown_participant] ->
        if boot_enforced?(), do: halt_replay(owner, entry.type, reason), else: false
    end
  end

  defp boot_enforced? do
    Application.get_env(:perpwalk, :env) == :prod and
      match?({:ok, _}, Keys.local_private_key())
  end

  # --- Private ---

  defp payload_keys(payload) when is_map(payload), do: payload |> Map.keys() |> Enum.sort()
  defp payload_keys(_), do: :non_map_payload

  defp malformed_for?(owner, marker) do
    case Map.get(HealthSystem.source_halts(), :"wal_replay_#{owner}") do
      reason when is_binary(reason) -> String.contains?(reason, marker)
      _ -> false
    end
  end

  # Halts boot replay for any signature-verification failure that
  # cannot legitimately arise in the current signing mode.
  #
  # Federated mode (pinned pubkeys registry non-empty): every
  # locally-written entry MUST be signed by a known origin. Halt
  # on `:bad_signature`, `:unsigned`, `:missing_origin`, AND
  # `:unknown_participant` — each is a WAL-poisoning tell in
  # federated mode. The previous grandfathering carve-out for
  # unsigned entries was safe when EVERY locally-written entry was
  # unsigned (dev boot with no pinned keys) but a forgery vector
  # otherwise: an attacker holding a legitimate key can also just
  # write unsigned entries, and boot replay would apply them.
  #
  # Single-node / dev mode (pinned pubkeys empty): `:unsigned`
  # entries are legitimate — the local Sealer intentionally emits
  # them when no signing key is provisioned. `:bad_signature`
  # still halts (it means someone tampered with the WAL on disk).
  defp bad_signature?(entry, owner) do
    case Signing.verify_entry(entry) do
      {:error, :bad_signature} ->
        halt_replay(owner, entry.type, :bad_signature)

      {:error, reason} when reason in [:unsigned, :missing_origin, :unknown_participant] ->
        if signing_enforced?() do
          halt_replay(owner, entry.type, reason)
        else
          false
        end

      _ ->
        false
    end
  end

  defp halt_replay(owner, type, reason_atom) do
    reason = "malformed WAL entry: owner=#{owner}, type=#{type}, reason=#{inspect(reason_atom)}"

    Logger.error(reason)
    HealthSystem.set_source_halt(:"wal_replay_#{owner}", reason)

    true
  end

  # Mirrors `Storage.WAL.Sealer.signing_enforced?/0`. Federated
  # mode = at least one participant has a pinned pubkey. Callers
  # go through `Federation.Keys` to preserve the injectable seam
  # (`:perpwalk, :participant_pubkeys` in app env for tests).
  defp signing_enforced?, do: PerpWalk.Federation.Keys.pinned_pubkeys() != %{}
end
