defmodule PerpWalk.Nostr.Frame do
  @moduledoc """
  Pure NIP-01 wire frame parsing and building.

  NIP-01 messages are JSON arrays with a string tag at index 0. This
  module decodes the relay→client variants we actually care about
  (`EVENT`, `EOSE`, `NOTICE`, `CLOSED`, `OK`) into typed structs, and
  builds the client→relay variants (`REQ`, `CLOSE`) we send. Anything
  unexpected is returned as `{:unknown, raw}` so the subscriber can
  log and ignore rather than crash.

  Pure module — no IO, no state.
  """

  @type subscription_id :: String.t()
  @type relay_message ::
          {:event, subscription_id(), map()}
          | {:eose, subscription_id()}
          | {:notice, String.t()}
          | {:closed, subscription_id(), String.t()}
          | {:ok, String.t(), boolean(), String.t()}
          | {:unknown, term()}
          | {:error, atom()}

  @doc """
  Parses one relay→client frame text.

  Returns a tagged tuple matching the message variant, or
  `{:error, :bad_frame}` if the JSON doesn't decode or doesn't match
  NIP-01 shape, `{:unknown, raw}` if it's a recognized JSON array
  but not a variant we handle.
  """
  @spec parse(binary()) :: relay_message()
  def parse(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, ["EVENT", sub_id, %{} = event]} when is_binary(sub_id) ->
        {:event, sub_id, event}

      {:ok, ["EOSE", sub_id]} when is_binary(sub_id) ->
        {:eose, sub_id}

      {:ok, ["NOTICE", notice]} when is_binary(notice) ->
        {:notice, notice}

      {:ok, ["CLOSED", sub_id, reason]} when is_binary(sub_id) and is_binary(reason) ->
        {:closed, sub_id, reason}

      {:ok, ["OK", event_id, accepted, reason]}
      when is_binary(event_id) and is_boolean(accepted) and is_binary(reason) ->
        {:ok, event_id, accepted, reason}

      {:ok, raw} ->
        {:unknown, raw}

      {:error, _} ->
        {:error, :bad_frame}
    end
  end

  def parse(_), do: {:error, :bad_frame}

  @doc """
  Builds a client→relay `REQ` frame for the given subscription id
  and filter map. Returns the JSON text ready to push over the
  WebSocket.
  """
  @spec build_req(subscription_id(), map()) :: binary()
  def build_req(sub_id, %{} = filter) when is_binary(sub_id) do
    Jason.encode!(["REQ", sub_id, filter])
  end

  @doc "Builds a client→relay `CLOSE` frame for the given subscription id."
  @spec build_close(subscription_id()) :: binary()
  def build_close(sub_id) when is_binary(sub_id) do
    Jason.encode!(["CLOSE", sub_id])
  end
end
