defmodule PerpWalk.Federation.RPC.PeerIntegrationTest do
  @moduledoc """
  Integration tests for the HMAC-protected peer endpoint that
  fronts `Darks.Multisig.{export_info, sign}` on every federation
  node.

  Uses a Darks stub client to avoid talking to a real wallet RPC;
  the focus is the auth shell, not the underlying multisig math.
  """

  use PerpWalk.IntegrationCase

  alias PerpWalk.Federation.{Payout, Store}
  alias PerpWalk.Federation.RPC.{Auth, Peer}

  defmodule StubClient do
    @moduledoc false

    def export_multisig_info, do: {:ok, %{info: "stub-info"}}

    def import_multisig_info(info_list) when is_list(info_list) do
      {:ok, %{n_outputs: length(info_list)}}
    end

    # Test wallet for peer signing — a single small recipient, well
    # under the Peer.Policy default caps. Returns a singleton list to
    # match the post-C1 describe_transfer contract.
    def describe_transfer(_hex) do
      {:ok,
       [
         %{
           recipients: [
             %{
               address:
                 "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge",
               amount: 1_000_000_000_000
             }
           ],
           fee: 10_000_000,
           amount_in: 1_010_000_000_000,
           amount_out: 1_000_000_000_000,
           change_amount: 0,
           change_address: nil,
           unlock_time: 0
         }
       ]}
    end

    def sign_multisig("legit-hex"),
      do: {:ok, %{tx_data_hex: "signed-stub", tx_hash_list: ["txid-1"]}}

    def sign_multisig(other), do: {:error, {:bad_input, other}}
  end

  setup do
    Application.put_env(:darks, :client, StubClient)
    on_exit(fn -> Application.delete_env(:darks, :client) end)

    # Throttle is supervised by the application; clear the window so
    # accumulated reservations from prior tests don't reject later
    # legitimate signs.
    PerpWalk.Federation.Signing.Peer.Throttle.reset()
    :ok
  end

  describe "export_info/1" do
    test "verifies the request, calls the underlying client, returns a signed response" do
      request = Auth.sign_request(:export_info, [])

      assert {:ok, response} = Peer.export_info(request)

      # Round-trip the response through the verifier — same nonce echo,
      # signed under the shared secret.
      assert {:ok, {:ok, %{info: "stub-info"}}} =
               Auth.verify_response(response, :export_info, request.nonce)
    end

    test "rejects an unsigned request shape" do
      assert {:error, :bad_request} = Peer.export_info(0)
      assert {:error, :bad_request} = Peer.export_info(%{method: :export_info})
    end

    test "rejects a request with a tampered HMAC" do
      request = Auth.sign_request(:export_info, [])
      forged = %{request | hmac: :crypto.strong_rand_bytes(32)}
      assert {:error, :unauthorized} = Peer.export_info(forged)
    end

    test "rejects a request that is too old" do
      old_ts = System.system_time(:millisecond) - Auth.clock_skew_ms() - 1_000
      stale = Auth.sign_request_at(:export_info, [], old_ts)
      assert {:error, :stale_request} = Peer.export_info(stale)
    end

    test "rejects a request whose method is :sign (cross-method replay)" do
      sign_req = Auth.sign_request(:sign, "legit-hex")
      # Caller forwarded a :sign request to the export_info endpoint.
      # The handler refuses because the methods don't match.
      assert {:error, :method_mismatch} = Peer.export_info(sign_req)
    end
  end

  describe "sign/1" do
    setup do
      # Ledger binding: the local guardian only co-signs when a
      # `:rules_passed` payout matches the tx's destination + amount.
      # StubClient's describe_transfer returns
      # (4Adu...5Jv2684Rge, 1_000_000_000_000), so seed a matching
      # payout for the sign/1 happy paths.
      matching_payout = %Payout{
        id: "test-payout-#{:erlang.unique_integer([:positive, :monotonic])}",
        market_id: "test-market",
        account_id: "test-account",
        kind: :winner_payout,
        amount_piconeros: 1_000_000_000_000,
        destination: "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge",
        status: :rules_passed,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      :ok = Store.put_payout(matching_payout)
      on_exit(fn -> Store.clear() end)

      %{payout: matching_payout}
    end

    test "verifies the request, signs the unsigned hex, returns a signed response" do
      request = Auth.sign_request(:sign, "legit-hex")

      assert {:ok, response} = Peer.sign(request)

      assert {:ok, {:ok, %{tx_data_hex: "signed-stub", tx_hash_list: ["txid-1"]}}} =
               Auth.verify_response(response, :sign, request.nonce)
    end

    test "refuses to sign when no local :rules_passed payout matches the tx" do
      # Wipe the store's seeded matching payout so the ledger binding
      # has nothing to bind against. Same "legit-hex" input as the
      # happy path; the only difference is the local ledger state.
      Store.clear()

      request = Auth.sign_request(:sign, "legit-hex")
      assert {:ok, response} = Peer.sign(request)

      assert {:ok, {:error, {:policy_rejected, reason}}} =
               Auth.verify_response(response, :sign, request.nonce)

      assert reason =~ "no_matching_payout"
    end

    test "accepts sign when multiple identical :rules_passed payouts exist" do
      # Two winners of the same amount to the same destination is a
      # legitimate state (same user won twice for identical bets).
      # The peer's job is to prove the tx matches SOME business
      # event; disambiguating which specific payout it corresponds
      # to is the leader's concern.
      duplicate = %Payout{
        id: "test-payout-dup-#{:erlang.unique_integer([:positive, :monotonic])}",
        market_id: "test-market-b",
        account_id: "test-account-b",
        kind: :winner_payout,
        amount_piconeros: 1_000_000_000_000,
        destination: "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge",
        status: :rules_passed,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      :ok = Store.put_payout(duplicate)

      request = Auth.sign_request(:sign, "legit-hex")
      assert {:ok, response} = Peer.sign(request)

      assert {:ok, {:ok, %{tx_data_hex: "signed-stub"}}} =
               Auth.verify_response(response, :sign, request.nonce)
    end

    test "args binding: tampering with unsigned_hex invalidates the request" do
      # Attacker captures sign(legit-hex), tries to swap in their own.
      original = Auth.sign_request(:sign, "legit-hex")
      tampered = %{original | args: "evil-hex"}
      assert {:error, :unauthorized} = Peer.sign(tampered)
    end

    test "rejects non-binary args" do
      # The endpoint refuses if the caller signed something other than
      # a binary unsigned-tx hex; protects Darks from being asked to
      # sign weird shapes.
      request = Auth.sign_request(:sign, [:not_a_hex_string])
      assert {:ok, response} = Peer.sign(request)

      assert {:ok, {:error, {:bad_args, [:not_a_hex_string]}}} =
               Auth.verify_response(response, :sign, request.nonce)
    end

    test "rejects an :export_info request routed to the :sign endpoint" do
      export_req = Auth.sign_request(:export_info, [])
      assert {:error, :method_mismatch} = Peer.sign(export_req)
    end
  end

  describe "multisig_info_exchange/1" do
    test "imports caller's info, returns local export in a single round-trip" do
      request = Auth.sign_request(:multisig_info_exchange, "caller-export-hex")

      assert {:ok, response} = Peer.multisig_info_exchange(request)

      # Response payload is the local export (stub returns the static
      # "stub-info" hex). The double-{:ok, ...} shape is `Auth.verify_response/3`
      # unwrapping the transport-level success around the inner result.
      assert {:ok, {:ok, "stub-info"}} =
               Auth.verify_response(response, :multisig_info_exchange, request.nonce)
    end

    test "rejects non-binary args" do
      request = Auth.sign_request(:multisig_info_exchange, %{not: "a binary"})

      assert {:ok, response} = Peer.multisig_info_exchange(request)

      assert {:ok, {:error, {:bad_args, %{not: "a binary"}}}} =
               Auth.verify_response(response, :multisig_info_exchange, request.nonce)
    end

    test "rejects an unsigned request shape" do
      assert {:error, :bad_request} = Peer.multisig_info_exchange(0)
      assert {:error, :bad_request} = Peer.multisig_info_exchange(%{method: :multisig_info_exchange})
    end

    test "rejects a request with a tampered HMAC" do
      request = Auth.sign_request(:multisig_info_exchange, "any-hex")
      forged = %{request | hmac: :crypto.strong_rand_bytes(32)}
      assert {:error, :unauthorized} = Peer.multisig_info_exchange(forged)
    end

    test "rejects a stale request outside the clock skew window" do
      old_ts = System.system_time(:millisecond) - Auth.clock_skew_ms() - 1_000
      stale = Auth.sign_request_at(:multisig_info_exchange, "any-hex", old_ts)
      assert {:error, :stale_request} = Peer.multisig_info_exchange(stale)
    end

    test "rejects an :export_info request routed to the :multisig_info_exchange endpoint" do
      # Cross-method replay protection — args were signed for the
      # other method's HMAC.
      export_req = Auth.sign_request(:export_info, [])
      assert {:error, :method_mismatch} = Peer.multisig_info_exchange(export_req)
    end
  end

  describe "response cannot be replayed across requests" do
    test "captured response from one request fails for another" do
      # Caller A sends export_info, gets a signed response.
      req_a = Auth.sign_request(:export_info, [])
      assert {:ok, response_a} = Peer.export_info(req_a)

      # Caller B (or attacker) tries to use response_a as the answer
      # to a different export_info request (different nonce).
      req_b = Auth.sign_request(:export_info, [])

      assert {:error, :nonce_mismatch} =
               Auth.verify_response(response_a, :export_info, req_b.nonce)
    end
  end

  describe "attest_snapshot/1" do
    # Squeeze the retry budget so divergence tests don't sleep for
    # 6 seconds each.
    setup do
      Application.put_env(:perpwalk, :reserves,
        attestation_max_attempts: 1,
        attestation_retry_interval_ms: 0
      )

      on_exit(fn -> Application.delete_env(:perpwalk, :reserves) end)

      :ok
    end

    test "endorses a leader snapshot whose values match our local source" do
      # In the test env both the markets facade and monero RPC are down,
      # so the local source returns zero total_held and zero outstanding.
      # A leader snapshot reporting the same zero values must be endorsed.
      leader = matching_local_snapshot()
      request = Auth.sign_request(:attest_snapshot, leader)

      assert {:ok, response} = Peer.attest_snapshot(request)

      assert {:ok, {:ok, %{attestation: %Vault.Attestation{} = att, pubkey: pubkey}}} =
               Auth.verify_response(response, :attest_snapshot, request.nonce)

      assert att.snapshot_id == leader.id
      assert att.total_held == leader.total_held
      assert att.outstanding == leader.outstanding

      # Pubkey hashes back to the attestation's guardian_id and the
      # attestation verifies under it.
      assert binary_part(:crypto.hash(:sha256, pubkey), 0, 16) == att.guardian_id
      assert {:ok, ^att} = Vault.Attestation.verify(att, pubkey)
    end

    test "refuses with :divergent when leader's values disagree with ours" do
      # Leader claims a non-zero total_held; our local source reports 0.
      # The handler must refuse and return a structured divergence.
      leader = divergent_snapshot()
      request = Auth.sign_request(:attest_snapshot, leader)

      assert {:ok, response} = Peer.attest_snapshot(request)

      assert {:ok, {:error, {:divergent, payload}}} =
               Auth.verify_response(response, :attest_snapshot, request.nonce)

      assert payload[:theirs].total_held == 999_000_000_000
      assert payload[:ours].total_held == 0
    end

    test "rejects an args shape that is not a Vault.Snapshot" do
      request = Auth.sign_request(:attest_snapshot, :not_a_snapshot)
      assert {:ok, response} = Peer.attest_snapshot(request)

      assert {:ok, {:error, {:bad_args, :not_a_snapshot}}} =
               Auth.verify_response(response, :attest_snapshot, request.nonce)
    end

    test "rejects a tampered HMAC" do
      leader = matching_local_snapshot()
      request = Auth.sign_request(:attest_snapshot, leader)
      forged = %{request | hmac: :crypto.strong_rand_bytes(32)}

      assert {:error, :unauthorized} = Peer.attest_snapshot(forged)
    end

    test "rejects a cross-method replay (sign request routed to attest endpoint)" do
      sign_req = Auth.sign_request(:sign, "legit-hex")
      assert {:error, :method_mismatch} = Peer.attest_snapshot(sign_req)
    end

    # --- helpers ---

    defp matching_local_snapshot do
      # Capture from the same source the handler uses, so values agree
      # by construction. Returns total_held=0, outstanding=0 in the
      # test env (no markets, no monero RPC).
      Vault.Snapshot.capture(PerpWalk.Reserves.Source)
    end

    defp divergent_snapshot do
      # Build a snapshot whose total_held is 0.999 XMR while the local
      # source's is 0 — guaranteed mismatch.
      %{matching_local_snapshot() | total_held: 999_000_000_000}
    end
  end
end
