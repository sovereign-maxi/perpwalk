defmodule PerpWalk.Federation.RPC.AuthIntegrationTest do
  @moduledoc "Integration tests for PerpWalk.Federation.RPC.Auth."

  use PerpWalk.IntegrationCase

  alias PerpWalk.Federation.RPC.Auth

  setup do
    original = Application.get_env(:perpwalk, :federation_rpc_secret)

    on_exit(fn ->
      if original do
        Application.put_env(:perpwalk, :federation_rpc_secret, original)
      else
        Application.delete_env(:perpwalk, :federation_rpc_secret)
      end
    end)

    :ok
  end

  describe "secret/0" do
    test "returns the configured secret" do
      assert is_binary(Auth.secret())
      assert byte_size(Auth.secret()) >= 32
    end

    test "raises when missing" do
      Application.delete_env(:perpwalk, :federation_rpc_secret)
      assert_raise RuntimeError, ~r/not configured/, fn -> Auth.secret() end
    end

    test "raises when too short" do
      Application.put_env(:perpwalk, :federation_rpc_secret, "short")
      assert_raise RuntimeError, ~r/at least 32 bytes/, fn -> Auth.secret() end
    end
  end

  describe "sign_request/2 + verify_request/1" do
    test "round-trips :export_info with empty args" do
      req = Auth.sign_request(:export_info, [])
      assert req.method == :export_info
      assert req.args == []
      assert byte_size(req.nonce) == 16
      assert byte_size(req.hmac) == 32

      assert {:ok, :export_info, [], nonce} = Auth.verify_request(req)
      assert nonce == req.nonce
    end

    test "round-trips :sign with a binary unsigned_hex" do
      hex = "deadbeef" <> String.duplicate("a", 200)
      req = Auth.sign_request(:sign, hex)
      assert {:ok, :sign, ^hex, _nonce} = Auth.verify_request(req)
    end

    test "two requests for the same method/args produce different nonces" do
      r1 = Auth.sign_request(:export_info, [])
      r2 = Auth.sign_request(:export_info, [])
      assert r1.nonce != r2.nonce
      assert r1.hmac != r2.hmac
    end

    test "rejects a request with a tampered HMAC" do
      req = Auth.sign_request(:export_info, [])
      forged = %{req | hmac: :crypto.strong_rand_bytes(32)}
      assert {:error, :unauthorized} = Auth.verify_request(forged)
    end

    test "rejects a request whose method has been swapped" do
      # Sign as :export_info, swap the method to :sign — HMAC was
      # bound to the original method, so the swap invalidates it.
      req = Auth.sign_request(:export_info, [])
      swapped = %{req | method: :sign}
      assert {:error, :unauthorized} = Auth.verify_request(swapped)
    end

    test "rejects a request with tampered args (binding defense)" do
      req = Auth.sign_request(:sign, "original-hex")
      tampered = %{req | args: "evil-hex"}
      assert {:error, :unauthorized} = Auth.verify_request(tampered)
    end

    test "rejects a request with a method outside the allowlist" do
      # Sign with a method NOT in allowed_methods — verify must
      # reject as :unknown_method even before HMAC check.
      req = Auth.sign_request(:rogue_method, [])
      assert {:error, :unknown_method} = Auth.verify_request(req)
    end

    test "rejects a request that is too old (replay defence)" do
      old_ts = System.system_time(:millisecond) - Auth.clock_skew_ms() - 1_000
      stale = Auth.sign_request_at(:export_info, [], old_ts)
      assert {:error, :stale_request} = Auth.verify_request(stale)
    end

    test "rejects a request with a future timestamp" do
      future_ts = System.system_time(:millisecond) + Auth.clock_skew_ms() + 1_000
      future = Auth.sign_request_at(:sign, "hex", future_ts)
      assert {:error, :stale_request} = Auth.verify_request(future)
    end

    test "rejects malformed shapes" do
      assert {:error, :bad_request} = Auth.verify_request(nil)
      assert {:error, :bad_request} = Auth.verify_request(%{})
      assert {:error, :bad_request} = Auth.verify_request(%{method: :sign})
    end

    test "rejects under a different secret" do
      req = Auth.sign_request(:export_info, [])
      Application.put_env(:perpwalk, :federation_rpc_secret, String.duplicate("x", 32))
      assert {:error, :unauthorized} = Auth.verify_request(req)
    end
  end

  describe "sign_response/3 + verify_response/3" do
    test "round-trips with the request's nonce echoed back" do
      req = Auth.sign_request(:export_info, [])
      result = {:ok, %{info: "abc", offset: 17}}
      response = Auth.sign_response(:export_info, result, req.nonce)

      assert {:ok, ^result} = Auth.verify_response(response, :export_info, req.nonce)
    end

    test "rejects when the response is for a different method" do
      req = Auth.sign_request(:export_info, [])
      response = Auth.sign_response(:sign, {:ok, %{tx_data_hex: "xyz"}}, req.nonce)
      assert {:error, :method_mismatch} = Auth.verify_response(response, :export_info, req.nonce)
    end

    test "rejects when the response carries a different nonce (replay)" do
      req = Auth.sign_request(:sign, "hex")
      response = Auth.sign_response(:sign, {:ok, %{tx_data_hex: "signed"}}, req.nonce)

      # Caller checks against a freshly-minted nonce — the captured
      # response must not validate.
      different_nonce = :crypto.strong_rand_bytes(16)
      assert {:error, :nonce_mismatch} = Auth.verify_response(response, :sign, different_nonce)
    end

    test "rejects a tampered HMAC" do
      req = Auth.sign_request(:export_info, [])
      response = Auth.sign_response(:export_info, {:ok, "x"}, req.nonce)
      forged = %{response | hmac: :crypto.strong_rand_bytes(32)}
      assert {:error, :unauthorized} = Auth.verify_response(forged, :export_info, req.nonce)
    end

    test "rejects a tampered result" do
      req = Auth.sign_request(:sign, "hex")
      response = Auth.sign_response(:sign, {:ok, %{tx_data_hex: "legit"}}, req.nonce)
      tampered = %{response | result: {:ok, %{tx_data_hex: "evil"}}}
      assert {:error, :unauthorized} = Auth.verify_response(tampered, :sign, req.nonce)
    end

    test "rejects a stale response (replay)" do
      req = Auth.sign_request(:export_info, [])
      old_ts = System.system_time(:millisecond) - Auth.clock_skew_ms() - 1_000
      stale = Auth.sign_response_at(:export_info, {:ok, "x"}, req.nonce, old_ts)
      assert {:error, :stale_response} = Auth.verify_response(stale, :export_info, req.nonce)
    end

    test "rejects malformed shapes" do
      nonce = :crypto.strong_rand_bytes(16)
      assert {:error, :bad_response} = Auth.verify_response(nil, :sign, nonce)
      assert {:error, :bad_response} = Auth.verify_response(%{}, :sign, nonce)
    end

    test "rejects under a different secret" do
      req = Auth.sign_request(:export_info, [])
      response = Auth.sign_response(:export_info, {:ok, "x"}, req.nonce)
      Application.put_env(:perpwalk, :federation_rpc_secret, String.duplicate("x", 32))
      assert {:error, :unauthorized} = Auth.verify_response(response, :export_info, req.nonce)
    end
  end

  describe "cross-method replay defence" do
    test "an :export_info request signature cannot be replayed as :sign" do
      # Attacker captures a valid :export_info request and tries
      # to use it to drive the :sign endpoint.
      export_req = Auth.sign_request(:export_info, [])
      replay_attempt = %{export_req | method: :sign, args: "evil-hex"}

      # Even if the verifier is told to accept :sign, the HMAC check
      # fails because the signature was over (:export_info, []).
      assert {:error, :unauthorized} = Auth.verify_request(replay_attempt)
    end

    test "an :export_info response signature cannot be replayed as :sign" do
      export_req = Auth.sign_request(:export_info, [])
      response = Auth.sign_response(:export_info, {:ok, "info"}, export_req.nonce)

      # Try to use the captured response as a :sign reply.
      sign_req = Auth.sign_request(:sign, "hex")
      forged = %{response | method: :sign, nonce: sign_req.nonce}

      # The HMAC was over the original method+nonce; both swaps invalidate.
      assert {:error, _} = Auth.verify_response(forged, :sign, sign_req.nonce)
    end
  end
end
