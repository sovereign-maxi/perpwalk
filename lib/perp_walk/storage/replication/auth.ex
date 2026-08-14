defmodule PerpWalk.Storage.Replication.Auth do
  @moduledoc """
  HMAC-SHA256 authentication for inter-node WAL replication RPC.

  The Erlang distribution cookie alone is insufficient — once an
  attacker has it (or compromises a guardian), they can call
  any function on any node via `:rpc.call`. This module adds an
  application-level shared-secret HMAC over the replication
  request/response payloads so that:

  - **Read-side**: a peer rejects `entries_since/1` calls that
    don't carry a valid HMAC, preventing WAL exfiltration by anyone
    who has only the BEAM cookie.
  - **Write-side**: the calling peer rejects responses it cannot
    verify, preventing a misconfigured or malicious peer from
    injecting fake entries.

  Each request and response carries a wall-clock timestamp; the
  verifier rejects anything outside the clock-skew window
  (`@clock_skew_ms`). Requests also carry a 16-byte random nonce
  so two concurrent ticks never produce identical HMACs, and the
  nonce is single-use within the skew window
  (`PerpWalk.Storage.Replication.Nonces`).

  Pure module — no GenServer, no IO, no process state.

  ## Symmetric model

  In the symmetric federation, every node both PUBLISHES (responds
  to `entries_since`) and CONSUMES (calls `entries_since` against
  its peers). `cursor` here is the calling node's high-water mark
  for the responder's origin — "send me entries with origin =
  yourself and seq > cursor". `peer_tip` is the responder's
  current local seq tip, used by the caller for lag telemetry.

  ## Configuration

      config :perpwalk, :replication_secret, System.fetch_env!("PERPWALK_REPLICATION_SECRET")

  The secret must be at least 32 bytes. `secret/0` raises if it's
  missing or too short — production fails fast at first use.

  ## Single-method scope

  This module currently authenticates exactly one RPC: a peer's
  `entries_since/1`. The request HMAC binds `cursor + ts + nonce`
  but NOT a method discriminator — adequate while there is only one
  method to confuse with. Adding a second replication RPC MUST bind
  a method name into the HMAC.
  """

  @clock_skew_ms 60_000
  @nonce_bytes 16
  @min_secret_bytes 32

  @type request :: %{
          required(:cursor) => non_neg_integer(),
          required(:timestamp_ms) => integer(),
          required(:nonce) => binary(),
          required(:hmac) => binary()
        }

  @type response :: %{
          required(:cursor) => non_neg_integer(),
          required(:new_cursor) => non_neg_integer(),
          required(:peer_tip) => non_neg_integer(),
          required(:entries) => [Locker.WAL.Entry.t()],
          required(:nonce) => binary(),
          required(:timestamp_ms) => integer(),
          required(:hmac) => binary()
        }

  @type request_error :: :bad_request | :unauthorized | :stale_request
  @type response_error ::
          :bad_response
          | :unauthorized
          | :stale_response
          | :cursor_mismatch
          | :nonce_mismatch

  @doc """
  Returns the configured shared secret. Raises if missing or
  shorter than 32 bytes.
  """
  @spec secret() :: binary()
  def secret do
    case Application.fetch_env(:perpwalk, :replication_secret) do
      {:ok, s} when is_binary(s) and byte_size(s) >= @min_secret_bytes ->
        s

      {:ok, _} ->
        raise ":replication_secret must be a binary of at least #{@min_secret_bytes} bytes"

      :error ->
        raise ":replication_secret is not configured"
    end
  end

  @doc "Returns the configured clock-skew window in milliseconds."
  @spec clock_skew_ms() :: pos_integer()
  def clock_skew_ms, do: @clock_skew_ms

  @doc """
  Builds a signed request for the given cursor. The caller attaches
  the result as the only argument of an `entries_since/1` RPC call.
  """
  @spec sign_request(non_neg_integer()) :: request()
  def sign_request(cursor) when is_integer(cursor) and cursor >= 0 do
    sign_request_at(cursor, System.system_time(:millisecond))
  end

  @doc false
  # Test seam: sign with a caller-supplied timestamp so the test
  # suite can exercise the freshness window without time travel.
  @spec sign_request_at(non_neg_integer(), integer()) :: request()
  def sign_request_at(cursor, timestamp_ms)
      when is_integer(cursor) and cursor >= 0 and is_integer(timestamp_ms) and
             timestamp_ms >= 0 do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)
    hmac = request_hmac(cursor, timestamp_ms, nonce, secret())
    %{cursor: cursor, timestamp_ms: timestamp_ms, nonce: nonce, hmac: hmac}
  end

  @doc """
  Verifies a request. Returns `{:ok, cursor}` on success.

  Failures:

  - `:bad_request` — shape is wrong.
  - `:unauthorized` — HMAC does not match.
  - `:stale_request` — timestamp is outside the skew window.
  - `:replay` — nonce was already seen inside the skew window.
  """
  @spec verify_request(term()) ::
          {:ok, non_neg_integer()}
          | {:error, request_error() | :replay | :replay_cache_unavailable}
  def verify_request(%{cursor: c, timestamp_ms: ts, nonce: n, hmac: h})
      when is_integer(c) and c >= 0 and is_integer(ts) and ts >= 0 and is_binary(n) and
             byte_size(n) == @nonce_bytes and is_binary(h) do
    expected = request_hmac(c, ts, n, secret())

    cond do
      not Plug.Crypto.secure_compare(h, expected) ->
        {:error, :unauthorized}

      not within_skew?(ts) ->
        {:error, :stale_request}

      true ->
        accept_nonce(c, n, ts)
    end
  end

  def verify_request(_), do: {:error, :bad_request}

  # Atomic accept-and-record so two concurrent verifications of the
  # same captured request can't both succeed. `:unavailable` means
  # the cache backing was torn down — fail closed (the cache is
  # load-bearing for replay protection).
  defp accept_nonce(cursor, nonce, ts) do
    case PerpWalk.Storage.Replication.Nonces.accept(:replication, nonce, ts) do
      :ok -> {:ok, cursor}
      {:error, :replay} -> {:error, :replay}
      {:error, :unavailable} -> {:error, :replay_cache_unavailable}
    end
  end

  @doc """
  Builds a signed response. `entries` must already be the slice
  past `cursor` carrying the responder's origin; `new_cursor` must
  equal the highest seq in that slice (or `cursor` if the slice is
  empty).

  `peer_tip` is the responder's local seq tip at signing time, used
  by the caller for lag telemetry. Bound into the HMAC.

  `nonce` MUST be the request's nonce — it is bound into the
  response HMAC and echoed in the payload so a captured response
  cannot be replayed as the answer to a different request, even
  within the skew window.
  """
  @spec sign_response(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [Locker.WAL.Entry.t()],
          binary()
        ) :: response()
  def sign_response(cursor, new_cursor, peer_tip, entries, nonce)
      when is_binary(nonce) and byte_size(nonce) == @nonce_bytes do
    sign_response_at(
      cursor,
      new_cursor,
      peer_tip,
      entries,
      nonce,
      System.system_time(:millisecond)
    )
  end

  @doc false
  @spec sign_response_at(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [Locker.WAL.Entry.t()],
          binary(),
          integer()
        ) :: response()
  def sign_response_at(cursor, new_cursor, peer_tip, entries, nonce, timestamp_ms)
      when is_integer(cursor) and cursor >= 0 and is_integer(new_cursor) and
             new_cursor >= cursor and is_integer(peer_tip) and peer_tip >= new_cursor and
             is_list(entries) and is_binary(nonce) and byte_size(nonce) == @nonce_bytes and
             is_integer(timestamp_ms) and timestamp_ms >= 0 do
    unsigned = %{
      cursor: cursor,
      new_cursor: new_cursor,
      peer_tip: peer_tip,
      entries: entries,
      nonce: nonce,
      timestamp_ms: timestamp_ms
    }

    Map.put(unsigned, :hmac, response_hmac(unsigned, secret()))
  end

  @doc """
  Verifies a response from the peer. `expected_cursor` and
  `expected_nonce` are the cursor + nonce the caller asked for —
  binding the response to the request prevents a swapped-in old
  response.

  Failures:

  - `:bad_response` — shape is wrong, or `new_cursor < cursor`.
  - `:cursor_mismatch` — response was for a different cursor.
  - `:nonce_mismatch` — response was for a different request nonce.
  - `:unauthorized` — HMAC does not match.
  - `:stale_response` — timestamp is outside the skew window.
  """
  @spec verify_response(term(), non_neg_integer(), binary()) ::
          {:ok, [Locker.WAL.Entry.t()], non_neg_integer(), non_neg_integer()}
          | {:error, response_error()}
  def verify_response(resp, expected_cursor, expected_nonce)
      when is_integer(expected_cursor) and is_binary(expected_nonce) do
    with {:ok, fields} <- validate_response_shape(resp),
         %{cursor: c, new_cursor: nc, peer_tip: pt, entries: entries, nonce: n, timestamp_ms: ts} =
           fields,
         :ok <- check_cursor_match(c, expected_cursor),
         :ok <- check_nonce_match(n, expected_nonce),
         :ok <- check_response_hmac(resp),
         :ok <- check_freshness(ts, :stale_response),
         :ok <- check_peer_tip(nc, pt) do
      {:ok, entries, nc, pt}
    end
  end

  def verify_response(_, _, _), do: {:error, :bad_response}

  defp validate_response_shape(
         %{
           cursor: c,
           new_cursor: nc,
           peer_tip: pt,
           entries: entries,
           nonce: n,
           timestamp_ms: ts,
           hmac: h
         } = resp
       )
       when is_integer(c) and c >= 0 and is_integer(nc) and nc >= c and is_integer(pt) and
              pt >= 0 and is_list(entries) and is_binary(n) and byte_size(n) == @nonce_bytes and
              is_integer(ts) and ts >= 0 and is_binary(h) do
    {:ok, resp}
  end

  defp validate_response_shape(_), do: {:error, :bad_response}

  defp check_cursor_match(c, expected) when c == expected, do: :ok
  defp check_cursor_match(_, _), do: {:error, :cursor_mismatch}

  defp check_nonce_match(n, expected) when is_binary(n) and is_binary(expected) do
    if Plug.Crypto.secure_compare(n, expected), do: :ok, else: {:error, :nonce_mismatch}
  end

  defp check_nonce_match(_, _), do: {:error, :nonce_mismatch}

  defp check_peer_tip(nc, pt) when pt >= nc, do: :ok
  defp check_peer_tip(_, _), do: {:error, :bad_response}

  defp check_response_hmac(%{hmac: h} = resp) do
    if Plug.Crypto.secure_compare(h, response_hmac(resp, secret())) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp check_freshness(ts, stale_error) do
    if within_skew?(ts), do: :ok, else: {:error, stale_error}
  end

  # --- Internal ---

  defp request_hmac(cursor, ts, nonce, secret) do
    msg = <<"perpwalk-options-replication-request-v1:", cursor::64, ts::64, nonce::binary>>
    :crypto.mac(:hmac, :sha256, secret, msg)
  end

  # `:erlang.term_to_binary/1` is not canonical: without the
  # `:deterministic` flag, maps with atom keys can be encoded in
  # arbitrary order, and an RPC serialize/deserialize roundtrip is
  # enough to flip the bytes for a logically identical term — even
  # on the same OTP version. Caller and responder would then
  # disagree on the entries digest and the caller rejects the
  # response with `:unauthorized`. `[:deterministic]` (OTP 26+)
  # locks the encoding so digests match across nodes and roundtrips.
  defp response_hmac(
         %{
           cursor: cursor,
           new_cursor: new_cursor,
           peer_tip: peer_tip,
           timestamp_ms: ts,
           nonce: nonce,
           entries: entries
         },
         secret
       ) do
    entries_digest = :crypto.hash(:sha256, :erlang.term_to_binary(entries, [:deterministic]))

    msg =
      <<"perpwalk-options-replication-response-v1:", cursor::64, new_cursor::64, peer_tip::64, ts::64, nonce::binary,
        entries_digest::binary>>

    :crypto.mac(:hmac, :sha256, secret, msg)
  end

  defp within_skew?(ts) do
    abs(System.system_time(:millisecond) - ts) <= @clock_skew_ms
  end
end
