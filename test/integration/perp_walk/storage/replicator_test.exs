defmodule PerpWalk.Storage.ReplicatorIntegrationTest do
  @moduledoc """
  Integration tests for `PerpWalk.Storage.Replicator` symmetric
  bi-directional WAL replication.

  The harness wires a single supervised `Replicator` against an
  in-process "fake peer". The fake peer keeps a list of
  `Locker.WAL.Entry` records in an Agent and responds to
  `entries_since/2` requests through a test-injected `:rpc`
  2-arity override. No second BEAM node required.

  Composite-key invariant: the responder filters by `origin == :p2`
  (the peer's participant id). The local node only ever stamps
  entries with `origin == :p1`. So local entries do NOT bleed back
  into the replicated stream.
  """

  use PerpWalk.IntegrationCase

  alias Locker.WAL.Entry
  alias PerpWalk.Federation.Payout
  alias PerpWalk.Federation.Store, as: FederationStore
  alias PerpWalk.Storage.Replication.Auth
  alias PerpWalk.Storage.Replicator
  alias PerpWalk.Storage.WAL.Signing

  # Deterministic Ed25519 keypair for the fake peer :p2. Pinned in the
  # participant registry for the duration of each test so
  # Signing.verify_entry sees a matching pubkey and the Replicator's
  # sig-verify passes.
  @peer_seed :crypto.hash(:sha256, "perpwalk-test-peer-p2")
  @peer_pub elem(:crypto.generate_key(:eddsa, :ed25519, :crypto.hash(:sha256, "perpwalk-test-peer-p2")), 0)

  setup do
    :ok = FederationStore.clear()

    original = Application.get_env(:perpwalk, :participant_pubkeys)
    Application.put_env(:perpwalk, :participant_pubkeys, %{p2: @peer_pub})

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:perpwalk, :participant_pubkeys)
      else
        Application.put_env(:perpwalk, :participant_pubkeys, original)
      end
    end)

    :ok
  end

  defp unique_id, do: "payout-#{:erlang.unique_integer([:positive, :monotonic])}"
  defp unique_position, do: "pos-#{:erlang.unique_integer([:positive, :monotonic])}"
  defp unique_market, do: "mkt-#{:erlang.unique_integer([:positive, :monotonic])}"
  defp unique_account, do: "acct-#{:erlang.unique_integer([:positive, :monotonic])}"

  # The WAL persists across tests within the same `mix test` run.
  # Each test's Replicator boots with a cursor recovered from
  # whatever entries with origin=:p2 prior tests wrote. To keep
  # tests self-contained, allocate peer-entry seqs strictly above
  # the current boot cursor — this is the same baseline a real
  # peer's WAL would start from after a restart.
  defp peer_entries_above(base_seq, n, opts \\ []) do
    entries =
      for i <- 1..n do
        peer_entry(base_seq + i, opts)
      end

    max_seq = base_seq + n
    {entries, max_seq}
  end

  # Builds a `:payout_requested` Entry for the fake peer's WAL.
  # Payload shape mirrors `Federation.Store.serialize/1` so the
  # local apply path's deserialize/1 round-trips cleanly.
  defp peer_entry(seq, opts \\ []) do
    origin = Keyword.get(opts, :origin, :p2)
    id = Keyword.get(opts, :id, unique_id())
    now_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    payload = %{
      id: id,
      position_id: unique_position(),
      market_id: unique_market(),
      account_id: unique_account(),
      kind: :winner_payout,
      amount_piconeros: 1_000_000_000_000,
      destination: "47jUE3...",
      status: :enqueued,
      rule_failure_reason: nil,
      payout_txid: nil,
      created_at: now_iso,
      updated_at: now_iso,
      seq: seq,
      origin: origin
    }

    signed = sign_test_payload(:payout_requested, payload, origin)
    %Entry{type: :payout_requested, payload: signed}
  end

  # Signs a payload with the seeded peer key so it survives the
  # Replicator's per-entry signature verification. Test-only shortcut
  # around Signing.sign_entry (which would use the local node's key,
  # not :p2's).
  defp sign_test_payload(type, payload, :p2) do
    material = Signing.canonicalize(type, payload)
    sig = :crypto.sign(:eddsa, :none, material, [@peer_seed, :ed25519])
    Map.put(payload, :sig, sig)
  end

  defp sign_test_payload(_type, payload, _other), do: payload

  # Builds the rpc-side fn that reads from an Agent + signs the
  # response through `Auth.sign_response/5`. Test mutates the agent
  # contents after reading the Replicator's boot cursor.
  defp build_dynamic_peer do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    rpc = fn _node, [request] ->
      case Auth.verify_request(request) do
        {:ok, cursor} ->
          peer_entries = Agent.get(agent, & &1)
          peer_tip = peer_entries |> peer_max_seq() |> max(cursor)
          {batch, new_cursor} = slice_peer_entries(peer_entries, cursor)
          {:ok, Auth.sign_response(cursor, new_cursor, peer_tip, batch, request.nonce)}

        {:error, _} = err ->
          err
      end
    end

    {agent, rpc}
  end

  defp peer_max_seq(entries) do
    Enum.reduce(entries, 0, fn
      %Entry{payload: %{seq: s}}, acc when is_integer(s) -> max(acc, s)
      _, acc -> acc
    end)
  end

  defp slice_peer_entries(entries, cursor) do
    {filtered, new_cursor} =
      Enum.reduce(entries, {[], cursor}, fn
        %Entry{payload: %{seq: s}} = entry, {acc, hw} when is_integer(s) and s > cursor ->
          {[entry | acc], max(hw, s)}

        _, acc ->
          acc
      end)

    {Enum.reverse(filtered), new_cursor}
  end

  defp start_replicator(rpc) do
    start_supervised!(
      {Replicator, peers: [%{origin: :p2, node: :p2@nohost}], rpc: rpc, auto_tick: false, name: TestReplicator}
    )
  end

  describe "round-trip apply" do
    test "pulls peer entries, appends to local WAL, routes to Federation.Store" do
      {agent_pid, rpc_fn} = build_dynamic_peer()
      _pid = start_replicator(rpc_fn)
      base = Replicator.status(TestReplicator).p2.cursor

      {entries, max_seq} = peer_entries_above(base, 3)
      Agent.update(agent_pid, fn _ -> entries end)

      :ok = Replicator.tick_now(TestReplicator)

      ids = Enum.map(entries, & &1.payload.id)

      for id <- ids do
        assert {:ok, %Payout{}} = FederationStore.get_payout(id)
      end

      snap = Replicator.status(TestReplicator)
      assert snap.p2.cursor == max_seq
      assert snap.p2.peer_tip >= max_seq
    end

    test "is idempotent — re-running the tick doesn't re-apply" do
      {agent_pid, rpc_fn} = build_dynamic_peer()
      _pid = start_replicator(rpc_fn)
      base = Replicator.status(TestReplicator).p2.cursor

      {entries, _max_seq} = peer_entries_above(base, 2)
      Agent.update(agent_pid, fn _ -> entries end)

      :ok = Replicator.tick_now(TestReplicator)
      pre_count = FederationStore.list_payouts_by_status(:enqueued) |> length()

      :ok = Replicator.tick_now(TestReplicator)
      post_count = FederationStore.list_payouts_by_status(:enqueued) |> length()

      assert pre_count == post_count
    end

    test "applies new entries on a subsequent tick" do
      {agent_pid, rpc_fn} = build_dynamic_peer()
      _pid = start_replicator(rpc_fn)
      base = Replicator.status(TestReplicator).p2.cursor

      {entries_1, first_max} = peer_entries_above(base, 2)
      Agent.update(agent_pid, fn _ -> entries_1 end)

      :ok = Replicator.tick_now(TestReplicator)
      assert Replicator.status(TestReplicator).p2.cursor == first_max

      new_entry = peer_entry(first_max + 1)
      Agent.update(agent_pid, fn list -> list ++ [new_entry] end)

      :ok = Replicator.tick_now(TestReplicator)
      assert Replicator.status(TestReplicator).p2.cursor == new_entry.payload.seq
      assert {:ok, %Payout{}} = FederationStore.get_payout(new_entry.payload.id)
    end

    test "halts on origin mismatch — entry claiming foreign participant_id rejected" do
      # Signature verification pins entry origin to the peer we asked.
      # A tampered / rogue peer serving an entry stamped with a
      # different participant_id fails verify_signatures and halts.
      {agent_pid, rpc_fn} = build_dynamic_peer()
      _pid = start_replicator(rpc_fn)
      base = Replicator.status(TestReplicator).p2.cursor

      wrong_origin = peer_entry(base + 1, origin: :p1)
      Agent.update(agent_pid, fn _ -> [wrong_origin] end)

      :ok = Replicator.tick_now(TestReplicator)

      # Batch rejected — cursor unchanged, entry not applied.
      assert Replicator.status(TestReplicator).p2.cursor == base
      assert {:error, :not_found} = FederationStore.get_payout(wrong_origin.payload.id)
    end

    test "signature-failure halt is STICKY across subsequent good batches" do
      # Pre-fix: `halt_on_signature_failure/2` and
      # `maybe_clear_replicator_halt/0` used the SAME `:replicator`
      # source-halt slot. A mostly-honest malicious peer sending
      # one bad batch followed by many good ones auto-cleared the
      # halt on the very next successful apply, defeating the
      # signal entirely. Fix: signature failures use the sticky
      # `:replicator_signature` slot that never auto-clears.
      alias PerpWalk.Telemetry.Health.System, as: HealthSystem

      {agent_pid, rpc_fn} = build_dynamic_peer()
      _pid = start_replicator(rpc_fn)
      base = Replicator.status(TestReplicator).p2.cursor

      # Bad batch — origin mismatch triggers halt_on_signature_failure.
      wrong_origin = peer_entry(base + 1, origin: :p1)
      Agent.update(agent_pid, fn _ -> [wrong_origin] end)
      :ok = Replicator.tick_now(TestReplicator)

      assert Map.has_key?(HealthSystem.source_halts(), :replicator_signature),
             "signature failure must set the sticky :replicator_signature halt"

      # Good batch follows — successful apply must NOT clear the
      # sticky signature halt.
      good = peer_entry(base + 2)
      Agent.update(agent_pid, fn _ -> [good] end)
      :ok = Replicator.tick_now(TestReplicator)

      assert Map.has_key?(HealthSystem.source_halts(), :replicator_signature),
             "successful apply must NOT clear the sticky :replicator_signature halt"

      # Only an explicit operator clear releases it.
      HealthSystem.clear_source_halt(:replicator_signature)
      refute Map.has_key?(HealthSystem.source_halts(), :replicator_signature)
    end

    test "accepts non-contiguous but monotonic seqs — Sealer counter is node-wide, not per-origin" do
      # Regression: a peer whose local Sealer has been bumped by other
      # origins will emit its own entries at seq values that skip
      # over the intervening bumps. The receiver must accept those
      # gaps as long as seq is strictly increasing.
      {agent_pid, rpc_fn} = build_dynamic_peer()
      _pid = start_replicator(rpc_fn)
      base = Replicator.status(TestReplicator).p2.cursor

      # Simulate peer p2 having received foreign-origin entries between
      # its own writes: its own entries land at base+5, base+11, base+42.
      entries = [
        peer_entry(base + 5),
        peer_entry(base + 11),
        peer_entry(base + 42)
      ]

      Agent.update(agent_pid, fn _ -> entries end)

      :ok = Replicator.tick_now(TestReplicator)

      for entry <- entries do
        assert {:ok, %Payout{}} = FederationStore.get_payout(entry.payload.id)
      end

      assert Replicator.status(TestReplicator).p2.cursor == base + 42
    end

    test "cursor advances from applied entries only, never from responder-claimed new_cursor" do
      # Regression: a malicious (or buggy) peer that returns
      # `{batch: [], new_cursor: 999_999_999}` used to see the
      # follower's cursor jump past every unseen entry, silently
      # skipping them forever (subsequent requests filter
      # `seq > cursor`). Fix: cursor advances to max applied seq only.
      pumping_rpc = fn _node, [request] ->
        case Auth.verify_request(request) do
          {:ok, cursor} ->
            forged =
              Auth.sign_response(
                cursor,
                # Responder claims huge cursor jump…
                cursor + 999_999_999,
                # …with matching tip…
                cursor + 999_999_999,
                # …but ZERO entries. Old code trusted `new_cursor`.
                [],
                request.nonce
              )

            {:ok, forged}

          err ->
            err
        end
      end

      _pid = start_replicator(pumping_rpc)
      before_cursor = Replicator.status(TestReplicator).p2.cursor

      :ok = Replicator.tick_now(TestReplicator)

      after_cursor = Replicator.status(TestReplicator).p2.cursor

      assert after_cursor == before_cursor,
             "cursor MUST NOT advance on an empty batch, even with responder-claimed new_cursor"
    end

    test "cursor advances to max applied entry seq — not responder claim, even on non-empty batch" do
      # Companion to the above: responder returns real entries at
      # seqs {base+2, base+5} with a claimed new_cursor of
      # base+9999. The follower must land at base+5, not base+9999.
      {agent_pid, base_rpc} = build_dynamic_peer()

      # Wrap the base rpc to overwrite the response's cursor field
      # with a bogus one (post-signing), simulating a compromised peer.
      overclaim_rpc = fn node, args ->
        case base_rpc.(node, args) do
          {:ok, response} ->
            {:ok, %{response | cursor: 999_999_999}}

          other ->
            other
        end
      end

      _pid = start_replicator(overclaim_rpc)
      base = Replicator.status(TestReplicator).p2.cursor

      # Because we tampered with the signed response, verify_response
      # rejects it (any post-sign mutation breaks the HMAC) — the
      # cursor stays put. This is the second line of defense; the
      # primary defense is the max-applied-seq logic above.
      Agent.update(agent_pid, fn _ -> [peer_entry(base + 2), peer_entry(base + 5)] end)

      :ok = Replicator.tick_now(TestReplicator)

      cursor_after = Replicator.status(TestReplicator).p2.cursor
      assert cursor_after == base
    end

    test "rejects non-monotonic seqs — batch with a rewind is dropped" do
      {agent_pid, rpc_fn} = build_dynamic_peer()
      _pid = start_replicator(rpc_fn)
      base = Replicator.status(TestReplicator).p2.cursor

      # Second entry rewinds — never valid, since the peer's own seq
      # allocation is strictly monotonic.
      entries = [peer_entry(base + 3), peer_entry(base + 2)]
      Agent.update(agent_pid, fn _ -> entries end)

      :ok = Replicator.tick_now(TestReplicator)

      assert Replicator.status(TestReplicator).p2.cursor == base

      for entry <- entries do
        assert {:error, :not_found} = FederationStore.get_payout(entry.payload.id)
      end
    end
  end

  describe "auth failure" do
    test "rejected response leaves the cursor unchanged" do
      bad_rpc = fn _node, [_request] ->
        # Return a response with a tampered HMAC.
        nonce = :crypto.strong_rand_bytes(16)

        forged =
          Auth.sign_response(0, 1, 1, [peer_entry(1)], nonce)
          |> Map.put(:hmac, :crypto.strong_rand_bytes(32))

        {:ok, forged}
      end

      _pid = start_replicator(bad_rpc)

      # Boot cursor recovery scans the local WAL — the assertion is
      # "cursor doesn't move", not "cursor is 0".
      before_cursor = Replicator.status(TestReplicator).p2.cursor
      :ok = Replicator.tick_now(TestReplicator)
      after_cursor = Replicator.status(TestReplicator).p2.cursor

      assert before_cursor == after_cursor
    end

    test "badrpc reply leaves the cursor unchanged" do
      bad_rpc = fn _node, [_request] -> {:badrpc, :nodedown} end
      _pid = start_replicator(bad_rpc)

      before_cursor = Replicator.status(TestReplicator).p2.cursor
      :ok = Replicator.tick_now(TestReplicator)
      after_cursor = Replicator.status(TestReplicator).p2.cursor

      assert before_cursor == after_cursor
    end
  end

  describe "entries_since/2 (read-side)" do
    test "returns origin-self entries past the cursor, filtered by origin" do
      # Write a local payout so something with origin = :p1 exists in
      # the local WAL.
      payload = %{
        id: unique_id(),
        position_id: unique_position(),
        market_id: unique_market(),
        account_id: unique_account(),
        kind: :winner_payout,
        amount_piconeros: 1_000_000_000_000,
        destination: "47jUE3...",
        status: :enqueued
      }

      payout = struct(Payout, payload)
      :ok = FederationStore.put_payout(payout)

      request = Auth.sign_request(0)

      assert {:ok, response} = Replicator.entries_since(request)
      assert response.cursor == 0
      assert response.new_cursor >= 1
      assert is_list(response.entries)
      assert response.entries != []

      # Every returned entry has origin = :p1 (local).
      assert Enum.all?(response.entries, fn %Entry{payload: %{origin: o}} -> o == :p1 end)

      # And every returned entry has seq > cursor.
      assert Enum.all?(response.entries, fn %Entry{payload: %{seq: s}} -> s > 0 end)
    end
  end
end
