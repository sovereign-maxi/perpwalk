defmodule PerpWalk.Markets.Supervisor do
  @moduledoc false

  use Supervisor

  alias PerpWalk.Markets.Comments
  alias PerpWalk.Markets.Publishers
  alias PerpWalk.Markets.{Scheduler, Store}

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [Store, Scheduler, Publishers.Nostr, Comments.Inbox]

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end
end
