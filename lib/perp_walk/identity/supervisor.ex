defmodule PerpWalk.Identity.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec healthy?() :: boolean()
  def healthy? do
    __MODULE__
    |> Supervisor.which_children()
    |> Enum.all?(fn {_id, pid, _type, _modules} ->
      is_pid(pid) and Process.alive?(pid)
    end)
  end

  @impl true
  def init(_init_arg) do
    identity_cfg = Application.get_env(:perpwalk, :identity, [])

    children = [
      PerpWalk.Identity.Sessions,
      Seer.NonceStore,
      {Seer.RateLimiter,
       [
         # Every operation classified by PerpWalk.Identity.Gate.classify_operation/1
         # MUST have an entry here — unknown operations fall through to {:ok, conn}
         # in the gate, which would silently let them bypass rate limiting.
         limits: %{
           # Auth — sensitive, brute-force resistance
           auth_login: {5, 300},
           auth_generate: {3, 600},
           auth_logout: {30, 60},
           # Page loads / read-mostly
           info: {100, 60},
           # LiveView WebSocket connect — one per session
           live_connect: {30, 60}
         }
       ]},
      {Seer.Difficulty,
       [
         min_difficulty: Keyword.get(identity_cfg, :pow_min_difficulty, 12),
         max_difficulty: Keyword.get(identity_cfg, :pow_max_difficulty, 28)
       ]},
      {Seer.Escalation, []}
    ]

    # Budget raised from 3/10. Identity.Sessions's `init/1` replays
    # the WAL which is multi-second on a long-lived production WAL;
    # any Seer-* child crash during that window risks tripping the
    # tighter budget and cascading into the root tree.
    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 10, max_seconds: 60)
  end
end
