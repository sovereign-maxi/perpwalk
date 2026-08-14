defmodule PerpWalk.Storage.Replication.AuthIntegrationTest do
  @moduledoc "Integration tests for PerpWalk.Storage.Replication.Auth."

  use PerpWalk.IntegrationCase

  alias PerpWalk.Storage.Replication.Auth

  setup do
    # Snapshot and restore the :replication_secret around each test
    # so individual tests can mutate it without leaking state.
    original = Application.get_env(:perpwalk, :replication_secret)

    on_exit(fn ->
      if original do
        Application.put_env(:perpwalk, :replication_secret, original)
      else
        Application.delete_env(:perpwalk, :replication_secret)
      end
    end)

    :ok
  end

  describe "secret/0" do
    test "returns the configured secret" do
      assert is_binary(Auth.secret())
      assert byte_size(Auth.secret()) >= 32
    end

    test "raises when the secret is missing" do
      Application.delete_env(:perpwalk, :replication_secret)
      assert_raise RuntimeError, ~r/not configured/, fn -> Auth.secret() end
    end

    test "raises when the secret is too short" do
      Application.put_env(:perpwalk, :replication_secret, "short")
      assert_raise RuntimeError, ~r/at least 32 bytes/, fn -> Auth.secret() end
    end
  end

  describe "sign_request/1 + verify_request/1" do
    test "round-trips a valid request" do
      request = Auth.sign_request(42)
      assert request.cursor == 42
      assert is_integer(request.timestamp_ms)
      assert byte_size(request.nonce) == 16
      assert byte_size(request.hmac) == 32

      assert {:ok, 42} = Auth.verify_request(request)
    end

    test "two requests for the same cursor produce different nonces and HMACs" do
      r1 = Auth.sign_request(0)
      r2 = Auth.sign_request(0)
      assert r1.nonce != r2.nonce
      assert r1.hmac != r2.hmac
    end

    test "rejects a request with a tampered HMAC" do
      request = Auth.sign_request(0)
      forged = %{request | hmac: :crypto.strong_rand_bytes(32)}
      assert {:error, :unauthorized} = Auth.verify_request(forged)
    end

    test "rejects a request with a tampered cursor (HMAC was bound to the original)" do
      request = Auth.sign_request(0)
      tampered = %{request | cursor: 99}
      assert {:error, :unauthorized} = Auth.verify_request(tampered)
    end

    test "rejects a request with a tampered nonce" do
      request = Auth.sign_request(0)
      tampered = %{request | nonce: :crypto.strong_rand_bytes(16)}
      assert {:error, :unauthorized} = Auth.verify_request(tampered)
    end

    test "rejects a request that is too old (replay attack)" do
      old_ts = System.system_time(:millisecond) - Auth.clock_skew_ms() - 1_000
      stale = Auth.sign_request_at(0, old_ts)
      assert {:error, :stale_request} = Auth.verify_request(stale)
    end

    test "rejects a request with a future timestamp" do
      future_ts = System.system_time(:millisecond) + Auth.clock_skew_ms() + 1_000
      future = Auth.sign_request_at(0, future_ts)
      assert {:error, :stale_request} = Auth.verify_request(future)
    end

    test "rejects a request with a wrong-sized nonce" do
      request = Auth.sign_request(0)
      bad = %{request | nonce: :crypto.strong_rand_bytes(8)}
      assert {:error, :bad_request} = Auth.verify_request(bad)
    end

    test "rejects a non-map request" do
      assert {:error, :bad_request} = Auth.verify_request(0)
      assert {:error, :bad_request} = Auth.verify_request(nil)
      assert {:error, :bad_request} = Auth.verify_request("0")
    end

    test "rejects a request missing required keys" do
      assert {:error, :bad_request} = Auth.verify_request(%{cursor: 0})

      assert {:error, :bad_request} =
               Auth.verify_request(%{cursor: 0, timestamp_ms: 1, nonce: <<>>})
    end

    test "rejects a request with a different secret" do
      request = Auth.sign_request(0)
      Application.put_env(:perpwalk, :replication_secret, String.duplicate("x", 32))
      assert {:error, :unauthorized} = Auth.verify_request(request)
    end
  end

  describe "sign_response/5 + verify_response/3" do
    test "round-trips a valid response" do
      entries = [%Locker.WAL.Entry{type: :market_put, payload: %{id: "abc"}}]
      nonce = :crypto.strong_rand_bytes(16)
      response = Auth.sign_response(5, 6, 6, entries, nonce)

      assert response.cursor == 5
      assert response.new_cursor == 6
      assert response.peer_tip == 6
      assert response.entries == entries
      assert response.nonce == nonce
      assert is_integer(response.timestamp_ms)
      assert byte_size(response.hmac) == 32

      assert {:ok, ^entries, 6, 6} = Auth.verify_response(response, 5, nonce)
    end

    test "round-trips an empty-delta response" do
      nonce = :crypto.strong_rand_bytes(16)
      response = Auth.sign_response(10, 10, 10, [], nonce)
      assert {:ok, [], 10, 10} = Auth.verify_response(response, 10, nonce)
    end

    test "returns peer_tip ahead of new_cursor when a backlog remains" do
      entries = [%Locker.WAL.Entry{type: :a, payload: %{}}]
      nonce = :crypto.strong_rand_bytes(16)
      response = Auth.sign_response(5, 6, 1_000, entries, nonce)

      assert {:ok, ^entries, 6, 1_000} = Auth.verify_response(response, 5, nonce)
    end

    test "rejects a response signed for a different cursor than the request" do
      nonce = :crypto.strong_rand_bytes(16)
      response = Auth.sign_response(5, 6, 6, [], nonce)
      assert {:error, :cursor_mismatch} = Auth.verify_response(response, 7, nonce)
    end

    test "rejects a response carrying a different nonce than the request" do
      request_nonce = :crypto.strong_rand_bytes(16)
      response = Auth.sign_response(5, 6, 6, [], request_nonce)

      # Caller asks for verification against a different nonce (e.g.
      # an attacker tries to replay a captured response against a
      # fresh request that has its own nonce).
      other_nonce = :crypto.strong_rand_bytes(16)
      assert {:error, :nonce_mismatch} = Auth.verify_response(response, 5, other_nonce)
    end

    test "rejects a tampered HMAC" do
      nonce = :crypto.strong_rand_bytes(16)
      response = Auth.sign_response(5, 6, 6, [], nonce)
      forged = %{response | hmac: :crypto.strong_rand_bytes(32)}
      assert {:error, :unauthorized} = Auth.verify_response(forged, 5, nonce)
    end

    test "rejects a tampered entries list" do
      nonce = :crypto.strong_rand_bytes(16)
      response = Auth.sign_response(5, 6, 6, [%Locker.WAL.Entry{type: :a, payload: %{}}], nonce)
      tampered = %{response | entries: [%Locker.WAL.Entry{type: :evil, payload: %{}}]}
      assert {:error, :unauthorized} = Auth.verify_response(tampered, 5, nonce)
    end

    test "rejects a tampered new_cursor" do
      nonce = :crypto.strong_rand_bytes(16)
      response = Auth.sign_response(5, 6, 6, [], nonce)
      tampered = %{response | new_cursor: 999}
      assert {:error, :unauthorized} = Auth.verify_response(tampered, 5, nonce)
    end

    test "rejects a tampered peer_tip (HMAC binds it)" do
      nonce = :crypto.strong_rand_bytes(16)
      response = Auth.sign_response(5, 6, 6, [], nonce)
      tampered = %{response | peer_tip: 9_999_999}
      assert {:error, :unauthorized} = Auth.verify_response(tampered, 5, nonce)
    end

    test "sign_response/5 refuses to sign a peer_tip below new_cursor" do
      # The signer guard catches the incoherent case at construction
      # time, so a `peer_tip < new_cursor` response can never even be
      # produced by an honest leader. The corresponding verifier branch
      # (`check_peer_tip/2`) protects against a manually-forged
      # response with a tampered peer_tip — that path is covered by
      # the "rejects a tampered peer_tip" test above, which fires
      # `:unauthorized` first.
      nonce = :crypto.strong_rand_bytes(16)

      assert_raise FunctionClauseError, fn ->
        Auth.sign_response(5, 6, 4, [], nonce)
      end
    end

    test "rejects a tampered nonce on the response payload" do
      nonce = :crypto.strong_rand_bytes(16)
      response = Auth.sign_response(5, 6, 6, [], nonce)
      tampered_nonce = :crypto.strong_rand_bytes(16)
      tampered = %{response | nonce: tampered_nonce}
      # Caller verifies against the original nonce — the response's
      # nonce field has been swapped, so nonce_match fires first.
      assert {:error, :nonce_mismatch} = Auth.verify_response(tampered, 5, nonce)
    end

    test "rejects a stale response (replay attack)" do
      nonce = :crypto.strong_rand_bytes(16)
      old_ts = System.system_time(:millisecond) - Auth.clock_skew_ms() - 1_000
      stale = Auth.sign_response_at(5, 6, 6, [], nonce, old_ts)
      assert {:error, :stale_response} = Auth.verify_response(stale, 5, nonce)
    end

    test "rejects a response with a future timestamp" do
      nonce = :crypto.strong_rand_bytes(16)
      future_ts = System.system_time(:millisecond) + Auth.clock_skew_ms() + 1_000
      future = Auth.sign_response_at(5, 6, 6, [], nonce, future_ts)
      assert {:error, :stale_response} = Auth.verify_response(future, 5, nonce)
    end

    test "rejects a non-map response" do
      nonce = :crypto.strong_rand_bytes(16)
      assert {:error, :bad_response} = Auth.verify_response(:not_a_map, 0, nonce)
      assert {:error, :bad_response} = Auth.verify_response(nil, 0, nonce)
    end

    test "rejects a response missing required keys" do
      nonce = :crypto.strong_rand_bytes(16)
      assert {:error, :bad_response} = Auth.verify_response(%{cursor: 0}, 0, nonce)
    end

    test "rejects a response with a different secret" do
      nonce = :crypto.strong_rand_bytes(16)
      response = Auth.sign_response(5, 6, 6, [], nonce)
      Application.put_env(:perpwalk, :replication_secret, String.duplicate("x", 32))
      assert {:error, :unauthorized} = Auth.verify_response(response, 5, nonce)
    end
  end

  describe "constant-time HMAC comparison" do
    # We can't directly probe Plug.Crypto.secure_compare timing in a
    # unit test, but we can confirm the types it sees: both branches
    # should produce binaries of equal size so secure_compare doesn't
    # short-circuit on length difference for legit-shape inputs.
    test "verify_request always produces a 32-byte expected hmac to compare against" do
      request = Auth.sign_request(0)
      assert byte_size(request.hmac) == 32
    end

    test "verify_response always produces a 32-byte expected hmac to compare against" do
      response = Auth.sign_response(0, 0, 0, [], :crypto.strong_rand_bytes(16))
      assert byte_size(response.hmac) == 32
    end
  end
end
