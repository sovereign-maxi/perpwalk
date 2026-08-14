defmodule PerpWalk.Federation.RPC.Auth do
  @moduledoc """
  HMAC-SHA256 authentication for inter-guardian Monero signing
  RPC.

  Same threat model as `PerpWalk.Storage.Replication.Auth`:
  Erlang distribution cookie alone is not sufficient. Anyone who
  has the cookie (or compromises a guardian) can call any exported
  function on another guardian's BEAM node. For the Monero signing
  path specifically, an unauthenticated `:rpc.call` to
  `Darks.Multisig.sign/1` would let the caller obtain a 2-of-3
  signature on any unsigned tx blob — equivalent to letting them
  drain the wallet.

  This module gates that path behind an application-level shared
  secret (`:federation_rpc_secret`). Bound to:

  - **Method discriminator** — every signed request carries the
    method name (`:export_info` | `:sign`) inside the HMAC, so a
    captured `:export_info` signature cannot be replayed as a
    `:sign` signature.
  - **Args digest** — the SHA-256 of `:erlang.term_to_binary(args)`
    is mixed into the HMAC, binding the signature to the exact
    arguments. An attacker who captures `sign(blob_A)` cannot
    replay it as `sign(blob_B)`.
  - **Nonce echo** — the request's 16-byte nonce is echoed in
    the response and bound into the response HMAC. A captured
    response is useless for a different request (different nonce).
  - **Timestamp window** — both directions reject anything outside
    `@clock_skew_ms` to bound replay risk.

  Pure module — no GenServer, no IO, no process state.

  ## Configuration

      config :perpwalk, :federation_rpc_secret,
        System.fetch_env!("PERPWALK_FEDERATION_RPC_SECRET")

  Must be at least 32 bytes. Different from `:replication_secret`
  on purpose — a leak of one shouldn't compromise the other.
  """

  @clock_skew_ms 60_000
  @nonce_bytes 16
  @min_secret_bytes 32

  @type method ::
          :export_info
          | :sign
          | :bootstrap_create_wallet
          | :bootstrap_prepare
          | :bootstrap_make
          | :bootstrap_exchange_keys
          | :attest_snapshot
          | :multisig_info_exchange
  @type args :: term()
  @type result :: term()

  @type request :: %{
          required(:method) => method(),
          required(:args) => args(),
          required(:timestamp_ms) => integer(),
          required(:nonce) => binary(),
          required(:hmac) => binary()
        }

  @type response :: %{
          required(:method) => method(),
          required(:result) => result(),
          required(:timestamp_ms) => integer(),
          required(:nonce) => binary(),
          required(:hmac) => binary()
        }

  @type request_error ::
          :bad_request
          | :unauthorized
          | :stale_request
          | :unknown_method
          | :replay
          | :replay_cache_unavailable
  @type response_error ::
          :bad_response | :unauthorized | :stale_response | :method_mismatch | :nonce_mismatch

  # --- Secret Access ---

  @spec secret() :: binary()
  def secret do
    case Application.fetch_env(:perpwalk, :federation_rpc_secret) do
      {:ok, s} when is_binary(s) and byte_size(s) >= @min_secret_bytes ->
        s

      {:ok, _} ->
        raise ":federation_rpc_secret must be a binary of at least #{@min_secret_bytes} bytes"

      :error ->
        raise ":federation_rpc_secret is not configured"
    end
  end

  @spec clock_skew_ms() :: pos_integer()
  def clock_skew_ms, do: @clock_skew_ms

  @doc "Allowed methods. Anything outside this list is rejected as `:unknown_method`."
  @spec allowed_methods() :: [method()]
  def allowed_methods,
    do: [
      :export_info,
      :sign,
      :bootstrap_create_wallet,
      :bootstrap_prepare,
      :bootstrap_make,
      :bootstrap_exchange_keys,
      :attest_snapshot,
      :multisig_info_exchange
    ]

  # --- Request ---

  @spec sign_request(method(), args()) :: request()
  def sign_request(method, args) when is_atom(method) do
    sign_request_at(method, args, System.system_time(:millisecond))
  end

  @doc false
  # Test seam — sign with an explicit timestamp so freshness can
  # be exercised without time travel.
  @spec sign_request_at(method(), args(), integer()) :: request()
  def sign_request_at(method, args, timestamp_ms)
      when is_atom(method) and is_integer(timestamp_ms) and timestamp_ms >= 0 do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)
    hmac = request_hmac(method, args, timestamp_ms, nonce, secret())

    %{method: method, args: args, timestamp_ms: timestamp_ms, nonce: nonce, hmac: hmac}
  end

  @doc """
  Verifies a request. Returns `{:ok, method, args, nonce}` on
  success — the verifier should pass `nonce` through to
  `sign_response/3` so the response binds back to the request.
  """
  @spec verify_request(term()) ::
          {:ok, method(), args(), binary()} | {:error, request_error()}
  def verify_request(%{method: m, args: a, timestamp_ms: ts, nonce: n, hmac: h})
      when is_atom(m) and is_integer(ts) and ts >= 0 and is_binary(n) and
             byte_size(n) == @nonce_bytes and is_binary(h) do
    cond do
      m not in allowed_methods() ->
        {:error, :unknown_method}

      not Plug.Crypto.secure_compare(h, request_hmac(m, a, ts, n, secret())) ->
        {:error, :unauthorized}

      not within_skew?(ts) ->
        {:error, :stale_request}

      true ->
        accept_nonce(m, a, n, ts)
    end
  end

  def verify_request(_), do: {:error, :bad_request}

  # Atomic accept-and-record so a captured :sign request can't be
  # replayed against the same peer inside the skew window. Same
  # Nonces store as the replication path — federation-RPC nonces
  # share the table, which is fine because nonce_bytes are 16
  # random bytes (collision probability vanishingly small).
  defp accept_nonce(method, args, nonce, ts) do
    case PerpWalk.Storage.Replication.Nonces.accept(:federation_rpc, nonce, ts) do
      :ok -> {:ok, method, args, nonce}
      {:error, :replay} -> {:error, :replay}
      {:error, :unavailable} -> {:error, :replay_cache_unavailable}
    end
  end

  # --- Response ---

  @spec sign_response(method(), result(), binary()) :: response()
  def sign_response(method, result, nonce)
      when is_atom(method) and is_binary(nonce) and byte_size(nonce) == @nonce_bytes do
    sign_response_at(method, result, nonce, System.system_time(:millisecond))
  end

  @doc false
  @spec sign_response_at(method(), result(), binary(), integer()) :: response()
  def sign_response_at(method, result, nonce, timestamp_ms)
      when is_atom(method) and is_binary(nonce) and byte_size(nonce) == @nonce_bytes and
             is_integer(timestamp_ms) and timestamp_ms >= 0 do
    hmac = response_hmac(method, result, timestamp_ms, nonce, secret())

    %{method: method, result: result, timestamp_ms: timestamp_ms, nonce: nonce, hmac: hmac}
  end

  @doc """
  Verifies a response. The caller passes the `expected_method`
  and the `expected_nonce` from its own original request. Both
  must match — a captured response from one call cannot be
  replayed against a different call.
  """
  @spec verify_response(term(), method(), binary()) ::
          {:ok, result()} | {:error, response_error()}
  def verify_response(
        %{method: m, result: r, timestamp_ms: ts, nonce: n, hmac: h},
        expected_method,
        expected_nonce
      )
      when is_atom(m) and is_integer(ts) and ts >= 0 and is_binary(n) and is_binary(h) and
             is_atom(expected_method) and is_binary(expected_nonce) do
    cond do
      m != expected_method ->
        {:error, :method_mismatch}

      # Constant-time so response-time variance can't be used to
      # recover the expected nonce a byte at a time and forge a
      # later response. The nonce is a per-call secret.
      not Plug.Crypto.secure_compare(n, expected_nonce) ->
        {:error, :nonce_mismatch}

      not Plug.Crypto.secure_compare(h, response_hmac(m, r, ts, n, secret())) ->
        {:error, :unauthorized}

      not within_skew?(ts) ->
        {:error, :stale_response}

      true ->
        {:ok, r}
    end
  end

  def verify_response(_, _, _), do: {:error, :bad_response}

  # --- Internal ---

  # `:erlang.term_to_binary/1` is not canonical: without the
  # `:deterministic` flag, maps with atom keys can be encoded in
  # arbitrary order, and an RPC serialize/deserialize roundtrip is
  # enough to flip the bytes for a logically identical term — even
  # on the same OTP version. Two nodes with identical secrets would
  # then disagree on the args/result digest and reject each other
  # with `:unauthorized`. `[:deterministic]` (OTP 26+) locks the
  # encoding so digests match across nodes and roundtrips.
  #
  # Version-prefix bump (`-request-v1` → `-request-v2`) is still the
  # migration knob if the wire format ever needs to change for other
  # reasons.
  defp request_hmac(method, args, ts, nonce, secret) do
    args_digest = :crypto.hash(:sha256, :erlang.term_to_binary(args, [:deterministic]))
    method_bin = Atom.to_string(method)

    msg =
      <<"perpwalk-federation-rpc-request-v1:", byte_size(method_bin)::8, method_bin::binary, ts::64, nonce::binary,
        args_digest::binary>>

    :crypto.mac(:hmac, :sha256, secret, msg)
  end

  defp response_hmac(method, result, ts, nonce, secret) do
    result_digest = :crypto.hash(:sha256, :erlang.term_to_binary(result, [:deterministic]))
    method_bin = Atom.to_string(method)

    msg =
      <<"perpwalk-federation-rpc-response-v1:", byte_size(method_bin)::8, method_bin::binary, ts::64, nonce::binary,
        result_digest::binary>>

    :crypto.mac(:hmac, :sha256, secret, msg)
  end

  defp within_skew?(ts) do
    abs(System.system_time(:millisecond) - ts) <= @clock_skew_ms
  end
end
