defmodule PerpWalk.Nostr.Relay.Subscriber do
  @moduledoc """
  Persistent WebSocket subscriber for one Nostr relay.

  Maintains a long-lived connection to the configured relay (routed
  through the Tor HTTP CONNECT tunnel, same as
  `PerpWalk.Nostr.Relay.Client`), sends an NIP-01 `REQ` for the
  perpwalk-market-comment topic on connect, and pipes verified
  events into `PerpWalk.Markets.Comments.Inbox` — which appends
  each to the venue's own WAL before insert. Nostr is the transport
  that brings comments in from outside; the WAL is the source of
  truth for what the venue has seen. A relay dropping or evicting
  an old event has no effect on comments already in the WAL.

  ## Reconnect

  On any disconnect or network error the Subscriber schedules a
  reconnect with simple linear backoff capped at 60 seconds. The
  `reconnect_attempts` counter resets on a successful connect.

  ## Verification

  Every received `EVENT` frame is verified through
  `PerpWalk.Nostr.Event.verify/1` (canonical id derivation + BIP-340
  Schnorr signature check) before extraction. Failed verifications
  are logged at info — relays sometimes echo events from clients
  with malformed payloads, and we just drop them rather than
  letting one bad event poison the subscription.

  ## Venue pubkey

  The `a` tag on a comment references a market under the venue's
  Nostr key. We need that pubkey to confirm the comment is referring
  to one of OUR markets and not a forgery under some other key. The
  pubkey is loaded lazily on the first relevant frame from
  `Reserves.Publishers.Nostr` (which owns the venue identity at boot
  via its load-or-generate-key path). Lazy load avoids a race
  against the application supervisor's startup order.
  """

  use GenServer

  require Logger

  alias PerpWalk.Markets.Facade, as: MarketsFacade
  alias PerpWalk.Nostr.{Event, Frame, Venue}

  @connect_timeout_ms 10_000

  # Linear backoff in seconds. Each failed connect bumps the index by
  # one; index is clamped to the last entry so steady-state retries
  # happen once a minute.
  @reconnect_schedule_s [1, 2, 5, 10, 30, 60]

  # The single topic we care about — kind:1 notes carrying the
  # perpwalk-market-comment tag. The relay filter narrows the
  # event stream at the relay's end so we don't pay for general
  # public-feed traffic.
  @subscription_filter %{
    "kinds" => [1],
    "#t" => ["perpwalk-market-comment"]
  }

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Test seam — injects a raw NIP-01 frame text as if it had arrived
  from the relay's WebSocket. Production code never calls this; the
  WebSocket receive loop is the only legitimate driver.

  Returns the parsed/routed result so tests can assert on the
  outcome without snooping on the inbox.
  """
  @spec inject_frame(GenServer.server(), binary()) :: term()
  def inject_frame(server, text) when is_binary(text) do
    GenServer.call(server, {:inject_frame, text})
  end

  @doc """
  Returns a snapshot of the current connection state — useful for
  operator iex and for tests that need to confirm the Subscriber
  reached a particular phase.
  """
  @spec status(GenServer.server()) :: %{
          relay_url: String.t(),
          connected: boolean(),
          subscription_id: String.t(),
          reconnect_attempts: non_neg_integer()
        }
  def status(server) do
    GenServer.call(server, :status)
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    state = %{
      relay_url: Keyword.fetch!(opts, :relay_url),
      auto_connect: Keyword.get(opts, :auto_connect, true),
      conn: nil,
      websocket: nil,
      ref: nil,
      subscription_id: generate_subscription_id(),
      reconnect_attempts: 0,
      venue_pubkey_hex: nil
    }

    if state.auto_connect do
      {:ok, state, {:continue, :connect}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:connect, state) do
    {:noreply, attempt_connect(state)}
  end

  @impl true
  def handle_call({:inject_frame, text}, _from, state) do
    {result, new_state} = handle_relay_text(text, state)
    {:reply, result, new_state}
  end

  def handle_call(:status, _from, state) do
    snapshot = %{
      relay_url: state.relay_url,
      connected: state.conn != nil,
      subscription_id: state.subscription_id,
      reconnect_attempts: state.reconnect_attempts
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, attempt_connect(state)}
  end

  def handle_info(_message, %{conn: nil} = state) do
    {:noreply, state}
  end

  def handle_info(message, state) do
    case stream_message(state, message) do
      {:cont, new_state} ->
        {:noreply, new_state}

      {:reconnect, new_state} ->
        {:noreply, schedule_reconnect(new_state)}

      :ignore ->
        {:noreply, state}
    end
  end

  # --- Connection ---

  defp attempt_connect(%{relay_url: url} = state) do
    case do_connect_and_subscribe(url, state.subscription_id) do
      {:ok, conn, websocket, ref} ->
        Logger.info("Subscriber: connected, relay=#{url}, sub_id=#{state.subscription_id}")
        %{state | conn: conn, websocket: websocket, ref: ref, reconnect_attempts: 0}

      {:error, reason} ->
        Logger.warning("Subscriber: connect failed, relay=#{url}, reason=#{inspect(reason)}")
        schedule_reconnect(state)
    end
  end

  # Dialyzer can't see through Mint.WebSocket's opaque return types
  # across the with-chain — same false positives the Relay.Client
  # already suppresses.
  @dialyzer {:nowarn_function,
             [
               attempt_connect: 1,
               do_connect_and_subscribe: 2,
               ws_upgrade: 2,
               await_upgrade_response: 2,
               finalize_upgrade: 3,
               send_req_frame: 4,
               stream_message: 2,
               process_responses: 2,
               handle_data: 3
             ]}

  defp do_connect_and_subscribe(url, sub_id) do
    with {:ok, uri} <- parse_relay_url(url),
         {:ok, conn} <- http_connect(uri),
         {:ok, conn, ref} <- ws_upgrade(conn, uri),
         {:ok, conn, websocket} <- await_upgrade_response(conn, ref),
         {:ok, conn, websocket} <- send_req_frame(conn, websocket, ref, sub_id) do
      {:ok, conn, websocket, ref}
    end
  catch
    kind, reason -> {:error, {:caught, kind, reason}}
  end

  defp parse_relay_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when scheme in ["ws", "wss"] and is_binary(host) ->
        port = uri.port || if(scheme == "wss", do: 443, else: 80)
        path = uri.path || "/"
        {:ok, %{scheme: String.to_existing_atom(scheme), host: host, port: port, path: path}}

      _ ->
        {:error, {:invalid_relay_url, url}}
    end
  end

  defp http_connect(%{scheme: :wss, host: host, port: port}) do
    Mint.HTTP.connect(:https, host, port, build_connect_opts())
  end

  defp http_connect(%{scheme: :ws, host: host, port: port}) do
    Mint.HTTP.connect(:http, host, port, build_connect_opts())
  end

  defp build_connect_opts do
    base = [
      transport_opts: [
        timeout: @connect_timeout_ms,
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3
      ],
      protocols: [:http1]
    ]

    case Application.get_env(:perpwalk, :tor_http_tunnel) do
      nil ->
        base

      {host, port} when is_binary(host) and is_integer(port) ->
        Keyword.put(base, :proxy, {:http, host, port, []})
    end
  end

  defp ws_upgrade(conn, %{scheme: scheme, path: path}) do
    Mint.WebSocket.upgrade(scheme, conn, path, [])
  end

  defp await_upgrade_response(conn, ref) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} -> finalize_upgrade(conn, ref, responses)
          {:error, _conn, reason, _responses} -> {:error, {:upgrade_stream, reason}}
        end
    after
      @connect_timeout_ms -> {:error, :upgrade_timeout}
    end
  end

  defp finalize_upgrade(conn, ref, responses) do
    status =
      Enum.find_value(responses, fn
        {:status, ^ref, s} -> s
        _ -> nil
      end)

    headers =
      Enum.find_value(responses, fn
        {:headers, ^ref, h} -> h
        _ -> nil
      end)

    done? = Enum.any?(responses, &match?({:done, ^ref}, &1))

    if is_nil(status) or is_nil(headers) or not done? do
      await_upgrade_response(conn, ref)
    else
      case Mint.WebSocket.new(conn, ref, status, headers) do
        {:ok, conn, websocket} -> {:ok, conn, websocket}
        {:error, _conn, reason} -> {:error, {:ws_new_failed, reason}}
      end
    end
  end

  defp send_req_frame(conn, websocket, ref, sub_id) do
    payload = Frame.build_req(sub_id, @subscription_filter)

    with {:ok, websocket, data} <- Mint.WebSocket.encode(websocket, {:text, payload}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      {:ok, conn, websocket}
    else
      {:error, _conn, reason} -> {:error, {:send_req_failed, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Streaming Reads ---

  defp stream_message(state, message) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        new_state = %{state | conn: conn}
        process_responses(responses, new_state)

      {:error, conn, reason, _responses} ->
        Logger.warning("Subscriber: WS stream error, relay=#{state.relay_url}, reason=#{inspect(reason)}")

        _ = Mint.HTTP.close(conn)
        {:reconnect, %{state | conn: nil, websocket: nil, ref: nil}}

      :unknown ->
        :ignore
    end
  end

  defp process_responses([], state), do: {:cont, state}

  defp process_responses([{:data, _ref, data} | rest], state) do
    case handle_data(state, data, &handle_relay_text(&1, &2)) do
      {:cont, new_state} -> process_responses(rest, new_state)
      {:reconnect, _} = stop -> stop
    end
  end

  defp process_responses([{:done, _ref} | _rest], state) do
    Logger.info("Subscriber: relay closed connection, relay=#{state.relay_url}")
    _ = state.conn && Mint.HTTP.close(state.conn)
    {:reconnect, %{state | conn: nil, websocket: nil, ref: nil}}
  end

  defp process_responses([_other | rest], state), do: process_responses(rest, state)

  defp handle_data(state, data, text_handler) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        new_state = %{state | websocket: websocket}
        consume_frames(frames, new_state, text_handler)

      {:error, _websocket, reason} ->
        Logger.warning("Subscriber: WS decode error, relay=#{state.relay_url}, reason=#{inspect(reason)}")

        {:reconnect, %{state | conn: nil, websocket: nil, ref: nil}}
    end
  end

  defp consume_frames([], state, _handler), do: {:cont, state}

  defp consume_frames([{:text, text} | rest], state, handler) do
    case handler.(text, state) do
      {{:reconnect, _why}, new_state} ->
        _ = new_state.conn && Mint.HTTP.close(new_state.conn)
        {:reconnect, %{new_state | conn: nil, websocket: nil, ref: nil}}

      {_result, new_state} ->
        consume_frames(rest, new_state, handler)
    end
  end

  defp consume_frames([{:close, _code, _reason} | _rest], state, _handler) do
    Logger.info("Subscriber: WS close frame received, relay=#{state.relay_url}")
    _ = state.conn && Mint.HTTP.close(state.conn)
    {:reconnect, %{state | conn: nil, websocket: nil, ref: nil}}
  end

  defp consume_frames([_other | rest], state, handler), do: consume_frames(rest, state, handler)

  # --- Frame Routing (shared by live and injected paths) ---

  defp handle_relay_text(text, state) do
    case Frame.parse(text) do
      {:event, _sub_id, raw_event} ->
        handle_event(raw_event, state)

      {:eose, _sub_id} ->
        Logger.debug("Subscriber: end of stored events, relay=#{state.relay_url}")
        {:ok, state}

      {:notice, notice} ->
        Logger.info("Subscriber: notice received, relay=#{state.relay_url}, notice=#{inspect(notice)}")
        {:ok, state}

      {:closed, sub_id, reason} ->
        # The relay terminated this subscription but kept the socket
        # open — comments silently stop flowing while the connection
        # still looks healthy. Reconnect; the connect path re-sends
        # the REQ frame.
        Logger.warning(
          "Subscriber: subscription closed by relay, " <>
            "sub_id=#{sub_id}, reason=#{reason}, relay=#{state.relay_url} — reconnecting"
        )

        {{:reconnect, {:closed, sub_id, reason}}, state}

      {:ok, _event_id, _accepted, _reason} ->
        # OK frames apply to publisher flows, not subscribers. Ignore.
        {:ok, state}

      {:unknown, _raw} ->
        {:ok, state}

      {:error, :bad_frame} ->
        Logger.info("Subscriber: discarded malformed frame, relay=#{state.relay_url}")
        {{:error, :bad_frame}, state}
    end
  end

  defp handle_event(raw_event, state) do
    {pubkey_hex, state} = ensure_venue_pubkey(state)

    with hex when is_binary(hex) <- pubkey_hex,
         {:ok, verified} <- Event.verify(raw_event),
         {:ok, attrs} <- Event.comment_attributes(verified, hex) do
      case MarketsFacade.ingest_comment(attrs) do
        {:ok, _} ->
          {:ingested, state}

        {:error, reason} ->
          # A poison event must not crash the subscriber: the strict
          # match this replaces took the process down, the supervisor
          # reconnected, and the relay re-delivered the same event —
          # an infinite crash loop on one bad frame.
          Logger.warning("Subscriber: comment ingest failed, reason=#{inspect(reason)}")
          {:rejected, state}
      end
    else
      nil ->
        Logger.debug("Subscriber: venue pubkey not yet available; skipping event")
        {:skipped, state}

      {:error, reason} ->
        Logger.debug("Subscriber: dropping event, reason=#{inspect(reason)}")
        {:rejected, state}
    end
  end

  defp ensure_venue_pubkey(%{venue_pubkey_hex: hex} = state) when is_binary(hex),
    do: {hex, state}

  defp ensure_venue_pubkey(%{venue_pubkey_hex: nil} = state) do
    case Venue.Identity.pubkey() do
      {:ok, hex} -> {hex, %{state | venue_pubkey_hex: hex}}
      {:error, _} -> {nil, state}
    end
  rescue
    _ -> {nil, state}
  catch
    :exit, _ -> {nil, state}
  end

  # --- Reconnect ---

  defp schedule_reconnect(state) do
    next_attempt = state.reconnect_attempts + 1
    delay_s = backoff_seconds(next_attempt)

    Logger.info(
      "Subscriber: scheduling reconnect, relay=#{state.relay_url}, " <>
        "attempt=#{next_attempt}, delay_s=#{delay_s}"
    )

    Process.send_after(self(), :reconnect, delay_s * 1_000)
    %{state | reconnect_attempts: next_attempt}
  end

  defp backoff_seconds(attempt) when attempt > 0 do
    idx = min(attempt - 1, length(@reconnect_schedule_s) - 1)
    Enum.at(@reconnect_schedule_s, idx)
  end

  # --- Misc ---

  defp generate_subscription_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
