defmodule PerpWalkWeb.Live.RateLimit do
  @moduledoc """
  Per-socket per-event rate limiter for LiveView handlers.

  Phoenix LiveView's `phx-throttle` attribute is client-side and
  ignorable — a malicious client can simply drop the throttle and
  spam events as fast as the WebSocket allows. Server-side checks
  on expensive handlers (anything that allocates a wallet
  subaddress, queues a payout, opens a dispute) are required.

  Each kind gets a token bucket of `:max` calls per `:window_ms`,
  tracked in the LiveView process dictionary so it's per-socket and
  vanishes when the socket closes. Lock-free under the GenServer's
  serial event loop. Default thresholds aim at a power user — fast
  enough that a real human never trips them, slow enough that a
  scripted abuser hits them within a second.

  ## Usage

      def handle_event("trade:open", params, socket) do
        case PerpWalkWeb.Live.RateLimit.check(:trade_open) do
          :ok ->
            do_trade_open(params, socket)

          {:error, :rate_limited} ->
            {:noreply, put_flash(socket, :error, PerpWalkWeb.Messages.rate_limited(:trade))}
        end
      end
  """

  @default_window_ms 1_000

  @defaults %{
    # Subaddress allocation, durable Quote write — the hot path.
    trade_open: {10, @default_window_ms},
    # Quote submission — same shape as trade_open, kept distinct so
    # operators can tune them independently if abuse patterns differ.
    quote_submit: {10, @default_window_ms},
    # Dispute filing requires its own subaddress + WAL entry. Lower
    # cap because legitimate dispute filing is rare per-user.
    dispute_open: {3, @default_window_ms * 5},
    # Claim flow — no money movement on `:open` (just modal state)
    # but the `:submit` enqueues a payout. Cap both.
    claim_open: {30, @default_window_ms},
    claim_submit: {5, @default_window_ms * 5},
    dispute_claim_open: {30, @default_window_ms},
    dispute_claim_submit: {5, @default_window_ms * 5},
    # Listing vote — Voter dedupes by (account_id, market_id) so
    # only the first vote per account/market sticks; cap exists to
    # bound wasted Store.put_vote calls under spam.
    vote: {10, @default_window_ms},
    # Creator resolution submission — Resolver state machine
    # rejects all but the first transition; cap covers a creator
    # hammering the submit button while waiting on a slow round-trip.
    resolve_submit: {5, @default_window_ms * 5},
    # Comment submission — Schnorr-sign + Inbox.ingest + fan-out to
    # configured relays. Cap covers stuck-Tor spam attempts; the
    # Composer's content cap + Inbox dedup are the other guards.
    comment_submit: {5, @default_window_ms * 5},
    # Comment drafts fire per keystroke. Generous ceiling — a fast
    # human peaks around 10/sec; this only trips on scripted floods.
    comment_draft: {120, @default_window_ms}
  }

  @doc """
  Checks the bucket for `kind`. On success the call is recorded and
  `:ok` is returned. On exhaustion returns `{:error, :rate_limited}`.

  Configurable via:

      config :perpwalk, PerpWalkWeb.Live.RateLimit,
        trade_open: {20, 1_000}
  """
  @spec check(atom()) :: :ok | {:error, :rate_limited}
  def check(kind) when is_atom(kind) do
    {max, window_ms} = limits_for(kind)
    now = System.monotonic_time(:millisecond)
    key = {:lrl, kind}
    bucket = Process.get(key, [])
    fresh = Enum.filter(bucket, fn ts -> now - ts < window_ms end)

    if length(fresh) >= max do
      :telemetry.execute(
        [:perp_walk_web, :live, :rate_limited],
        %{count: 1},
        %{kind: kind}
      )

      {:error, :rate_limited}
    else
      Process.put(key, [now | fresh])
      :ok
    end
  end

  defp limits_for(kind) do
    overrides =
      :perpwalk
      |> Application.get_env(__MODULE__, [])
      |> Map.new()

    Map.get(overrides, kind) || Map.get(@defaults, kind) || {30, @default_window_ms}
  end
end
