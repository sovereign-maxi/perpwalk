defmodule PerpWalk.Sim.Invariants.Replication do
  @moduledoc """
  Verifies leader-follower convergence: after applying any WAL
  slice from the leader, the follower converges to identical
  state.

  Single-node sim runs (the default) don't have a follower in
  the supervision tree, so this invariant is structurally a
  no-op — `Role.follower?/0` returns false and there's no
  `Storage.Replicator` running. `check/0` returns `:ok`.

  When sim graduates to a multi-node mode (a separate scenario
  that boots a follower BEAM), this module is where the
  convergence comparison lands. The shape will be:

      leader_state = Markets.Store.snapshot()
      follower_state = :rpc.call(follower_node, Markets.Store, :snapshot, [])
      compare(leader_state, follower_state)

  Stub for now so the validator's invariant list stays
  consistent across single-node and future multi-node runs.
  """

  @spec check(map()) :: :ok | {:violation, map()}
  def check(_snapshot), do: :ok
end
