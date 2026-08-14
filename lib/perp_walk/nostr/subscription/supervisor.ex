defmodule PerpWalk.Nostr.Subscription.Supervisor do
  @moduledoc """
  Supervises one `PerpWalk.Nostr.Relay.Subscriber` per configured
  Nostr relay.

  Relays are read from `Application.get_env(:perpwalk, :nostr_relays)`.
  When the configured list is empty (the dev / sim default), this
  supervisor starts with no children — the application boots
  cleanly without an active inbound subscription, and the Inbox
  is reachable only via `Inbox.ingest/1` direct calls (tests).

  ## Children

  Each Subscriber is identified in the supervisor by the tuple
  `{Subscriber, relay_url}`. Use `subscriber_pid/1` to look up the
  live pid by relay url for operator iex queries.
  """

  use Supervisor

  alias PerpWalk.Nostr.Relay.Subscriber

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    relays = Application.get_env(:perpwalk, :nostr_relays, [])

    children =
      Enum.map(relays, fn relay_url ->
        Supervisor.child_spec(
          {Subscriber, [relay_url: relay_url]},
          id: {Subscriber, relay_url}
        )
      end)

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end

  @doc """
  Returns the live pid for the Subscriber managing `relay_url`, or
  `nil` if no such child is running. Useful for operator iex —
  `Subscriber.status(SubscriptionSupervisor.subscriber_pid(url))`.
  """
  @spec subscriber_pid(String.t()) :: pid() | nil
  def subscriber_pid(relay_url) when is_binary(relay_url) do
    __MODULE__
    |> Supervisor.which_children()
    |> Enum.find_value(nil, fn
      {{Subscriber, ^relay_url}, pid, _type, _modules} when is_pid(pid) -> pid
      _ -> nil
    end)
  end
end
