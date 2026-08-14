defmodule PerpWalk.Identity.SessionsIntegrationTest do
  @moduledoc """
  Integration tests for `PerpWalk.Identity.Sessions`.
  Runs against the application-supervised store.
  """

  use PerpWalk.IntegrationCase

  alias PerpWalk.Identity.Sessions

  describe "create/1 + lookup/1" do
    test "round-trips a fresh session_id back to its account" do
      session_id = Sessions.create("acct-a")
      assert is_binary(session_id)
      assert byte_size(session_id) >= 32
      assert {:ok, "acct-a"} = Sessions.lookup(session_id)
    end

    test "two creates for the same account yield distinct session_ids" do
      s1 = Sessions.create("acct-a")
      s2 = Sessions.create("acct-a")
      assert s1 != s2
      assert {:ok, "acct-a"} = Sessions.lookup(s1)
      assert {:ok, "acct-a"} = Sessions.lookup(s2)
    end

    test "lookup of an unknown session_id returns :not_found" do
      assert {:error, :not_found} = Sessions.lookup("never-minted")
    end

    test "lookup of a non-binary returns :not_found" do
      assert {:error, :not_found} = Sessions.lookup(nil)
      assert {:error, :not_found} = Sessions.lookup(0)
    end
  end

  describe "revoke/1" do
    test "removes the session_id so subsequent lookups fail" do
      session_id = Sessions.create("acct-a")
      assert {:ok, _} = Sessions.lookup(session_id)

      :ok = Sessions.revoke(session_id)

      assert {:error, :not_found} = Sessions.lookup(session_id)
    end

    test "is idempotent for an already-revoked session_id" do
      session_id = Sessions.create("acct-a")
      :ok = Sessions.revoke(session_id)
      :ok = Sessions.revoke(session_id)
    end

    test "is idempotent for an unknown session_id" do
      assert :ok = Sessions.revoke("never-existed")
    end

    test "leaves other sessions untouched" do
      s_a = Sessions.create("acct-a")
      s_b = Sessions.create("acct-b")

      :ok = Sessions.revoke(s_a)

      assert {:error, :not_found} = Sessions.lookup(s_a)
      assert {:ok, "acct-b"} = Sessions.lookup(s_b)
    end
  end

  describe "revoke_all_for_account/1" do
    test "revokes every session_id bound to the given account" do
      s1 = Sessions.create("acct-a")
      s2 = Sessions.create("acct-a")
      s3 = Sessions.create("acct-a")
      other = Sessions.create("acct-b")

      assert Sessions.revoke_all_for_account("acct-a") == 3

      assert {:error, :not_found} = Sessions.lookup(s1)
      assert {:error, :not_found} = Sessions.lookup(s2)
      assert {:error, :not_found} = Sessions.lookup(s3)
      assert {:ok, "acct-b"} = Sessions.lookup(other)
    end

    test "returns 0 when the account has no live sessions" do
      assert Sessions.revoke_all_for_account("nobody") == 0
    end
  end

  describe "count/0" do
    test "tracks the number of live sessions" do
      _ = Sessions.create("acct-a")
      _ = Sessions.create("acct-b")
      assert Sessions.count() == 2

      _ = Sessions.create("acct-c")
      assert Sessions.count() == 3
    end
  end

  describe "per-account session cap" do
    test "the (N+1)th login revokes the oldest session for that account" do
      first = Sessions.create("acct-capped")

      for _ <- 1..20 do
        Sessions.create("acct-capped")
      end

      # Cap is 20: the oldest session was evicted to make room, the
      # account never exceeds 20 live rows no matter how many logins.
      assert {:error, :not_found} = Sessions.lookup(first)

      all =
        Sessions.table_name()
        |> :ets.match({:"$1", "acct-capped", :_, :_})
        |> length()

      assert all == 20
    end

    test "cap enforcement is per-account — other accounts keep their sessions" do
      bystander = Sessions.create("acct-bystander")

      for _ <- 1..25 do
        Sessions.create("acct-spammy")
      end

      assert {:ok, "acct-bystander"} = Sessions.lookup(bystander)
    end
  end

  describe "TTL sweep" do
    test "sweeping an expired session broadcasts :session_revoked like an explicit revoke" do
      sid = "swept-session-id"
      old_ts = System.system_time(:millisecond) - 31 * 24 * 60 * 60 * 1_000

      :ets.insert(
        Sessions.table_name(),
        {sid, "acct-old", old_ts, :erlang.unique_integer([:monotonic, :positive])}
      )

      Phoenix.PubSub.subscribe(PerpWalk.PubSub, Sessions.topic(sid))

      send(Process.whereis(Sessions), :sweep)

      assert_receive {:session_revoked, ^sid}, 1000
      assert {:error, :not_found} = Sessions.lookup(sid)
    end
  end

  describe "nostr_seckey binding" do
    test "create/2 with :nostr_seckey stores the key and lookup_nostr_seckey/1 returns it" do
      seckey = :crypto.strong_rand_bytes(32)
      session_id = Sessions.create("acct-a", nostr_seckey: seckey)

      assert {:ok, ^seckey} = Sessions.lookup_nostr_seckey(session_id)
    end

    test "create/1 without :nostr_seckey leaves the seckey nil; lookup returns :no_nostr_key" do
      session_id = Sessions.create("acct-a")
      assert {:error, :no_nostr_key} = Sessions.lookup_nostr_seckey(session_id)
    end

    test "lookup_nostr_seckey/1 returns :not_found for unknown session_ids" do
      assert {:error, :not_found} = Sessions.lookup_nostr_seckey("missing-session-id")
    end

    test "lookup_nostr_seckey/1 returns :not_found for non-binary inputs" do
      assert {:error, :not_found} = Sessions.lookup_nostr_seckey(:not_a_binary)
      assert {:error, :not_found} = Sessions.lookup_nostr_seckey(nil)
    end

    test "revoke/1 clears the nostr_seckey along with the account binding" do
      seckey = :crypto.strong_rand_bytes(32)
      session_id = Sessions.create("acct-a", nostr_seckey: seckey)
      assert {:ok, ^seckey} = Sessions.lookup_nostr_seckey(session_id)

      :ok = Sessions.revoke(session_id)

      assert {:error, :not_found} = Sessions.lookup(session_id)
      assert {:error, :not_found} = Sessions.lookup_nostr_seckey(session_id)
    end

    test "revoke_all_for_account/1 clears nostr_seckeys for every session of the account" do
      sk1 = :crypto.strong_rand_bytes(32)
      sk2 = :crypto.strong_rand_bytes(32)
      s1 = Sessions.create("acct-a", nostr_seckey: sk1)
      s2 = Sessions.create("acct-a", nostr_seckey: sk2)
      other = Sessions.create("acct-b", nostr_seckey: :crypto.strong_rand_bytes(32))

      assert 2 = Sessions.revoke_all_for_account("acct-a")

      assert {:error, :not_found} = Sessions.lookup_nostr_seckey(s1)
      assert {:error, :not_found} = Sessions.lookup_nostr_seckey(s2)
      # Untouched.
      assert {:ok, _} = Sessions.lookup_nostr_seckey(other)
    end

    test "lookup/1 still returns the account_id even with a bound nostr_seckey" do
      seckey = :crypto.strong_rand_bytes(32)
      session_id = Sessions.create("acct-a", nostr_seckey: seckey)
      assert {:ok, "acct-a"} = Sessions.lookup(session_id)
    end
  end

  describe "WAL persistence + replay" do
    test "session + bound seckey both survive a Sessions process restart via WAL replay" do
      # Mint a couple of sessions. Both the public (sid, account_id)
      # binding AND the bound nostr_seckey are WAL-persisted and
      # SHOULD survive restart — the comment-signing UX depends on
      # the seckey coming back alongside the session.
      seckey = :crypto.strong_rand_bytes(32)
      s_persisted = Sessions.create("acct-a", nostr_seckey: seckey)
      s_other = Sessions.create("acct-b")

      assert {:ok, "acct-a"} = Sessions.lookup(s_persisted)
      assert {:ok, ^seckey} = Sessions.lookup_nostr_seckey(s_persisted)

      # Simulate a Phoenix restart by stopping the Sessions GenServer
      # and wiping its ETS tables. The supervisor will revive the
      # GenServer, which replays the WAL on init.
      pid_before = Process.whereis(Sessions)
      assert is_pid(pid_before)
      ref = Process.monitor(pid_before)

      :ok = Supervisor.terminate_child(PerpWalk.Identity.Supervisor, Sessions)
      assert_receive {:DOWN, ^ref, :process, ^pid_before, _}, 1000

      # Wipe the in-memory ETS tables to model "BEAM restart".
      try do
        :ets.delete(Sessions.table_name())
      rescue
        ArgumentError -> :ok
      end

      try do
        :ets.delete(Module.concat(Sessions, Secrets))
      rescue
        ArgumentError -> :ok
      end

      {:ok, _pid_after} = Supervisor.restart_child(PerpWalk.Identity.Supervisor, Sessions)

      # The (sid, account_id) bindings come back via WAL replay.
      assert {:ok, "acct-a"} = Sessions.lookup(s_persisted)
      assert {:ok, "acct-b"} = Sessions.lookup(s_other)

      # The bound nostr_seckey comes back too. The /data volume is
      # encrypted at rest and the federation's master signing key is already
      # on the same volume by necessity, so persisting per-user
      # seckeys alongside the session row changes the seizure
      # scenario only cosmetically while fixing the deploy-breaks-
      # comments UX bug.
      assert {:ok, ^seckey} = Sessions.lookup_nostr_seckey(s_persisted)
    end

    test "revoke survives a Sessions process restart" do
      s = Sessions.create("acct-a")
      :ok = Sessions.revoke(s)

      pid_before = Process.whereis(Sessions)
      ref = Process.monitor(pid_before)
      :ok = Supervisor.terminate_child(PerpWalk.Identity.Supervisor, Sessions)
      assert_receive {:DOWN, ^ref, :process, ^pid_before, _}, 1000

      try do
        :ets.delete(Sessions.table_name())
      rescue
        ArgumentError -> :ok
      end

      try do
        :ets.delete(Module.concat(Sessions, Secrets))
      rescue
        ArgumentError -> :ok
      end

      {:ok, _} = Supervisor.restart_child(PerpWalk.Identity.Supervisor, Sessions)

      assert {:error, :not_found} = Sessions.lookup(s)
    end
  end
end
