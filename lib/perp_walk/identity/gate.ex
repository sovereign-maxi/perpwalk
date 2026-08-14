defmodule PerpWalk.Identity.Gate do
  @moduledoc """
  Plug that acts as the central access control gate in the Phoenix
  request pipeline.

  Chains together circuit ID extraction (via `Seer.Circuit.Extractor`),
  operation classification, and Tor-circuit-scoped rate limit checking
  (via `Seer.RateLimiter`). PoW gating is wired through but defaults
  off for the LiveView-heavy paths — perpwalk's hot path is browser
  page loads + WebSocket events, not REST endpoints.

  Pipeline order:
    1. Extract circuit ID hash
    2. Classify operation by request method + path segments
    3. Check rate limit
    4. (Future) Require PoW if the configured difficulty is elevated
    5. Pass through

  ## Why not IP rate limiting?

  The whole venue is a Tor hidden service. Every external request
  arrives on `127.0.0.1` from the application's point of view; there
  is no real client IP. The Tor source port (per ephemeral circuit) is
  the per-circuit surrogate Seer extracts.

  ## Options

  - `:enabled` — whether the gate is active (default: true)
  - `:exempt_paths` — list of `{method, path}` tuples exempt from all
    checks. Health endpoints, static assets, the LiveView socket, etc.
  """

  @behaviour Plug

  import Plug.Conn

  alias Seer.{Challenge, Difficulty, Escalation, RateLimiter}
  alias Seer.Circuit.Extractor, as: CircuitExtractor

  @enabled Application.compile_env(:perpwalk, [:identity, :request_gate_enabled], true)

  @default_exempt_paths [
    {"GET", "/health"},
    {"GET", "/health/live"},
    {"GET", "/health/ready"}
  ]

  # --- Plug Callbacks ---

  @impl true
  def init(opts) do
    %{
      enabled: Keyword.get(opts, :enabled, @enabled),
      exempt_paths: Keyword.get(opts, :exempt_paths, @default_exempt_paths)
    }
  end

  @impl true
  def call(conn, %{enabled: false}) do
    # When disabled, assign a deterministic test circuit ID so any
    # downstream code that reads it has a stable value.
    test_circuit_id = :crypto.hash(:sha256, "test-circuit")

    conn
    |> assign(:circuit_id_hash, test_circuit_id)
    |> assign(:operation, classify_operation(conn))
  end

  def call(conn, opts) do
    with {:ok, conn} <- extract_circuit(conn),
         {:ok, conn} <- classify_and_assign(conn, opts),
         {:ok, conn} <- apply_security_checks(conn) do
      conn
    else
      {:halt, conn} -> conn
    end
  end

  defp apply_security_checks(%{assigns: %{exempt: true}} = conn), do: {:ok, conn}

  defp apply_security_checks(conn) do
    check_rate_limit(conn)
  end

  # --- Private Functions ---

  defp extract_circuit(conn) do
    {:ok, circuit_id_hash} = CircuitExtractor.extract(conn)
    {:ok, assign(conn, :circuit_id_hash, circuit_id_hash)}
  end

  defp classify_and_assign(conn, opts) do
    operation = classify_operation(conn)
    conn = assign(conn, :operation, operation)

    if exempt?(conn, opts) do
      {:ok, assign(conn, :exempt, true)}
    else
      {:ok, conn}
    end
  end

  defp check_rate_limit(conn) do
    operation = conn.assigns[:operation]
    circuit_id_hash = conn.assigns[:circuit_id_hash]

    case RateLimiter.check(circuit_id_hash, operation) do
      :ok ->
        {:ok, conn}

      {:error, {:unknown_operation, op}} ->
        # Fail closed: a `classify_operation/1` return value not
        # configured in the supervisor's RateLimiter limits would
        # otherwise bypass the gate silently. Log + 429 surfaces the
        # misconfiguration before it ships and forces the operator
        # to either add the limit or remove the classification.
        require Logger
        Logger.warning("Gate: unknown operation rejected, operation=#{inspect(op)}, request_path=#{conn.request_path}")

        send_429(conn)

      {:error, :rate_limited} ->
        # Optional PoW bypass: if the client provided a valid solution,
        # let the request through despite the rate limit.
        case Challenge.extract_solution(conn) do
          {:ok, nonce, solution} ->
            verify_pow_solution(conn, nonce, solution, circuit_id_hash)

          {:error, :missing_solution} ->
            send_429(conn)
        end

      {:error, :unavailable} ->
        # Limiter mid-restart — fail closed with 503 and surface the
        # condition through the telemetry pipeline.
        :telemetry.execute([:perpwalk, :identity, :rate_limiter_unavailable], %{count: 1}, %{})
        send_503(conn)
    end
  end

  defp verify_pow_solution(conn, nonce, solution, circuit_id_hash) do
    # Difficulty is deliberately not passed in: Seer.Challenge.verify/2
    # reads the difficulty the nonce was ISSUED with from the nonce
    # record, so verification can never be weakened by the caller.
    case Challenge.verify(nonce, solution) do
      :ok ->
        Difficulty.record_request()
        {:ok, assign(conn, :pow_verified, true)}

      {:error, reason} ->
        # Record the failed bypass attempt against the originating
        # circuit so Seer.Escalation can raise the bar (or ban the
        # circuit) on sustained probing rather than letting an
        # attacker burn server CPU verifying junk solutions at the
        # plain 403 rate.
        Escalation.record(circuit_id_hash)

        send_403(conn, reason)
    end
  end

  defp send_429(conn) do
    conn =
      conn
      |> put_resp_header("retry-after", "60")
      |> put_resp_content_type("text/plain")
      |> send_resp(429, "Too many requests. Try again later.")
      |> halt()

    {:halt, conn}
  end

  defp send_503(conn) do
    conn =
      conn
      |> put_resp_header("retry-after", "5")
      |> put_resp_content_type("text/plain")
      |> send_resp(503, "Service temporarily unavailable.")
      |> halt()

    {:halt, conn}
  end

  defp send_403(conn, reason) do
    conn =
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "Forbidden: #{reason}")
      |> halt()

    {:halt, conn}
  end

  defp exempt?(conn, %{exempt_paths: exempt_paths}) do
    Enum.any?(exempt_paths, fn {method, path} ->
      conn.method == method and path_matches?(conn.request_path, path)
    end)
  end

  defp path_matches?(request_path, exempt_path) do
    request_path == exempt_path or
      String.starts_with?(request_path, exempt_path <> "/")
  end

  @doc false
  def classify_operation(conn) do
    case {conn.method, path_segments(conn.request_path)} do
      {"POST", ["auth", "login" | _]} -> :auth_login
      {"POST", ["auth", "generate" | _]} -> :auth_generate
      {"POST", ["auth", "logout" | _]} -> :auth_logout
      {"GET", ["live" | _]} -> :live_connect
      {"GET", _} -> :info
      # Anything POST that's not classified above is treated as
      # auth-sensitive to avoid bypass via unknown routes.
      {"POST", _} -> :auth_login
      _ -> :info
    end
  end

  defp path_segments(path) do
    path |> String.split("/", trim: true)
  end
end
