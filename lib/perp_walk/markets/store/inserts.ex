defmodule PerpWalk.Markets.Store.Inserts do
  @moduledoc """
  ETS mutation helpers for the Markets domain Store.

  Each function takes the live `tables` map (built by
  `Markets.Store.build_table_config/1`) and an entity struct, and
  performs the primary insert plus every secondary-index update
  in lockstep. Counter updates piggy-back on the status transitions
  detected by these helpers — see `update_slash_counters_on_transition/3`
  and `update_market_counters_on_transition/3`.

  Pure of GenServer state; the only side effects are `:ets.*` calls
  on the supplied tables. Both `Markets.Store.handle_call/3` (write
  path) and `Markets.Store.Replay.apply_wal_entry/2` (WAL replay
  path) drive these — so changes here are visible at runtime and on
  cold-boot reconstruction.
  """

  require Logger

  alias PerpWalk.Markets.{Dispute, Market, Position, Quote, Vote}

  @ledger_counter_keys [
    :slashed_piconeros,
    :burned_piconeros,
    :spread_total_piconeros,
    :slash_count,
    :burn_count,
    :settled_market_count
  ]

  @doc """
  Seeds every ledger counter to 0. Called from `Store.init/1` after
  the counter table is created; gives the public read API a known
  zero baseline so callers never see a missing-key fallback.
  """
  @spec init_ledger_counters(map()) :: :ok
  def init_ledger_counters(tables) do
    Enum.each(@ledger_counter_keys, fn key ->
      :ets.insert(tables.ledger_counters, {key, 0})
    end)

    :ok
  end

  @doc "Counter keys seeded by `init_ledger_counters/1`. Used by `ledger_counters/0`."
  @spec ledger_counter_keys() :: [atom()]
  def ledger_counter_keys, do: @ledger_counter_keys

  @doc """
  Returns the current status of the market with `id`, or `nil` if
  the market doesn't exist. Used by `do_put_resolution` to detect
  the `:settled` transition for spread accumulation.
  """
  @spec lookup_market_status(map(), binary()) :: atom() | nil
  def lookup_market_status(tables, id) do
    case :ets.lookup(tables.markets, id) do
      [{_, %Market{status: status}}] -> status
      [] -> nil
    end
  end

  @doc """
  CAS comparator. Market-struct fields compare against `live`. The
  optional `:live_dispute_count` key is checked separately because
  dispute writes go through the direct `:public` ETS path (not the
  Store's serial handler), so the count must be re-read inside the
  critical section — outside it the caller's read is already stale
  by the time we get here.
  """
  @spec cas_matches?(Market.t(), map(), map()) :: boolean()
  def cas_matches?(%Market{} = live, expected, tables) do
    Enum.all?(expected, fn
      {:live_dispute_count, expected_count} ->
        live_count_in_table(tables, live.id) == expected_count

      {k, v} ->
        Map.get(live, k) == v
    end)
  end

  @doc """
  Counts `:live` disputes for a market via the `disputes_by_market`
  index, then filters by status. Bounded by disputes-in-market, not
  total dispute count — the prior `:ets.select_count/2` over the
  whole disputes table dominated put_resolution_cas under load.
  """
  @spec live_count_in_table(map(), binary()) :: non_neg_integer()
  def live_count_in_table(tables, market_id) when is_map(tables) do
    case :ets.lookup(tables.disputes_by_market, market_id) do
      [] ->
        0

      pairs ->
        Enum.count(pairs, fn {_, key} ->
          case :ets.lookup(tables.disputes, key) do
            [{_, %Dispute{status: :live}}] -> true
            _ -> false
          end
        end)
    end
  rescue
    _ -> 0
  end

  @doc """
  Inserts/updates a market and keeps all secondary market indexes
  (status / category / creator / subaddress) in sync. Category and
  creator are immutable for a given market so those bags dedupe
  naturally; only the status index needs the prior-row-then-replace
  dance. Counter updates piggy-back on status transitions detected
  here.
  """
  @spec insert_market(map(), Market.t()) :: :ok
  def insert_market(tables, %Market{} = market) do
    prior_status =
      case :ets.lookup(tables.markets, market.id) do
        [{_, %Market{status: s}}] -> s
        [] -> nil
      end

    cond do
      prior_status == market.status ->
        :ok

      is_nil(prior_status) ->
        :ets.insert(tables.markets_by_status, {market.status, market.id})

      true ->
        :ets.delete_object(tables.markets_by_status, {prior_status, market.id})
        :ets.insert(tables.markets_by_status, {market.status, market.id})
    end

    :ets.insert(tables.markets_by_category, {market.category, market.id})
    :ets.insert(tables.markets_by_creator, {market.creator_account_id, market.id})
    :ets.insert(tables.markets, {market.id, market})

    if is_integer(market.deposit_subaddress_index) and market.deposit_subaddress_index > 0 do
      maybe_log_subaddress_collision(
        tables.markets_by_subaddress,
        market.deposit_subaddress_index,
        market.id,
        :market
      )

      :ets.insert(tables.markets_by_subaddress, {market.deposit_subaddress_index, market.id})
    end

    update_market_counters_on_transition(tables, prior_status, market)
    :ok
  end

  @doc """
  Dual-table position write: primary `:set` table by id, secondary
  `:bag` indexes by market_id, account_id, and status. The market
  and account indexes are immutable for a given position id and
  idempotent for a `:bag`. The status index follows the
  transition-pattern: delete the prior `{old_status, id}` pair on
  status change, then insert the new pair.
  """
  @spec insert_position(map(), Position.t()) :: :ok
  def insert_position(tables, %Position{} = p) do
    prior_status =
      case :ets.lookup(tables.positions, p.id) do
        [{_, %Position{status: s}}] -> s
        [] -> nil
      end

    :ets.insert(tables.positions, {p.id, p})
    :ets.insert(tables.positions_by_market, {p.market_id, p.id})
    :ets.insert(tables.positions_by_account, {p.account_id, p.id})

    cond do
      prior_status == p.status ->
        :ok

      is_nil(prior_status) ->
        :ets.insert(tables.positions_by_status, {p.status, p.id})

      true ->
        :ets.delete_object(tables.positions_by_status, {prior_status, p.id})
        :ets.insert(tables.positions_by_status, {p.status, p.id})
    end

    :ok
  end

  @doc """
  Maintains every secondary dispute index alongside the primary
  disputes table. By-market and by-account dedupe naturally
  (dispute_key is immutable). By-status follows the
  transition-pattern. Counter updates piggy-back on the
  `:resolved_for` transition.
  """
  @spec insert_dispute(map(), Dispute.t()) :: :ok
  def insert_dispute(tables, %Dispute{} = d) do
    key = {d.account_id, d.market_id}

    prior_status =
      case :ets.lookup(tables.disputes, key) do
        [{_, %Dispute{status: s}}] -> s
        [] -> nil
      end

    :ets.insert(tables.disputes, {key, d})
    :ets.insert(tables.disputes_by_market, {d.market_id, key})
    :ets.insert(tables.disputes_by_account, {d.account_id, key})

    if is_integer(d.deposit_subaddress_index) and d.deposit_subaddress_index > 0 do
      maybe_log_subaddress_collision(
        tables.disputes_by_subaddress,
        d.deposit_subaddress_index,
        key,
        :dispute
      )

      :ets.insert(tables.disputes_by_subaddress, {d.deposit_subaddress_index, key})
    end

    cond do
      prior_status == d.status ->
        :ok

      is_nil(prior_status) ->
        :ets.insert(tables.disputes_by_status, {d.status, key})

      true ->
        :ets.delete_object(tables.disputes_by_status, {prior_status, key})
        :ets.insert(tables.disputes_by_status, {d.status, key})
    end

    update_slash_counters_on_transition(tables, prior_status, d)
    :ok
  end

  @doc """
  Checks whether a Quote's subaddress index is unallocated against
  this tables's secondary index. Returns `:ok` if free or
  re-pointing at the same Quote id (replay/idempotent retry), or
  `{:error, :subaddress_collision}` if a different Quote already
  holds the slot. Public so callers can fail closed BEFORE the WAL
  append rather than discover the collision after persistence.
  """
  @spec subaddress_available_for_quote(map(), Quote.t()) ::
          :ok | {:error, :subaddress_collision}
  def subaddress_available_for_quote(tables, %Quote{subaddress_index: idx, id: id})
      when is_integer(idx) and idx > 0 and is_binary(id) do
    case :ets.lookup(tables.quotes_by_subaddress, idx) do
      [] -> :ok
      [{^idx, ^id}] -> :ok
      [{^idx, _other}] -> {:error, :subaddress_collision}
    end
  end

  def subaddress_available_for_quote(_tables, %Quote{}), do: :ok

  @doc """
  Same contract as `subaddress_available_for_quote/2` but for the
  `markets_by_subaddress` index. Returns `:ok` when the market has
  no subaddress or when the slot is unoccupied or held by the same
  market; returns `{:error, :subaddress_collision}` when a
  different Market already holds the slot. Public so
  `Store.handle_call({:put_market, ...})` can fail closed BEFORE the
  WAL append (mirrors the quote pattern).
  """
  @spec subaddress_available_for_market(map(), Market.t()) ::
          :ok | {:error, :subaddress_collision}
  def subaddress_available_for_market(tables, %Market{
        deposit_subaddress_index: idx,
        id: id
      })
      when is_integer(idx) and idx > 0 and is_binary(id) do
    case :ets.lookup(tables.markets_by_subaddress, idx) do
      [] -> :ok
      [{^idx, ^id}] -> :ok
      [{^idx, _other}] -> {:error, :subaddress_collision}
    end
  end

  def subaddress_available_for_market(_tables, %Market{}), do: :ok

  @doc """
  Same contract as `subaddress_available_for_quote/2` but for the
  `disputes_by_subaddress` index. Dispute rows are keyed by
  `{account_id, market_id}` so the identity check compares against
  the tuple rather than a single id field. `:ok` when unoccupied
  or held by the same `(account_id, market_id)` pair.
  """
  @spec subaddress_available_for_dispute(map(), Dispute.t()) ::
          :ok | {:error, :subaddress_collision}
  def subaddress_available_for_dispute(tables, %Dispute{
        deposit_subaddress_index: idx,
        account_id: aid,
        market_id: mid
      })
      when is_integer(idx) and idx > 0 do
    case :ets.lookup(tables.disputes_by_subaddress, idx) do
      [] -> :ok
      [{^idx, {^aid, ^mid}}] -> :ok
      [{^idx, _other}] -> {:error, :subaddress_collision}
    end
  end

  def subaddress_available_for_dispute(_tables, %Dispute{}), do: :ok

  @doc """
  Maintains the `quotes_by_market` / `quotes_by_account` /
  `quotes_by_subaddress` indexes alongside the primary quotes table.
  Quote.market_id and account_id are immutable so the bags dedupe;
  the subaddress index is unique. Collisions are logged here and
  the live-write path fails closed earlier via
  `subaddress_available_for_quote/2`; this function still proceeds
  on collision because it's also driven by WAL replay where the
  collision is the historical truth being rehydrated.
  """
  @spec insert_quote(map(), Quote.t()) :: :ok
  def insert_quote(tables, %Quote{} = q) do
    :ets.insert(tables.quotes, {q.id, q})
    :ets.insert(tables.quotes_by_market, {q.market_id, q.id})
    :ets.insert(tables.quotes_by_account, {q.account_id, q.id})

    # Ordered-set index keyed by `{unix_expires_at, quote_id}`.
    # Scheduler uses this to select expired quotes in O(K) via
    # a bounded ETS match spec (no full-list scan).
    expires_unix = DateTime.to_unix(q.expires_at)
    :ets.insert(tables.quotes_by_expiry, {{expires_unix, q.id}})

    if is_integer(q.subaddress_index) and q.subaddress_index > 0 do
      maybe_log_subaddress_collision(
        tables.quotes_by_subaddress,
        q.subaddress_index,
        q.id,
        :quote
      )

      :ets.insert(tables.quotes_by_subaddress, {q.subaddress_index, q.id})
    end

    :ok
  end

  @doc """
  Quotes are deleted (on fill / expiry). The bag-index rows must
  be removed alongside, otherwise `list_quotes_for_*` returns ids
  that no longer exist in the primary table.
  """
  @spec delete_quote(map(), binary()) :: :ok
  def delete_quote(tables, quote_id) when is_binary(quote_id) do
    case :ets.lookup(tables.quotes, quote_id) do
      [{^quote_id, %Quote{} = q}] ->
        :ets.delete_object(tables.quotes_by_market, {q.market_id, quote_id})
        :ets.delete_object(tables.quotes_by_account, {q.account_id, quote_id})
        :ets.delete(tables.quotes_by_expiry, {DateTime.to_unix(q.expires_at), quote_id})

        if is_integer(q.subaddress_index) and q.subaddress_index > 0 do
          :ets.delete(tables.quotes_by_subaddress, q.subaddress_index)
        end

      _ ->
        :ok
    end

    :ets.delete(tables.quotes, quote_id)
    :ok
  end

  @doc """
  Vote write: primary `:set` table keyed by `{account_id, market_id}`,
  secondary `:bag` index by market_id. One vote per account per
  market — re-puts overwrite.
  """
  @spec insert_vote(map(), Vote.t()) :: :ok
  def insert_vote(tables, %Vote{} = v) do
    key = {v.account_id, v.market_id}
    :ets.insert(tables.votes, {key, v})
    :ets.insert(tables.votes_by_market, {v.market_id, key})
    :ok
  end

  # --- Counter Transitions ---

  # Slash is recorded at the `:resolved_for` transition. Subsequent
  # writes (e.g. `:refunded_partial`) keep the slashed amount but
  # don't change the ledger total — the slash already counted.
  # `prior_status != :resolved_for` gates the increment so a re-write
  # of the same `:resolved_for` row (replay, idempotent retry) doesn't
  # double-count.
  defp update_slash_counters_on_transition(tables, prior_status, %Dispute{
         status: :resolved_for,
         slashed_amount_piconeros: slash
       })
       when prior_status != :resolved_for and is_integer(slash) and slash > 0 do
    :ets.update_counter(
      tables.ledger_counters,
      :slashed_piconeros,
      slash,
      {:slashed_piconeros, 0}
    )

    :ets.update_counter(
      tables.ledger_counters,
      :slash_count,
      1,
      {:slash_count, 0}
    )
  end

  defp update_slash_counters_on_transition(_tables, _prior, _dispute), do: :ok

  # Burn happens at the `:rejected` transition. Settle count goes up
  # at the `:settled` transition. `prior_status != new` gates each
  # increment so a re-write or idempotent retry doesn't double-count.
  # Spread accumulation lives in `Store.do_put_resolution/4` (not
  # here) because it needs the position list, which is only in scope
  # at the resolution call.
  defp update_market_counters_on_transition(tables, prior_status, %Market{
         status: :rejected,
         deposit_amount: amount
       })
       when prior_status != :rejected and is_integer(amount) and amount > 0 do
    :ets.update_counter(
      tables.ledger_counters,
      :burned_piconeros,
      amount,
      {:burned_piconeros, 0}
    )

    :ets.update_counter(
      tables.ledger_counters,
      :burn_count,
      1,
      {:burn_count, 0}
    )
  end

  defp update_market_counters_on_transition(tables, prior_status, %Market{status: :settled})
       when prior_status != :settled do
    :ets.update_counter(
      tables.ledger_counters,
      :settled_market_count,
      1,
      {:settled_market_count, 0}
    )
  end

  defp update_market_counters_on_transition(_tables, _prior, _market), do: :ok

  # Subaddresses come from a wallet-side monotonic counter, so two
  # records claiming the same subaddress_index means either an
  # allocator bug (H9: two nodes independently ran wallet
  # `create_address` and both handed out "index N") or a wallet
  # swap. Fail closed: raise so the surrounding GenServer handler
  # aborts the write cleanly. The prior "log only, insert proceeds"
  # variant let the collision propagate through — one payer's
  # deposit filled another user's quote and two positions were
  # inserted for a single deposit.
  #
  # On the WAL replay path this raise crashes the Store, which is
  # the correct fail-closed response to WAL-level divergence — a
  # follower must never silently accept an entry whose contents
  # violate a cluster invariant.
  defp maybe_log_subaddress_collision(table, idx, new_value, kind) do
    case :ets.lookup(table, idx) do
      [] ->
        :ok

      [{^idx, ^new_value}] ->
        :ok

      [{^idx, other}] ->
        Logger.error(
          "Inserts: subaddress index collision, kind=#{kind}, index=#{idx}, " <>
            "prior=#{inspect(other)}, new=#{inspect(new_value)}"
        )

        raise ArgumentError,
              "subaddress index collision (kind=#{kind}, index=#{idx}): " <>
                "cannot insert #{inspect(new_value)}, already owned by #{inspect(other)}. " <>
                "This is either an allocator bug (two nodes both ran wallet " <>
                "create_address and handed out the same index) or a wallet swap. " <>
                "Investigate before continuing writes."
    end
  end
end
