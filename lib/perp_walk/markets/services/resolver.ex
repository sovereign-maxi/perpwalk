defmodule PerpWalk.Markets.Services.Resolver do
  @moduledoc """
  Owns every market lifecycle transition past creation.

  | Command              | From        | To         | Atomic with positions? |
  |----------------------|-------------|------------|------------------------|
  | `activate/1`         | `:pending`  | `:active`  | no                     |
  | `expire/1`           | `:active`   | `:expired` | no                     |
  | `submit_resolution/2`| `:expired`  | `:resolving` (with outcome) | no |
  | `reverse_resolution/2`| `:resolving` | `:resolving` (new outcome) | no |
  | `settle/1`           | `:resolving`| `:settled` | yes — every position   |
  | `void/1`             | `:expired` or `:resolving` | `:voided` | yes — every position |

  `settle/1` and `void/1` write the market and every position on it
  via `Store.put_resolution/2` — a single WAL append, all-or-nothing.
  Winners credited and losers consumed in one operation; if
  settlement bookkeeping fails after odds resolution the system MUST
  halt rather than partially apply.

  No payout movement happens here — positions are stamped with their
  terminal status (`:settled_winner` / `:settled_loser` / `:refunded`)
  and the actual XMR transfer is the Monero domain's job.
  """

  require Logger

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Guards
  alias PerpWalk.Markets.{Dispute, Market, Moderation, Position, Store}

  # --- Lifecycle (single-aggregate transitions) ---

  @doc "Transitions a `:pending` market to `:active`."
  @spec activate(binary()) :: {:ok, Market.t()} | {:error, atom()}
  def activate(market_id) when is_binary(market_id) do
    Guards.ensure_operational!()

    transition_market(market_id, &Market.activate/1, fn updated ->
      EventBus.publish(%MarketsEvents.MarketActivated{
        market_id: updated.id,
        timestamp: DateTime.utc_now()
      })
    end)
  end

  @doc "Transitions an `:active` market to `:expired` (betting closed)."
  @spec expire(binary()) :: {:ok, Market.t()} | {:error, atom()}
  def expire(market_id) when is_binary(market_id) do
    Guards.ensure_operational!()

    transition_market(market_id, &Market.expire/1, fn updated ->
      EventBus.publish(%MarketsEvents.MarketExpired{
        market_id: updated.id,
        timestamp: DateTime.utc_now()
      })
    end)
  end

  @doc """
  Transitions an `:expired` market to `:resolving` with the proposed
  outcome. **No auth check** — for the operator-override path
  (Console) and tests. The public/web path goes through
  `submit_resolution_by_creator/3` which verifies the caller is the
  market creator.

  Opens the dispute window — settlement happens via `settle/1`
  after the window closes.
  """
  @spec submit_resolution(binary(), Market.outcome()) ::
          {:ok, Market.t()} | {:error, atom()}
  def submit_resolution(market_id, outcome)
      when is_binary(market_id) and outcome in [:yes, :no, :void] do
    Guards.ensure_operational!()

    transition_market(
      market_id,
      &Market.submit_resolution(&1, outcome),
      fn updated ->
        EventBus.publish(%MarketsEvents.ResolutionSubmitted{
          market_id: updated.id,
          outcome: outcome,
          timestamp: DateTime.utc_now()
        })
      end
    )
  end

  @doc """
  Creator-driven resolution. Verifies `account_id` is the market
  creator before transitioning. This is the public path used by
  the web UI; the operator-override path uses `submit_resolution/2`
  directly.

  Outcomes are constrained to `:yes | :no` — the `:void` outcome is
  deliberately operator-only. A creator who genuinely can't resolve
  should let the resolution deadline lapse, at which point the
  Scheduler auto-voids with `reason: :creator_no_show`. Forcing
  creators to pick a side means a deliberately-wrong resolution can
  be community-disputed; voiding to dodge disputes would be a free
  escape hatch and is closed off here.

  Returns `{:error, :not_creator}` if the caller is not the
  creator, `{:error, :invalid_outcome_for_creator}` if `outcome`
  is `:void`, otherwise delegates to `submit_resolution/2`.
  """
  @spec submit_resolution_by_creator(binary(), binary(), :yes | :no) ::
          {:ok, Market.t()} | {:error, atom()}
  def submit_resolution_by_creator(account_id, market_id, outcome)
      when is_binary(account_id) and is_binary(market_id) and
             outcome in [:yes, :no, :void] do
    Guards.ensure_operational!()

    with :ok <- ensure_non_void(outcome),
         {:ok, market} <- fetch_market(market_id),
         :ok <- ensure_creator(market, account_id) do
      submit_resolution(market_id, outcome)
    end
  end

  defp ensure_non_void(:void), do: {:error, :invalid_outcome_for_creator}
  defp ensure_non_void(_), do: :ok

  defp ensure_creator(market, account_id) do
    if Market.creator?(market, account_id),
      do: :ok,
      else: {:error, :not_creator}
  end

  @doc """
  Reverses a `:resolving` market's outcome while still inside the
  dispute window. Stays in `:resolving` — only the outcome changes.
  Implicitly acknowledges all currently-flagged disputes: reversing
  IS the review action.
  """
  @spec reverse_resolution(binary(), Market.outcome()) ::
          {:ok, Market.t()} | {:error, atom()}
  def reverse_resolution(market_id, new_outcome)
      when is_binary(market_id) and new_outcome in [:yes, :no, :void] do
    Guards.ensure_operational!()

    with {:ok, market} <- fetch_market(market_id),
         previous = market.outcome,
         {:ok, reversed} <- Market.reverse_resolution(market, new_outcome) do
      # Capture the live count BEFORE resolving so the watermark
      # reflects "how many live disputes guardians reviewed."
      dispute_count = Store.live_dispute_count(market.id)

      # Reversal means guardians sided with disputers — full
      # refund, no slash. Transition each live dispute in-memory
      # to its terminal status without writing yet.
      resolved_disputes = transition_live_disputes(market.id, :resolved_against)

      acknowledged = Market.acknowledge_disputes(reversed, dispute_count)

      # `live_dispute_count` in the CAS catches the race where a
      # `:awaiting_deposit → :live` transition lands (via the direct
      # `Store.put_dispute/1` path) between the read above and this
      # write. Without it, the new dispute would be invisible to
      # `transition_live_disputes/2`, commit alongside the resolution,
      # and stay `:live` forever — the disputer's stake stuck because
      # `Cashier.ensure_refundable` requires `:resolved_*`.
      expected = %{
        status: market.status,
        outcome: market.outcome,
        live_dispute_count: dispute_count
      }

      # Single atomic write — market state change + every dispute
      # transition commits as one WAL entry. No partial state, and
      # WAL back-pressure surfaces as `{:error, :wal_overloaded}`
      # rather than crashing this process.
      case Store.put_resolution_cas(acknowledged, [], resolved_disputes, expected) do
        :ok ->
          now = DateTime.utc_now()

          publish_dispute_resolutions(resolved_disputes, now)

          EventBus.publish(%MarketsEvents.ResolutionReversed{
            market_id: acknowledged.id,
            previous_outcome: previous,
            new_outcome: new_outcome,
            timestamp: now
          })

          maybe_publish_acknowledgement(acknowledged, market, dispute_count, now)

          {:ok, acknowledged}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Records that the guardian federation has reviewed the disputes and
  is confirming the existing resolution (no reversal). Sets the
  market's `disputes_acknowledged_count` high-water mark so
  `settle/1` is permitted; fresh disputes filed afterward must again
  cross the threshold to re-block settlement.
  """
  @spec acknowledge_disputes(binary()) :: {:ok, Market.t()} | {:error, atom()}
  def acknowledge_disputes(market_id) when is_binary(market_id) do
    Guards.ensure_operational!()

    with {:ok, market} <- fetch_market(market_id),
         :ok <- ensure_resolving(market) do
      # Capture the live count BEFORE resolving so the watermark
      # reflects "how many live disputes guardians reviewed."
      dispute_count = Store.live_dispute_count(market.id)

      # Acknowledgement = guardians sided with the creator. Each
      # live disputer is on the losing side and gets a partial
      # refund (slash applied per `Moderation.dispute_slash_pct/0`).
      # Transition each live dispute in-memory; the actual Store
      # write happens atomically below.
      resolved_disputes = transition_live_disputes(market.id, :resolved_for)

      acknowledged = Market.acknowledge_disputes(market, dispute_count)

      # `live_dispute_count` in the CAS catches the race where a
      # `:awaiting_deposit → :live` transition lands between the
      # read above and this write — without it the new dispute
      # would commit alongside the acknowledgement and stay
      # `:live` forever, leaving the disputer unable to claim.
      expected = %{
        status: market.status,
        outcome: market.outcome,
        live_dispute_count: dispute_count
      }

      # Single atomic write — market state change + every dispute
      # transition commits as one WAL entry.
      case Store.put_resolution_cas(acknowledged, [], resolved_disputes, expected) do
        :ok ->
          now = DateTime.utc_now()
          publish_dispute_resolutions(resolved_disputes, now)
          maybe_publish_acknowledgement(acknowledged, market, dispute_count, now)
          {:ok, acknowledged}

        {:error, _} = err ->
          err
      end
    end
  end

  # --- Terminal Transitions (atomic with all positions) ---

  @doc """
  Settles a `:resolving` market: every open position is stamped
  `:settled_winner` or `:settled_loser` based on `side` vs the
  recorded outcome, and the market itself moves to `:settled`. One
  atomic WAL append covers the whole thing.

  Refuses with `{:error, :unacknowledged_disputes}` if the unack'd
  dispute count is past the moderation threshold — the guardian
  federation must call `acknowledge_disputes/1` (or
  `reverse_resolution/2`, which acknowledges implicitly) first.
  """
  @spec settle(binary()) :: {:ok, Market.t()} | {:error, atom()}
  def settle(market_id) when is_binary(market_id) do
    Guards.ensure_operational!()

    with {:ok, market} <- fetch_market(market_id),
         :ok <- ensure_dispute_window_elapsed(market),
         live_dispute_count = Store.live_dispute_count(market.id),
         :ok <- ensure_disputes_reviewed(market, live_dispute_count),
         {:ok, settled_market} <- Market.settle(market),
         {:ok, settled_positions} <- settle_open_positions(market.id, settled_market.outcome) do
      # Sub-threshold live disputes were on the losing side of the
      # creator's resolution — settle treats them like an implicit
      # acknowledge_disputes: each transitions to :resolved_for so the
      # disputer can claim their partial-slash refund. Without this,
      # disputers with stakes below the moderation threshold are
      # permanently stuck in :live (no other Resolver path gates on
      # :settled markets) and their XMR is unreachable.
      resolved_disputes = transition_live_disputes(market.id, :resolved_for)

      # CAS guard — fail if the live market changed since we read it.
      # Catches:
      # - reverse-race: reverse_resolution flips outcome while settle
      #   is computing winners against the stale one.
      # - dispute-race: a fresh dispute confirms past threshold between
      #   ensure_disputes_reviewed and the WAL append. Disputes write
      #   to a :public ETS table and don't serialise through this
      #   GenServer, so the count snapshot is part of the CAS and
      #   re-checked inside the handler under the serial write lock.
      expected = %{
        status: market.status,
        outcome: market.outcome,
        disputes_acknowledged_count: market.disputes_acknowledged_count,
        live_dispute_count: live_dispute_count
      }

      case Store.put_resolution_cas(settled_market, settled_positions, resolved_disputes, expected) do
        :ok ->
          now = DateTime.utc_now()
          publish_dispute_resolutions(resolved_disputes, now)

          EventBus.publish(%MarketsEvents.MarketSettled{
            market_id: settled_market.id,
            outcome: settled_market.outcome,
            resolved_at: settled_market.resolved_at,
            timestamp: now
          })

          {:ok, settled_market}

        {:error, :concurrent_modification} ->
          {:error, :concurrent_modification}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Voids a market from `:expired` or `:resolving`: every open position
  is refunded, the market moves to `:voided` with `outcome: :void`,
  and a `PositionCancelled` event is published per refunded position
  alongside the `MarketVoided` event.

  `reason` distinguishes operator-initiated voids from scheduler
  auto-voids — see `MarketsEvents.MarketVoided`. Defaults to
  `:operator` so existing callers (Console, Facade, iex) get the
  expected event.
  """
  @spec void(binary(), MarketsEvents.MarketVoided.reason()) ::
          {:ok, Market.t()} | {:error, atom()}
  def void(market_id, reason \\ :operator)
      when is_binary(market_id) and
             reason in [:operator, :creator_no_show, :guardian_undecidable] do
    Guards.ensure_operational!()

    with {:ok, market} <- fetch_market(market_id),
         {:ok, voided_market} <- Market.void(market),
         {:ok, refunded_positions} <- refund_open_positions(market.id) do
      # If we're voiding from `:resolving`, any live disputers
      # were correct that the original resolution wasn't right —
      # void implies "undecidable," not "creator was right."
      # Resolve them with full refund. Transition in-memory; the
      # actual writes commit atomically below alongside market +
      # positions.
      voiding_from_resolving? = market.status == :resolving

      dispute_count =
        if voiding_from_resolving?, do: Store.live_dispute_count(market.id), else: 0

      resolved_disputes =
        if voiding_from_resolving? do
          transition_live_disputes(market.id, :resolved_against)
        else
          []
        end

      # CAS guard against concurrent settle/reverse races. When
      # voiding from `:resolving`, also pin `live_dispute_count`
      # so a `:awaiting_deposit → :live` transition that lands
      # between the read above and this write forces a retry —
      # otherwise the new dispute would stay `:live` after void
      # and the disputer's stake would be stuck (refund requires
      # a `:resolved_*` terminal status).
      expected =
        if voiding_from_resolving? do
          %{
            status: market.status,
            outcome: market.outcome,
            live_dispute_count: dispute_count
          }
        else
          %{status: market.status, outcome: market.outcome}
        end

      case Store.put_resolution_cas(voided_market, refunded_positions, resolved_disputes, expected) do
        :ok ->
          now = DateTime.utc_now()

          EventBus.publish(%MarketsEvents.MarketVoided{
            market_id: voided_market.id,
            resolved_at: voided_market.resolved_at,
            reason: reason,
            timestamp: now
          })

          Enum.each(refunded_positions, fn pos ->
            EventBus.publish(%MarketsEvents.PositionCancelled{
              position_id: pos.id,
              market_id: voided_market.id,
              amount_refunded: pos.amount_paid,
              timestamp: now
            })
          end)

          # Publish DisputeResolved events for any disputes that were
          # resolved as part of voiding from `:resolving`. Events fire
          # after the atomic write commits.
          publish_dispute_resolutions(resolved_disputes, now)

          {:ok, voided_market}

        {:error, :concurrent_modification} ->
          {:error, :concurrent_modification}

        {:error, store_reason} ->
          {:error, store_reason}
      end
    end
  end

  # --- Time-Driven Auto-Transitions ---

  @doc """
  Single entry point for time-driven state transitions. Walks every
  non-terminal market status and applies whatever transition is
  eligible given `now` and the configured windows.

  Eligibility logic lives here, in the same module as the transitions
  themselves, so callers can't accidentally encode a precondition
  that disagrees with what `settle/1` or `void/2` will actually
  accept.

  Required opts:
  - `:pending_window_seconds` — listing-vote window
  - `:dispute_window_seconds` — post-resolution dispute window
  - `:auto_void_grace_seconds` — extra grace after the dispute window
    before a stuck `:resolving` market is voided as
    `:guardian_undecidable`, AND grace after `resolution_deadline`
    before an unsubmitted `:expired` market voids as `:creator_no_show`
  """
  @spec tick(DateTime.t(), keyword()) :: :ok
  def tick(%DateTime{} = now, opts) when is_list(opts) do
    Guards.ensure_operational!()

    pending_window = Keyword.fetch!(opts, :pending_window_seconds)
    dispute_window = Keyword.fetch!(opts, :dispute_window_seconds)
    grace = Keyword.fetch!(opts, :auto_void_grace_seconds)

    tick_pending(now, pending_window)
    tick_active(now)
    tick_resolving(now, dispute_window, grace)
    tick_expired(now, grace)

    :ok
  end

  defp tick_pending(now, pending_window) do
    for m <- safe_list_by_status(:pending),
        DateTime.diff(now, pending_anchor(m), :second) >= pending_window do
      case activate(m.id) do
        {:ok, _} ->
          Logger.info("Resolver: tick activated market_id=#{m.id}")

        {:error, reason} ->
          Logger.warning("Resolver: tick activate failed market_id=#{m.id} reason=#{inspect(reason)}")
      end
    end
  end

  # The listing-vote window runs from deposit confirmation, not
  # creation — otherwise a creator who funds a day late gets
  # :pending → :active in a single tick and the community downvote
  # window never engages.
  defp pending_anchor(%Market{} = m), do: m.deposit_confirmed_at || m.created_at

  defp tick_active(now) do
    for m <- safe_list_by_status(:active),
        DateTime.compare(now, m.expiry) != :lt do
      case expire(m.id) do
        {:ok, _} ->
          Logger.info("Resolver: tick expired market_id=#{m.id}")

        {:error, reason} ->
          Logger.warning("Resolver: tick expire failed market_id=#{m.id} reason=#{inspect(reason)}")
      end
    end
  end

  # `:resolving` flow: the creator has acted, so the relevant clock
  # is `resolution_submitted_at`, not `resolution_deadline`. After
  # the dispute window elapses, attempt settle — `settle/1` owns the
  # dispute-threshold decision and processes sub-threshold live
  # disputes via implicit acknowledge. Only fall through to void if
  # settle refuses with `:unacknowledged_disputes` AND the grace
  # window beyond the dispute window has also elapsed.
  defp tick_resolving(now, dispute_window, grace) do
    for m <- safe_list_by_status(:resolving),
        not is_nil(m.resolution_submitted_at) do
      settle_cutoff = DateTime.add(m.resolution_submitted_at, dispute_window, :second)

      if DateTime.compare(now, settle_cutoff) == :lt do
        # Still inside the dispute window — nothing to do this tick.
        :skip
      else
        attempt_settle_or_void(m, now, settle_cutoff, grace)
      end
    end
  end

  defp attempt_settle_or_void(market, now, settle_cutoff, grace) do
    if market.outcome == :void do
      # The operator resolved this market as undecidable — void it
      # (refunds for every position) once the dispute window has
      # elapsed. settle/1 refuses :void outcomes by design: settling
      # one would brick every position in :open forever.
      case void(market.id, :guardian_undecidable) do
        {:ok, _} ->
          Logger.warning("Resolver: tick voided :void-outcome market, market_id=#{market.id}")

        {:error, reason} ->
          Logger.warning("Resolver: tick void failed market_id=#{market.id} reason=#{inspect(reason)}")
      end
    else
      case settle(market.id) do
        {:ok, _} ->
          Logger.info(
            "Resolver: tick auto-settled market_id=#{market.id} " <>
              "outcome=#{market.outcome} dispute_window=#{DateTime.diff(now, settle_cutoff, :second) + 0}s_past"
          )

        {:error, :unacknowledged_disputes} ->
          maybe_void_after_grace(market, now, settle_cutoff, grace)

        {:error, reason} ->
          Logger.warning("Resolver: tick settle failed market_id=#{market.id} reason=#{inspect(reason)}")
      end
    end
  end

  # Settle refused on dispute review. Void only once the grace window
  # beyond the dispute window has also elapsed — inside the grace the
  # operator still has room to acknowledge and settle cleanly.
  defp maybe_void_after_grace(market, now, settle_cutoff, grace) do
    void_cutoff = DateTime.add(settle_cutoff, grace, :second)

    if DateTime.compare(now, void_cutoff) != :lt do
      case void(market.id, :guardian_undecidable) do
        {:ok, _} ->
          Logger.warning("Resolver: tick auto-voided, market_id=#{market.id}, reason=:guardian_undecidable")

        {:error, reason} ->
          Logger.warning("Resolver: tick void failed market_id=#{market.id} reason=#{inspect(reason)}")
      end
    end
  end

  defp tick_expired(now, grace) do
    overdue_cutoff = DateTime.add(now, -grace, :second)

    for m <- safe_list_by_status(:expired),
        DateTime.compare(m.resolution_deadline, overdue_cutoff) != :gt do
      case void(m.id, :creator_no_show) do
        {:ok, _} ->
          Logger.warning("Resolver: tick auto-voided, market_id=#{m.id}, reason=:creator_no_show")

        {:error, reason} ->
          Logger.warning("Resolver: tick void failed market_id=#{m.id} reason=#{inspect(reason)}")
      end
    end
  end

  defp safe_list_by_status(status) do
    Store.list_markets_by_status(status)
  rescue
    e ->
      Logger.warning("Resolver: list_markets_by_status failed status=#{status} reason=#{inspect(e)}")
      []
  catch
    _, _ -> []
  end

  # --- Internal ---

  defp fetch_market(market_id) do
    case Store.get_market(market_id) do
      {:ok, market} -> {:ok, market}
      {:error, :not_found} -> {:error, :market_not_found}
    end
  end

  defp ensure_resolving(%Market{status: :resolving}), do: :ok
  defp ensure_resolving(_market), do: {:error, :market_not_resolving}

  # Checks whether `:live` disputes still block settle. Acknowledge
  # / reverse / void all auto-resolve any live disputes to a terminal
  # state, so live count drops to 0 after a review. Fresh disputes
  # filed afterwards re-block settle if they cross the scaled
  # threshold (population-aware — see `Moderation.scaled_threshold/1`
  # for the floor + ratio semantics).
  # Enforces the dispute window inside `settle/1` itself, not just in
  # the Scheduler's tick loop. Without this gate an operator running
  # `Resolver.settle(market_id)` from iex a minute after resolution
  # submission bypasses the entire dispute window disputers were
  # promised — collapsing the counterweight to creator-resolution
  # self-dealing (the creator's LP return is outcome-sensitive by
  # design; the dispute window is the only observable check between
  # resolution submission and slash-refund window closure).
  #
  # Refuses with `{:error, :dispute_window_open}` when
  # `now - resolution_submitted_at < dispute_window_seconds`. Reads
  # the window from `:perpwalk, :markets_scheduler` — same source
  # the Scheduler consults — so tests and prod agree.
  defp ensure_dispute_window_elapsed(%Market{
         status: :resolving,
         resolution_submitted_at: submitted_at
       })
       when not is_nil(submitted_at) do
    now = DateTime.utc_now()

    window =
      Application.get_env(:perpwalk, :markets_scheduler, [])
      |> Keyword.get(:dispute_window_seconds, 86_400)

    if DateTime.diff(now, submitted_at, :second) >= window do
      :ok
    else
      {:error, :dispute_window_open}
    end
  end

  # No resolution submitted yet, or market not in :resolving. Downstream
  # `Market.settle/1` will reject with its own error; short-circuit the
  # gate to :ok so we return the more specific error.
  defp ensure_dispute_window_elapsed(_market), do: :ok

  defp ensure_disputes_reviewed(%Market{} = market, live_count) do
    position_holders = Store.count_distinct_position_holders(market.id)

    if Moderation.dispute_review_required?(live_count, position_holders) do
      {:error, :unacknowledged_disputes}
    else
      :ok
    end
  end

  defp maybe_publish_acknowledgement(acknowledged, previous, dispute_count, now)
       when acknowledged.disputes_acknowledged_count != previous.disputes_acknowledged_count do
    EventBus.publish(%MarketsEvents.DisputesAcknowledged{
      market_id: acknowledged.id,
      acknowledged_count: dispute_count,
      timestamp: now
    })
  end

  defp maybe_publish_acknowledgement(_a, _p, _c, _n), do: :ok

  defp transition_market(market_id, transition_fn, after_persist) do
    with {:ok, market} <- fetch_market(market_id),
         {:ok, updated} <- transition_fn.(market),
         :ok <- Store.put_market_cas(updated, %{status: market.status}) do
      after_persist.(updated)
      {:ok, updated}
    end
  end

  # Money-path invariant: if settlement bookkeeping fails after odds
  # resolution the system MUST halt rather than partially apply. We
  # return `{:error, _}` from the batch helper so the calling `with`
  # chain refuses the transition before any partial WAL write.
  defp settle_open_positions(market_id, outcome) when outcome in [:yes, :no] do
    market_id
    |> Store.list_positions_for_market()
    |> Enum.filter(&(&1.status == :open))
    |> Enum.reduce_while({:ok, []}, fn pos, {:ok, acc} ->
      case Position.settle(pos, outcome) do
        {:ok, settled} -> {:cont, {:ok, [settled | acc]}}
        {:error, reason} -> {:halt, {:error, {:settle_failed, pos.id, reason}}}
      end
    end)
  end

  # `:void` outcome shouldn't reach `settle/1` — Market.settle/1
  # accepts any outcome but a :void outcome should have gone through
  # `void/1`. Defensive default returns an empty list (no settle work).
  defp settle_open_positions(_market_id, _outcome), do: {:ok, []}

  defp refund_open_positions(market_id) do
    market_id
    |> Store.list_positions_for_market()
    |> Enum.filter(&(&1.status == :open))
    |> Enum.reduce_while({:ok, []}, fn pos, {:ok, acc} ->
      case Position.refund(pos) do
        {:ok, refunded} -> {:cont, {:ok, [refunded | acc]}}
        {:error, reason} -> {:halt, {:error, {:refund_failed, pos.id, reason}}}
      end
    end)
  end

  # Transitions every `:live` dispute on the market to its terminal
  # state in-memory. `terminal` is one of `:resolved_for` (guardians
  # sided with creator → slash) or `:resolved_against` (guardians
  # sided with disputers → full refund).
  #
  # No Store writes happen here — the caller batches these transitions
  # into a single atomic `Store.put_disputes_resolved_cas/3` write so
  # the dispute resolutions and the market state change commit as one
  # WAL entry. Events fire only after the atomic write succeeds, via
  # `publish_dispute_resolutions/2`.
  defp transition_live_disputes(market_id, terminal)
       when terminal in [:resolved_for, :resolved_against] do
    market_id
    |> Store.list_disputes_for_market()
    |> Enum.filter(&Dispute.live?/1)
    |> Enum.map(fn dispute ->
      {:ok, resolved} = transition_dispute(dispute, terminal)
      resolved
    end)
  end

  defp publish_dispute_resolutions(disputes, %DateTime{} = now) do
    Enum.each(disputes, fn %Dispute{} = resolved ->
      EventBus.publish(%MarketsEvents.DisputeResolved{
        market_id: resolved.market_id,
        account_id: resolved.account_id,
        status: resolved.status,
        refund_amount_piconeros: Dispute.refund_amount_piconeros(resolved),
        slashed_amount_piconeros: resolved.slashed_amount_piconeros,
        timestamp: now
      })
    end)
  end

  defp transition_dispute(%Dispute{} = d, :resolved_for) do
    slash = Moderation.slash_amount(d.stake_amount_piconeros)
    Dispute.resolve_for(d, slash)
  end

  defp transition_dispute(%Dispute{} = d, :resolved_against) do
    Dispute.resolve_against(d)
  end
end
