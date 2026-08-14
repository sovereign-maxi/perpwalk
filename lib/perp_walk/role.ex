defmodule PerpWalk.Role do
  @moduledoc """
  Local node identity and write-eligibility within the federation.

  PERP WALK runs as a 2-of-3 FROST federation with three hot nodes
  (N1, N2, N3) Erlang-clustered on dedicated bare metal across
  three independent providers. The architecture is *deliberately*
  not an HA cluster:

  - **Service tier (N1)** — drives user-traffic side effects that
    must not double-fire: Monero deposit-credit processing, payout
    signing-loop. Only N1 polls confirmations into ledger writes,
    only N1 advances the federation's payout state machine.
  - **Custody tier (N1, N2, N3)** — every guardian holds a FROST
    share and counter-signs when its share is requested. Any 2-of-3
    quorum can complete a signing round. Custody integrity is the
    invariant that survives if any single guardian dies.

  The system optimises for *custody integrity*, not *availability*.
  An N1 outage halts new traffic processing until N1 returns or
  the operator promotes N2 / N3 by flipping `:participant_id` — it
  does NOT silently fail over. This is the right tradeoff for a
  privacy venue: the failure mode is "stop accepting writes" rather
  than "two nodes race to credit the same deposit twice."

  At the Storage layer, all three nodes write freely to their local
  WAL with `(origin, seq)` composite keys; the Replicator pulls
  each peer's `:origin == peer_id` entries past the per-peer cursor
  and applies them locally, so each node's WAL converges to the
  union of all origins' entries.

  ## Single-node development

  Defaults to `participant_id: :p1` (a benign default — service +
  custody on one box). Tests and dev can override `:participant_id`
  via config to simulate any of the three hot nodes.

  ## Shape

  The participant atom is `:"<prefix><index>"` where `<prefix>` is
  the env letter (`n` prod / `s` staging) and `<index>` is the
  federation position (1/2/3). Runtime config derives this from
  `NODE_LABEL`. Staging and prod atoms never collide, so a WAL
  entry's `:origin` is legible at a glance.
  """

  @type participant_id :: :p1 | :p2 | :p3 | :s1 | :s2 | :s3

  @valid_participant_ids [:p1, :p2, :p3, :s1, :s2, :s3]

  # Default designated set. Nodes at index 1 are the service-tier
  # processor in every federation (prod and staging alike). Can be
  # overridden at runtime via `Federation.Console.promote_processor/1`
  # so a failed N1 can be temporarily failed over to N2 or N3 without
  # a redeploy — the override lands as a WAL-recorded
  # `:processor_promotion` entry replicated to every guardian, so all
  # nodes converge on the same set (pre-fix: RPC-broadcast app-env
  # writes tolerated partial application, producing two "processors"
  # each driving fills and signing cluster-wide → double-payout).
  # See `designated_processor?/0`.
  @default_designated_processors [:p1, :s1]

  @doc "The full set of valid participant ids across prod + staging."
  @spec valid_participants() :: [participant_id()]
  def valid_participants, do: @valid_participant_ids

  @doc """
  This BEAM node's federation participant id from config.

  Used as the per-node seq-space identifier for the WAL and as the
  identity sticker on every entry this node writes. Bi-directional
  replication uses this to attribute entries to their author.
  """
  @spec participant_id() :: participant_id()
  def participant_id do
    case Application.get_env(:perpwalk, :participant_id, :p1) do
      id when id in @valid_participant_ids -> id
      other -> raise ArgumentError, "invalid :participant_id config: #{inspect(other)}"
    end
  end

  @doc """
  The currently-designated set. Consults, in order:

    1. WAL-backed `:persistent_term` promotion record (set by
       `Federation.Store.persist_processor_promotion/4`; replicated
       to every guardian via `apply_wal_entry(:processor_promotion,
       ...)`). Present iff an operator has issued at least one
       runtime promotion.
    2. `Application.get_env(:perpwalk, :designated_processors, ...)`
       — the inventory default, seeded at boot from config.

  The WAL-backed record is the single cluster-consistent source of
  truth for runtime overrides. Reading straight from app env (the
  pre-fix path) tolerated partial `:rpc.call` propagation: an
  operator promoting `:p2` while any peer's RPC failed left the
  failed peer thinking `:p1` is still the processor while the
  accepted peers thought `:p2` was — two "processors" both driving
  cluster-state writes, both signing payouts, both filling deposits.

  A node restart no longer reverts the override: the WAL replay
  restores the last `:processor_promotion` entry into
  `:persistent_term` before `Role.designated_processors/0` is
  consulted for the first payout.
  """
  @spec designated_processors() :: [participant_id()]
  def designated_processors do
    case promotion_lookup() do
      {set, _epoch} when is_list(set) and set != [] ->
        set

      _ ->
        Application.get_env(:perpwalk, :designated_processors, @default_designated_processors)
    end
  end

  # Indirect via a runtime lookup so `PerpWalk.Role` doesn't compile-time
  # depend on `PerpWalk.Federation.Store` (bootstrap ordering: Role is
  # read during config validation on `Application.start/2` before
  # Federation.Supervisor's children start). `:persistent_term.get/2`
  # returns the default when the store hasn't booted yet.
  defp promotion_lookup do
    :persistent_term.get({PerpWalk.Federation.Store, :promotion}, :none)
  end

  @doc """
  True when local stores will accept write operations.

  In the symmetric bi-directional model every hot node always
  accepts writes when the local BEAM is healthy. The federation
  health check (peer reachability, signing quorum) lives in
  `PerpWalk.Federation.Facade.healthy?/0` and gates outflow
  signing, not local write acceptance — the WAL replicator handles
  catch-up after a peer outage transparently.
  """
  @spec writes_allowed?() :: boolean()
  def writes_allowed?, do: true

  @doc """
  True when this node is the *service-tier processor* for
  cluster-state writes that must NOT double-fire across the
  federation:

    - Monero deposit-credit processing (every guardian observes
      the chain for reorg detection, but only N1 writes the ledger
      mutation; the other two guardians receive the result via
      bi-directional WAL replication).
    - Payout signing-loop drive (only N1 advances the queue; N2 +
      N3 counter-sign when their FROST shares are requested).

  This is the *service tier* of the service-tier-vs-custody-tier
  split documented in the module-level moduledoc. N1 is the
  service-tier node by design; if N1 is down, the operator can
  promote N2 or N3 at runtime via `Federation.Console.promote_processor/1`
  without a redeploy. Custody (the FROST shares) lives on all three
  nodes regardless.
  """
  @spec designated_processor?() :: boolean()
  def designated_processor?, do: participant_id() in designated_processors()
end
