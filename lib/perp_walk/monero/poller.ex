defmodule PerpWalk.Monero.Poller do
  @moduledoc """
  Bridges on-chain Monero deposits to Markets quote fills.

  Wraps `Darks.Poller` — receives lifecycle callbacks for deposits
  hitting the wallet, looks up the matching pending Quote by
  subaddress index, and (once the deposit reaches the confirmation
  threshold and the amount is sufficient) calls
  `Trader.fill_quote/2` to consume the Quote into a Position.

  ## Lifecycle

      lookup_subaddress(subaddr_index) → {:ok, quote_id}
        Caller is Darks.Poller. We scan pending quotes for a match
        and return the quote id as the `ref` that Darks will pass
        through to subsequent callbacks.

      on_deposit → record the amount we observed for this txid
        We need the amount at on_confirmed time but Darks.Poller
        only exposes it at on_deposit time, so we cache it here.

      on_confirmed → if amount ≥ quote.amount_paid_piconeros, fill.
        Underpaid deposits record an Orphan and auto-enqueue a
        refund payout to the Quote's `refund_address` via
        `Federation.Facade.enqueue_quote_underpayment_refund/5`;
        the Store's uniqueness scope keeps the enqueue idempotent
        against re-fires.

  Each callback fires inside an unlinked Task in Darks.Poller so we
  never block its poll loop.
  """

  use GenServer

  require Logger

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Federation.Facade, as: FederationFacade
  alias PerpWalk.Markets.Facade, as: MarketsFacade
  alias PerpWalk.Monero.Orphans
  alias PerpWalk.Role

  # Monero's wallet convention: outputs become "unlocked" (spendable)
  # after 10 confirmations. Crediting a deposit as filled after only
  # a handful of confirmations opens a deep-reorg attack: an attacker
  # can double-spend a deposit that got 2 confirmations, trade the
  # resulting position immediately, then a chain reorganisation drops
  # the deposit while the position still stands and any payouts
  # already signed are real XMR against phantom collateral. Matching
  # the wallet's own 10-conf lock is the tightest reasonable floor.
  @default_confirmations 10
  @default_poll_interval_ms 15_000

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Resolves a Monero subaddress index to an attribution tuple that
  identifies what the deposit is for. Used as the
  `lookup_subaddress` callback for `Darks.Poller` — the returned
  ref is opaque to Darks but pattern-matched on confirm.

  Lookups hit O(1) secondary indexes (`Markets.Store.get_quote_by_subaddress/1`
  and friends), not full-table scans. Looks across:

  - pending quotes (`:quote`) — any non-expired Quote
  - awaiting-deposit disputes (`:dispute`) — any Dispute that's
    still in `:awaiting_deposit`
  - awaiting-deposit markets (`:market_deposit`) — any Market
    that's still in `:awaiting_deposit` for its creation deposit

  Subaddress index 0 is the wallet's primary address by Monero
  convention; never an allocated user-facing subaddress. Reject it
  before any lookup so a deposit to the primary (e.g. bootstrap
  migration) can never be misrouted to a user resource that
  somehow has index 0 stored.

  For any non-zero index that doesn't match a live resource (e.g.
  the user paid into a subaddress whose Quote has since expired),
  returns `{:ok, {:orphan, index}}` so the deposit is observable
  in the Orphans store rather than dropped silently by Darks.
  """
  @spec lookup_subaddress(non_neg_integer()) ::
          {:ok,
           {:quote, binary()}
           | {:dispute, binary(), binary()}
           | {:market_deposit, binary()}
           | {:orphan, non_neg_integer()}}
          | :not_found
  def lookup_subaddress(0), do: :not_found

  def lookup_subaddress(subaddr_index) when is_integer(subaddr_index) and subaddr_index > 0 do
    now = DateTime.utc_now()

    cond do
      match = find_quote(subaddr_index, now) ->
        match

      match = find_pending_dispute(subaddr_index) ->
        match

      match = find_pending_market(subaddr_index) ->
        match

      true ->
        # No live resource owns this subaddress. Surface the deposit
        # as an orphan so the operator sees the entry in Orphans
        # rather than the funds landing silently in the wallet.
        {:ok, {:orphan, subaddr_index}}
    end
  end

  defp find_quote(subaddr_index, now) do
    case MarketsFacade.get_quote_by_subaddress(subaddr_index) do
      {:ok, quote} ->
        if MarketsFacade.quote_expired?(quote, now), do: nil, else: {:ok, {:quote, quote.id}}

      {:error, :not_found} ->
        nil
    end
  end

  defp find_pending_dispute(subaddr_index) do
    case MarketsFacade.get_dispute_by_subaddress(subaddr_index) do
      {:ok, %{status: :awaiting_deposit} = d} -> {:ok, {:dispute, d.account_id, d.market_id}}
      _ -> nil
    end
  end

  defp find_pending_market(subaddr_index) do
    case MarketsFacade.get_market_by_subaddress(subaddr_index) do
      {:ok, %{status: :awaiting_deposit, id: id}} -> {:ok, {:market_deposit, id}}
      _ -> nil
    end
  end

  # --- GenServer ---

  # Cap on the in-flight deposit observation map. A patient attacker
  # who can force wallet rescans (DoS monerod → operator restart loop)
  # would otherwise grow `txid_amounts` without bound. Once the cap is
  # hit, the oldest pending observation is dropped — confirmation for
  # the dropped txid would log "no recorded amount" and skip, which
  # is the existing safe path for unknown txids.
  #
  # Sized well above realistic legitimate-pending counts. The
  # `Trader.create_quote/5` free-quote surface is throttled to ~50 per
  # 300s per circuit; even sustained maximum trader traffic won't
  # populate anywhere near this cap in a 30-min quote-lifetime
  # window. Raised from the prior 10_000 to give the operator a
  # generous margin against a dust-quote spam wave evicting
  # legitimate observations before they confirm. Follow-up: TTL-based
  # eviction (drop entries older than the quote lifetime) would cap
  # attacker traffic by wall-clock instead of count.
  @max_in_flight_observations 100_000

  # Cap on the recently-seen-confirmed set. We retain confirmed txids
  # so a re-fired :confirmed event (eviction in Darks.Poller, wallet
  # rescan, monerod bug) is detected and skipped rather than
  # double-processed. 50_000 is well above any realistic eviction
  # window.
  @max_recently_confirmed 50_000

  @impl true
  def init(opts) do
    path = persistence_path(opts)
    {recently_confirmed, recently_confirmed_order} = load_recently_confirmed(path)

    state = %{
      txid_amounts: %{},
      txid_order: :queue.new(),
      recently_confirmed: recently_confirmed,
      recently_confirmed_order: recently_confirmed_order,
      persistence_path: path
    }

    if Keyword.get(opts, :start_darks, true) do
      start_darks_poller(opts)
    end

    {:ok, state}
  end

  @impl true
  def handle_info({:deposit, %{txid: txid, ref: ref, amount: amount}}, state) do
    Logger.info("Poller: deposit observed, txid=#{txid}, ref=#{inspect(ref)}, amount=#{amount}")

    {amounts, order} =
      bounded_put(state.txid_amounts, state.txid_order, txid, amount, @max_in_flight_observations)

    publish_deposit_observed(ref, txid, amount)

    {:noreply, %{state | txid_amounts: amounts, txid_order: order}}
  end

  def handle_info({:confirmed, %{txid: txid, ref: ref, confirmations: confs}}, state) do
    if Map.has_key?(state.recently_confirmed, txid) do
      Logger.debug("Poller: re-fired :confirmed for already-processed txid=#{txid}")
      {:noreply, state}
    else
      handle_fresh_confirmed(state, txid, ref, confs)
    end
  end

  def handle_info({:reorg, %{txid: txid, ref: ref} = payload}, state) do
    # A previously-detected deposit's confirmation count dropped.
    # We can't safely advance any state on the back of an
    # uncertain deposit; halt auto-signing globally so the operator
    # has a chance to triage before any payout for an affected
    # position lands on-chain. Halt is local to this guardian —
    # the other guardians stay up, but no quorum can be reached
    # without this one's signature, which is the desired posture.
    Logger.error("Poller: reorg detected, txid=#{txid}, ref=#{inspect(ref)}, payload=#{inspect(payload)}")

    FederationFacade.halt_signing()
    FederationFacade.record_audit(:monero_reorg, %{txid: txid, ref: inspect(ref)})

    {:noreply, state}
  end

  def handle_info({:unconfirmed, %{txid: txid, ref: ref} = payload}, state) do
    # `:unconfirmed` only fires for deposits that previously crossed
    # the confirmation threshold — i.e. we already filled / confirmed
    # something against this deposit. The chain has now reorged it
    # away. Halt is the only safe response; manual reconciliation
    # follows.
    Logger.error(
      "Poller: previously-confirmed deposit dropped below threshold, txid=#{txid}, ref=#{inspect(ref)}, payload=#{inspect(payload)}"
    )

    FederationFacade.halt_signing()
    FederationFacade.record_audit(:monero_unconfirmed, %{txid: txid, ref: inspect(ref)})

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_fresh_confirmed(state, txid, ref, confs) do
    case Map.fetch(state.txid_amounts, txid) do
      {:ok, amount} ->
        # Quote fills, dispute confirmations, and orphan recording are
        # cluster-state writes that must NOT double-fire across nodes.
        # Every node observes the deposit locally (Darks needs the view
        # for reorg detection) but only the designated processor writes
        # the ledger mutation; the other node receives the result via
        # bi-directional WAL replication.
        #
        # Underpayment detection is stateless (compare on-chain amount
        # to Quote.amount_paid_piconeros), so every node publishes the
        # `QuoteUnderpaid` event locally — LiveViews on any node see
        # the modal transition without needing WAL-replay re-emission
        # (see `Markets.Store.Replay.maybe_emit_event/1` for the
        # cluster-state-write pattern used by :quote_filled).
        maybe_publish_underpaid(ref, txid, amount)

        credit_result =
          if Role.designated_processor?() do
            safe_process_confirmed(ref, txid, amount, confs)
          else
            :ok
          end

        amounts = Map.delete(state.txid_amounts, txid)
        order = :queue.filter(fn t -> t != txid end, state.txid_order)

        # Only mark the txid as "recently confirmed" if the
        # credit attempt actually succeeded (or the ref was handled
        # via a durable orphan record). A crash inside process_confirmed
        # — e.g. Trader.fill_quote raising because Guards.ensure_operational!
        # blows during a federation halt — historically dropped the
        # txid into recently_confirmed anyway, so subsequent Darks
        # rescans skipped it, and the user's funds sat in custody
        # with no retry, no orphan row, no refund. Skip the marker
        # on error so the next confirmation re-fire drives another
        # attempt; the orphan record already logged provides the
        # operator's alert surface.
        new_state =
          case credit_result do
            :ok ->
              {confirmed, confirmed_order} =
                bounded_put(
                  state.recently_confirmed,
                  state.recently_confirmed_order,
                  txid,
                  true,
                  @max_recently_confirmed
                )

              %{
                state
                | txid_amounts: amounts,
                  txid_order: order,
                  recently_confirmed: confirmed,
                  recently_confirmed_order: confirmed_order
              }

            {:error, _reason} ->
              %{state | txid_amounts: amounts, txid_order: order}
          end

        persist_recently_confirmed(new_state)
        {:noreply, new_state}

      :error ->
        Logger.warning("Poller: confirmed but no recorded amount, skipping, txid=#{txid}")

        {:noreply, state}
    end
  end

  # Surface the mempool/unconfirmed observation to LiveView consumers
  # so the QR / waiting-state can flip to "payment detected" before
  # the confirmation threshold lands. Published for quote and
  # market-deposit refs today; dispute flow can opt in later by
  # adding an analogous event type. Resolution to a market_id is
  # best-effort — if the quote has already been filled or expired
  # between Darks emitting `:deposit` and us looking it up, we
  # silently skip rather than publish a half-populated event.
  defp publish_deposit_observed({:quote, quote_id}, txid, amount) do
    case MarketsFacade.get_quote(quote_id) do
      {:ok, %{market_id: market_id}} ->
        EventBus.publish(%MarketsEvents.QuoteDepositObserved{
          quote_id: quote_id,
          market_id: market_id,
          txid: txid,
          amount_piconeros: amount,
          timestamp: DateTime.utc_now()
        })

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp publish_deposit_observed({:market_deposit, market_id}, txid, amount) do
    EventBus.publish(%MarketsEvents.MarketDepositObserved{
      market_id: market_id,
      txid: txid,
      amount_piconeros: amount,
      timestamp: DateTime.utc_now()
    })
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp publish_deposit_observed({:dispute, account_id, market_id}, txid, amount) do
    EventBus.publish(%MarketsEvents.DisputeDepositObserved{
      market_id: market_id,
      account_id: account_id,
      txid: txid,
      amount_piconeros: amount,
      timestamp: DateTime.utc_now()
    })
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp publish_deposit_observed(_ref, _txid, _amount), do: :ok

  # Locally publish `QuoteUnderpaid` when a confirmed deposit's amount
  # is less than the matched Quote's locked-in price. Fires on every
  # node's Poller — stateless, no cluster-write — so LiveViews on
  # any node see the modal transition. Silent no-op for market-deposit
  # or dispute refs, or when the Quote is gone.
  defp maybe_publish_underpaid({:quote, quote_id}, txid, amount) do
    case MarketsFacade.get_quote(quote_id) do
      {:ok, %{amount_paid_piconeros: expected} = quote} when amount < expected ->
        EventBus.publish(%MarketsEvents.QuoteUnderpaid{
          quote_id: quote_id,
          market_id: quote.market_id,
          txid: txid,
          amount_paid_piconeros: amount,
          amount_expected_piconeros: expected,
          refund_address: quote.refund_address,
          timestamp: DateTime.utc_now()
        })

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp maybe_publish_underpaid(_ref, _txid, _amount), do: :ok

  # Auto-enqueue a refund for an underpaid Quote. Only reached from
  # the designated processor's `process_confirmed` — the enqueue is a
  # cluster write and mustn't fan out to every node.
  #
  # Failures are logged but non-fatal: the Orphan row is already
  # written, so the operator can still refund manually from
  # Federation.Console if the auto-path breaks. Callers are wrapped
  # in `rescue`/`catch` at `process_confirmed/4` — this helper
  # additionally swallows enqueue errors so a Facade failure doesn't
  # abort the confirmed-tx handler.
  defp enqueue_underpayment_refund(quote, amount, txid) do
    case FederationFacade.enqueue_quote_underpayment_refund(
           quote.id,
           quote.account_id,
           quote.market_id,
           amount,
           quote.refund_address
         ) do
      {:ok, payout} ->
        Logger.info(
          "Poller: enqueued underpayment refund, quote_id=#{quote.id}, txid=#{txid}, payout_id=#{payout.id}, amount=#{amount}"
        )

        # The refund is now the Federation.Signer's responsibility —
        # drop this orphan out of the "awaiting operator action" count.
        # The DETS row stays as audit trail; only the count changes.
        # If the refund later fails at signing (dust, wallet unreachable),
        # PayoutFailed fires its own alert — no double signal needed.
        Orphans.mark_resolved(txid)

      {:error, :quote_underpayment_refund_already_pending} ->
        # A prior confirmation (or replay) already queued the refund
        # and marked the orphan resolved; nothing to do.
        Logger.info("Poller: underpayment refund already pending, quote_id=#{quote.id}, txid=#{txid}")

      {:error, reason} ->
        Logger.error(
          "Poller: underpayment refund enqueue failed, quote_id=#{quote.id}, txid=#{txid}, reason=#{inspect(reason)}"
        )
    end
  rescue
    e ->
      Logger.error(
        "Poller: underpayment refund enqueue crashed, quote_id=#{quote.id}, txid=#{txid}, reason=#{inspect(e)}"
      )
  catch
    :exit, reason ->
      Logger.error(
        "Poller: underpayment refund enqueue exited, quote_id=#{quote.id}, txid=#{txid}, reason=#{inspect(reason)}"
      )
  end

  # Bounded Map+queue — when the queue length hits `cap` the oldest
  # key is evicted before the new one is inserted. Cheaper than
  # walking the map looking for the oldest, and the queue order
  # stays consistent with insertion order.
  defp bounded_put(map, order, key, value, cap) do
    cond do
      Map.has_key?(map, key) ->
        {Map.put(map, key, value), order}

      :queue.len(order) >= cap ->
        {{:value, oldest}, dropped} = :queue.out(order)
        {Map.put(Map.delete(map, oldest), key, value), :queue.in(key, dropped)}

      true ->
        {Map.put(map, key, value), :queue.in(key, order)}
    end
  end

  # --- Private ---

  defp start_darks_poller(opts) do
    parent = self()

    poller_opts = [
      name: PerpWalk.Monero.Poller.Darks,
      lookup_subaddress: &__MODULE__.lookup_subaddress/1,
      on_deposit: fn payload -> send(parent, {:deposit, payload}) end,
      on_confirmed: fn payload -> send(parent, {:confirmed, payload}) end,
      on_reorg: fn payload -> send(parent, {:reorg, payload}) end,
      on_unconfirmed: fn payload -> send(parent, {:unconfirmed, payload}) end,
      confirmations: get_config(opts, :confirmations, @default_confirmations),
      poll_interval_ms: get_config(opts, :poll_interval_ms, @default_poll_interval_ms)
    ]

    case Darks.Poller.start_link(poller_opts) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.error("Poller: Darks.Poller failed to start, reason=#{inspect(reason)}")
        :ok
    end
  end

  # process_confirmed clauses can raise (e.g.
  # `Trader.fill_quote` calling `Guards.ensure_operational!` during a
  # federation halt) — an uncaught crash means the deposit was NOT
  # durably credited to the user. Record an orphan so the operator
  # has an actionable row, and return `{:error, _}` so
  # `handle_fresh_confirmed/4` skips the `recently_confirmed` marker.
  # That skip is the load-bearing bit: keeping the txid OFF the dedup
  # set means the next Darks rescan re-fires `:confirmed` and drives
  # another crediting attempt.
  #
  # Handled cases (underpayment, unknown_quote, fill rejected) are
  # inner-clause responsibilities — they record their own orphans and
  # return `:ok`; the wrapper only intercepts uncaught crashes.
  defp safe_process_confirmed(ref, txid, amount, confs) do
    process_confirmed(ref, txid, amount, confs)
  rescue
    e ->
      Logger.error("Poller: crediting crashed, ref=#{inspect(ref)}, txid=#{txid}, reason=#{inspect(e)}")

      record_crediting_failure(ref, txid, amount, confs, {:crash, e})
      {:error, {:crash, e}}
  catch
    :exit, reason ->
      Logger.error("Poller: crediting exited, ref=#{inspect(ref)}, txid=#{txid}, reason=#{inspect(reason)}")

      record_crediting_failure(ref, txid, amount, confs, {:exit, reason})
      {:error, {:exit, reason}}

    :throw, value ->
      Logger.error("Poller: crediting threw, ref=#{inspect(ref)}, txid=#{txid}, value=#{inspect(value)}")

      record_crediting_failure(ref, txid, amount, confs, {:throw, value})
      {:error, {:throw, value}}
  end

  defp record_crediting_failure(ref, txid, amount, confs, reason) do
    Orphans.record(
      :crediting_failed,
      txid,
      amount,
      %{ref: inspect(ref), reason: inspect(reason)},
      confs
    )
  rescue
    e ->
      Logger.error("Poller: could not record crediting failure, txid=#{txid}, reason=#{inspect(e)}")
      :ok
  catch
    :exit, _ -> :ok
    :throw, _ -> :ok
  end

  defp process_confirmed({:quote, quote_id}, txid, amount, confs) do
    case MarketsFacade.get_quote(quote_id) do
      {:ok, %{amount_paid_piconeros: expected} = _quote} when amount >= expected ->
        if amount > expected do
          overage = amount - expected

          # User paid more than the locked Quote price. The Position
          # materialises at the locked amount; the overage is recorded
          # in Orphans so the operator can manually return the surplus
          # via Federation.Console rather than relying on log scraping.
          Logger.warning(
            "Poller: overpaid deposit, quote_id=#{quote_id}, txid=#{txid}, amount=#{amount}, expected=#{expected}, overage=#{overage}"
          )

          Orphans.record(
            :overpayment,
            txid,
            overage,
            %{quote_id: quote_id, paid: amount, expected: expected},
            confs
          )
        end

        case MarketsFacade.fill_quote(quote_id, deposit_txid: txid) do
          {:ok, position} ->
            Logger.info(
              "Poller: filled, quote_id=#{quote_id}, position_id=#{position.id}, txid=#{txid}, confs=#{confs}"
            )

          {:error, reason} ->
            # User paid, the deposit confirmed, but the fill itself
            # was rejected (expired quote, AMM price moved past the
            # locked amount, or the source side ran dry between quote
            # and fill). The funds are now sitting in federation
            # custody attributable to a known subaddress but not to a
            # filled position — record an orphan so the operator can
            # refund via Federation.Console rather than discover the
            # discrepancy by tailing logs.
            Logger.warning("Poller: fill_quote failed, quote_id=#{quote_id}, txid=#{txid}, reason=#{inspect(reason)}")

            Orphans.record(
              :fill_failed,
              txid,
              amount,
              %{quote_id: quote_id, reason: inspect(reason)},
              confs
            )
        end

      {:ok, %{amount_paid_piconeros: expected} = quote} ->
        # User paid less than the locked Quote price. The Quote
        # won't fill (amount mismatch), but the deposit is real
        # money in federation custody on a known subaddress. Record
        # an orphan for audit, then auto-enqueue a refund to the
        # `refund_address` the user captured at quote generation
        # time. The Store's uniqueness scope on `source_quote_id`
        # makes the enqueue idempotent — Poller re-fire on the same
        # txid returns `:quote_underpayment_refund_already_pending`
        # instead of double-issuing.
        Logger.warning(
          "Poller: underpaid deposit, quote_id=#{quote_id}, txid=#{txid}, amount=#{amount}, expected=#{expected}"
        )

        Orphans.record(
          :underpayment,
          txid,
          amount,
          %{quote_id: quote_id, paid: amount, expected: expected},
          confs
        )

        enqueue_underpayment_refund(quote, amount, txid)

      {:error, :not_found} ->
        Orphans.record(:unknown_quote, txid, amount, quote_id, confs)
    end

    :ok
  end

  defp process_confirmed({:dispute, account_id, market_id}, txid, amount, confs) do
    case MarketsFacade.get_dispute(account_id, market_id) do
      {:ok, %{status: :awaiting_deposit, stake_amount_piconeros: expected}} ->
        cond do
          amount < expected ->
            # User paid less than the dispute stake. Dispute stays in
            # `:awaiting_deposit`, but the deposit is now in federation
            # custody on a known subaddress with no actionable record.
            # Same orphan-and-operator-review treatment as quotes.
            Logger.warning(
              "Poller: underpaid dispute deposit, market=#{market_id}, account=#{account_id}, txid=#{txid}, amount=#{amount}, expected=#{expected}"
            )

            Orphans.record(
              :underpayment,
              txid,
              amount,
              %{account_id: account_id, market_id: market_id, paid: amount, expected: expected},
              confs
            )

          not market_resolvable?(market_id) ->
            # The market already left :resolving — a dispute confirmed
            # now could never resolve, and claim_dispute_refund requires
            # a :resolved_* status, so confirming would strand the stake
            # in :live forever. Record and leave for the operator.
            Logger.warning(
              "Poller: dispute deposit for non-resolving market, market=#{market_id}, account=#{account_id}, txid=#{txid}, amount=#{amount}"
            )

            Orphans.record(
              :dispute_late_deposit,
              txid,
              amount,
              %{account_id: account_id, market_id: market_id},
              confs
            )

          true ->
            if amount > expected do
              overage = amount - expected

              # Overage on dispute deposit: record as an orphan so the
              # operator can manually return the surplus. The dispute
              # confirms at the expected stake; only the excess is orphaned.
              Logger.warning(
                "Poller: overpaid dispute deposit, market=#{market_id}, account=#{account_id}, txid=#{txid}, amount=#{amount}, expected=#{expected}, overage=#{overage}"
              )

              Orphans.record(
                :overpayment,
                txid,
                overage,
                %{account_id: account_id, market_id: market_id, paid: amount, expected: expected},
                confs
              )
            end

            case MarketsFacade.confirm_dispute_deposit(account_id, market_id) do
              {:ok, dispute} ->
                Logger.info(
                  "Poller: dispute confirmed, market=#{market_id}, account=#{account_id}, status=#{dispute.status}, txid=#{txid}, confs=#{confs}"
                )

              {:error, reason} ->
                # The deposit is real but the confirmation failed —
                # without an orphan row the funds are invisible.
                Logger.warning(
                  "Poller: confirm_dispute_deposit failed, market=#{market_id}, account=#{account_id}, txid=#{txid}, reason=#{inspect(reason)}"
                )

                Orphans.record(
                  :dispute_confirm_failed,
                  txid,
                  amount,
                  %{account_id: account_id, market_id: market_id, reason: inspect(reason)},
                  confs
                )
            end
        end

      {:ok, %{status: other_status}} ->
        # Dispute is already :live / :cancelled / resolved — this is a
        # duplicate stake tx (double-click, wallet resend). The funds
        # are in custody with nothing to attach to; record so the
        # operator can refund.
        Logger.warning(
          "Poller: deposit for non-awaiting dispute, status=#{other_status}, market=#{market_id}, account=#{account_id}, txid=#{txid}, amount=#{amount}"
        )

        Orphans.record(
          :duplicate_dispute_deposit,
          txid,
          amount,
          %{account_id: account_id, market_id: market_id, status: other_status},
          confs
        )

      {:error, :not_found} ->
        Orphans.record(
          :unknown_dispute,
          txid,
          amount,
          {account_id, market_id},
          confs
        )
    end

    :ok
  end

  defp process_confirmed({:market_deposit, market_id}, txid, amount, confs) do
    case MarketsFacade.get_market(market_id) do
      {:ok, %{deposit_amount: expected, status: :awaiting_deposit}} when amount >= expected ->
        if amount > expected do
          overage = amount - expected

          # Overage on market-deposit: record as an orphan so the
          # operator can manually return the surplus. Pre-fix
          # market deposits silently kept the overage — no audit
          # trail. The market confirms at the expected deposit;
          # only the excess is orphaned.
          Logger.warning(
            "Poller: overpaid market deposit, market=#{market_id}, txid=#{txid}, amount=#{amount}, expected=#{expected}, overage=#{overage}"
          )

          Orphans.record(
            :overpayment,
            txid,
            overage,
            %{market_id: market_id, paid: amount, expected: expected},
            confs
          )
        end

        case MarketsFacade.confirm_market_deposit(market_id) do
          {:ok, market} ->
            Logger.info(
              "Poller: market deposit confirmed, market=#{market_id}, status=#{market.status}, txid=#{txid}, confs=#{confs}"
            )

          {:error, reason} ->
            Logger.warning(
              "Poller: confirm_market_deposit failed, market=#{market_id}, txid=#{txid}, reason=#{inspect(reason)}"
            )
        end

      {:ok, %{deposit_amount: expected, status: :awaiting_deposit}} ->
        # `amount < expected` (the happy clause caught the >= case)
        # AND market is still awaiting its initial liquidity. Real
        # underpayment — funds are in federation custody on a known
        # subaddress but no actionable resource maps to them.
        Logger.warning(
          "Poller: underpaid market deposit, market=#{market_id}, txid=#{txid}, amount=#{amount}, expected=#{expected}"
        )

        Orphans.record(
          :underpayment,
          txid,
          amount,
          %{market_id: market_id, paid: amount, expected: expected},
          confs
        )

      {:ok, %{status: status}} ->
        # Market exists but is no longer in :awaiting_deposit — the
        # deposit already confirmed and the market moved on. This is
        # almost always a re-fired :confirmed (Darks rescan, Poller
        # restart with a recently_confirmed file that didn't yet
        # exist on the prior build, etc.). Not an underpayment, not
        # money that needs refunding. Log defensively so the
        # operator can spot a genuine dust-after-transition case in
        # the warnings stream.
        Logger.warning(
          "Poller: deposit to non-awaiting market, market=#{market_id}, status=#{status}, txid=#{txid}, amount=#{amount}"
        )

      {:error, :not_found} ->
        Orphans.record(:unknown_market_deposit, txid, amount, market_id, confs)
    end

    :ok
  end

  defp process_confirmed({:orphan, subaddr_index}, txid, amount, confs) do
    Logger.warning(
      "Poller: deposit to unmatched subaddress, txid=#{txid}, subaddr_index=#{subaddr_index}, amount=#{amount}"
    )

    Orphans.record(:unmatched_subaddress, txid, amount, %{subaddress_index: subaddr_index}, confs)
    :ok
  end

  defp process_confirmed(other, txid, _amount, _confs) do
    Logger.warning("Poller: unknown ref shape, txid=#{txid}, ref=#{inspect(other)}")
    :ok
  end

  # A dispute stake only has a resolution path while the market is in
  # :resolving — every dispute-resolution transition is gated on it.
  defp market_resolvable?(market_id) do
    case MarketsFacade.get_market(market_id) do
      {:ok, %{status: status}} -> status == :resolving
      _ -> false
    end
  end

  defp get_config(opts, key, default) do
    Keyword.get(
      opts,
      key,
      Application.get_env(:perpwalk, :monero_poller, [])
      |> Keyword.get(key, default)
    )
  end

  # --- Recently_confirmed Persistence ---

  # Without this, a PerpWalk Poller restart wipes the dedup set; a
  # subsequent Darks rescan (operator-triggered or wallet-side bug)
  # could re-fire :confirmed for a txid that already settled into a
  # Position, and the orphan path would queue an erroneous refund.
  defp persistence_path(opts) do
    case Keyword.get(opts, :recently_confirmed_path, :unset) do
      :unset ->
        case Application.get_env(:perpwalk, :data_dir) do
          nil -> nil
          dir -> Path.join([dir, "monero", "poller_recently_confirmed"])
        end

      path ->
        path
    end
  end

  defp load_recently_confirmed(nil), do: {%{}, :queue.new()}

  defp load_recently_confirmed(path) when is_binary(path) do
    case File.read(path) do
      {:ok, bin} ->
        try do
          case :erlang.binary_to_term(bin, [:safe]) do
            txids when is_list(txids) ->
              hydrate_recently_confirmed(txids)

            _other ->
              {%{}, :queue.new()}
          end
        rescue
          _ -> {%{}, :queue.new()}
        end

      {:error, _} ->
        {%{}, :queue.new()}
    end
  end

  defp hydrate_recently_confirmed(txids) do
    bounded =
      txids
      |> Enum.filter(&is_binary/1)
      |> Enum.take(-@max_recently_confirmed)

    map = Map.new(bounded, fn t -> {t, true} end)
    queue = Enum.reduce(bounded, :queue.new(), fn t, q -> :queue.in(t, q) end)
    {map, queue}
  end

  defp persist_recently_confirmed(%{persistence_path: nil}), do: :ok

  defp persist_recently_confirmed(%{persistence_path: path} = state) when is_binary(path) do
    File.mkdir_p!(Path.dirname(path))
    txids = :queue.to_list(state.recently_confirmed_order)
    bin = :erlang.term_to_binary(txids)
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, bin),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Poller: recently_confirmed persist failed, path=#{path}, reason=#{inspect(reason)}")

        :ok
    end
  end
end
