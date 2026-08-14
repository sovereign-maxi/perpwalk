defmodule PerpWalk.Markets.Services.Voter do
  @moduledoc """
  Records community moderation votes on `:pending` markets and
  triggers rejection when the burn threshold is crossed.

  Vote semantics:

  - One vote per `(account_id, market_id)`. A second vote from the
    same account overwrites the first.
  - Votes are silent on the EventBus — only meaningful state
    changes (a `MarketRejected` + `DepositBurned`) are published.
  - The reputation score on the market is the cached
    `Moderation.reputation/1` over all votes for that market.
  - A creator cannot vote on their own market.
  """

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Guards
  alias PerpWalk.Markets.{Market, Moderation, Store, Vote}

  @doc """
  Casts an `:up` or `:down` vote on a `:pending` market. Recomputes
  the market reputation and rejects + burns if the threshold is hit.

  Returns `{:ok, market}` with the updated market struct.
  """
  @spec cast_vote(binary(), binary(), :up | :down) ::
          {:ok, Market.t()}
          | {:error, :market_not_found | :market_not_pending | :creator_cannot_vote | atom()}
  def cast_vote(account_id, market_id, direction)
      when is_binary(account_id) and is_binary(market_id) and direction in [:up, :down] do
    Guards.ensure_operational!()

    with {:ok, market} <- fetch_market(market_id),
         :ok <- ensure_pending(market),
         :ok <- ensure_not_creator(market, account_id),
         :ok <- ensure_under_market_cap(market.id, account_id, direction) do
      record_and_evaluate(market, account_id, direction)
    end
  end

  # --- Internal ---

  # Per-market hard ceiling on the vote count, applied PER
  # DIRECTION. A logged-in attacker rotating fresh accounts can
  # otherwise grow the votes table by one row + WAL entry per
  # fresh-account-per-market. The Wilson burn decision stabilises
  # long before any realistic vote count nears this cap; the cap
  # exists only to bound the DoS amplifier under account-rotation
  # spam. A re-vote from an already-counted account is exempt — it
  # overwrites in place.
  #
  # The per-direction split matters: counting up+down together would
  # let an attacker stuff the UP bucket to the cap and freeze the
  # DOWN-vote burn path entirely — every subsequent down-vote would
  # bounce off :market_vote_cap_reached and the market could never
  # be burned.
  @max_votes_per_market 10_000

  defp ensure_under_market_cap(market_id, account_id, direction) do
    votes = Store.list_votes_for_market(market_id)

    cond do
      Enum.any?(votes, &(&1.account_id == account_id)) -> :ok
      Enum.count(votes, &(&1.direction == direction)) < @max_votes_per_market -> :ok
      true -> {:error, :market_vote_cap_reached}
    end
  end

  defp fetch_market(market_id) do
    case Store.get_market(market_id) do
      {:ok, market} -> {:ok, market}
      {:error, :not_found} -> {:error, :market_not_found}
    end
  end

  defp ensure_pending(%Market{status: :pending}), do: :ok
  defp ensure_pending(_market), do: {:error, :market_not_pending}

  defp ensure_not_creator(market, account_id) do
    if Market.creator?(market, account_id),
      do: {:error, :creator_cannot_vote},
      else: :ok
  end

  defp record_and_evaluate(market, account_id, direction) do
    vote = Vote.new(account_id, market.id, direction)

    with :ok <- Store.put_vote(vote) do
      # Burn-or-not decision uses the live tally read inside the
      # serial handler — the lock that re-tallies for reputation
      # also locks the markets table, so a concurrent voter can't
      # race past the burn threshold and have their write
      # silently overwritten by our older snapshot.
      votes = Store.list_votes_for_market(market.id)

      if Moderation.burn?(votes) do
        reputation = Moderation.reputation(votes)
        market_with_rep = Market.put_reputation(market, reputation)
        reject_and_burn(market_with_rep)
      else
        case Store.refresh_pending_market_reputation(market.id, &Moderation.reputation/1) do
          {:ok, %Market{} = refreshed} ->
            {:ok, refreshed}

          {:ok, :not_pending} ->
            # The market burned between our `put_vote` and our
            # reputation refresh — our vote is recorded, the burn
            # path will have emitted its events from the racing
            # voter's commit. Return the snapshot for the caller's
            # immediate render; the next read will reflect live.
            {:ok, market}

          {:error, _} = err ->
            err
        end
      end
    end
  end

  # Concurrent down-voters can both push past the burn threshold
  # and arrive here with their own snapshot of the market.
  # `Store.commit_market_rejection/1` collapses the check and the
  # write into a single GenServer handler: the first request to be
  # processed transitions the market and reports `:transitioned`;
  # any subsequent request sees the row already in `:rejected` and
  # reports `:already_rejected`. Events fire only on the
  # transitioning call, so a single underlying state change
  # produces a single pair of event-stream emissions regardless of
  # how many concurrent voters raced the threshold. The earlier
  # check-then-act pattern via `get_market` + `put_market` had a
  # window where both voters' `get_market` returned `:live` and
  # both fell through to emit events.
  defp reject_and_burn(market) do
    {:ok, rejected} = Market.reject(market)

    case Store.commit_market_rejection(rejected) do
      {:ok, :transitioned} ->
        now = DateTime.utc_now()

        EventBus.publish(%MarketsEvents.MarketRejected{
          market_id: rejected.id,
          reputation: rejected.reputation,
          timestamp: now
        })

        EventBus.publish(%MarketsEvents.DepositBurned{
          market_id: rejected.id,
          amount: rejected.deposit_amount,
          timestamp: now
        })

        {:ok, rejected}

      {:ok, :already_rejected} ->
        {:ok, rejected}

      {:error, {:not_rejectable, live_status}} ->
        # The market was activated between the voter's snapshot read
        # and this commit — traders may have opened positions since,
        # so clobbering it to `:rejected` would burn the creator's
        # deposit AND strand every opened position. The voter loses
        # this race; their vote stays recorded but no burn event
        # fires and the market continues as `:active`. Return the
        # live snapshot so the caller renders normally.
        case Store.get_market(rejected.id) do
          {:ok, live} -> {:ok, live}
          {:error, _reason} -> {:ok, %{rejected | status: live_status}}
        end

      {:error, _} = err ->
        err
    end
  end
end
