defmodule PerpWalk.Markets.Console do
  @moduledoc """
  Operator-facing iex helpers for market lifecycle operations.

  All mutating operations are deliberately iex-only — there is no
  HTTP endpoint, no LiveView form. Operator presence at a terminal
  is itself a security control: a stolen browser session can't
  submit a resolution, can't settle a market, can't acknowledge
  disputes.

  ## Usage

  Connect to a running node:

      $ iex --remsh perpwalk@anchor-1

  Then:

      iex> PerpWalk.Markets.Console.queue()
      iex> PerpWalk.Markets.Console.review("abc123...")
      iex> PerpWalk.Markets.Console.submit_resolution("abc123...", :yes)
      iex> PerpWalk.Markets.Console.acknowledge_disputes("abc123...")
      iex> PerpWalk.Markets.Console.reverse_resolution("abc123...", :no)
      iex> PerpWalk.Markets.Console.settle("abc123...")
      iex> PerpWalk.Markets.Console.void("abc123...")

  ## Output

  Functions that print return `:ok`; functions that return data
  return the data structure (or `{:ok, _} | {:error, reason}` for
  state-changing operations).
  """

  alias PerpWalk.Federation.Facade, as: FederationFacade
  alias PerpWalk.Markets.{AMM, Facade, Market, Moderation}

  # --- Read / Discovery ---

  @doc """
  Prints a summary of every market in a state that requires (or may
  soon require) operator attention: `:expired` (needs resolution
  submitted), `:resolving` (in dispute window — surface dispute count),
  and `:pending` (in listing window — informational). Returns `:ok`.
  """
  @spec queue() :: :ok
  def queue do
    markets = Facade.list_markets()
    threshold = Moderation.default_dispute_threshold()

    expired = Enum.filter(markets, &(&1.status == :expired))
    resolving = Enum.filter(markets, &(&1.status == :resolving))
    pending = Enum.filter(markets, &(&1.status == :pending))

    if expired == [] and resolving == [] and pending == [] do
      IO.puts("No markets pending operator action.")
    else
      print_section("EXPIRED — needs submit_resolution/2", expired, &print_queue_row/1)
      print_section("RESOLVING — in dispute window", resolving, &print_resolving_row(&1, threshold))
      print_section("PENDING — listing window", pending, &print_queue_row/1)
    end

    :ok
  end

  @doc """
  Prints a detailed snapshot of a single market — current state,
  outcome, dispute count, position counts, pool, timestamps.
  Returns the market struct or `{:error, :not_found}`.
  """
  @spec review(binary()) :: Market.t() | {:error, :not_found}
  def review(market_id) when is_binary(market_id) do
    case Facade.get_market(market_id) do
      {:ok, market} ->
        positions = Facade.list_positions_for_market(market_id)
        votes = Facade.list_votes_for_market(market_id)
        # Unacked math must use the LIVE count — the resolver's
        # acknowledge path pins live disputes only, so deriving
        # unacked from the total (which includes cancelled and
        # unfunded rows) would report a permanently-blocked market.
        total_disputes = Facade.dispute_count(market_id)
        live_disputes = Facade.live_dispute_count(market_id)
        unacked = max(live_disputes - market.disputes_acknowledged_count, 0)
        position_counts = position_status_counts(positions)
        vote_counts = vote_direction_counts(votes)

        IO.puts("""

        Market #{short(market.id)}
          description:           #{market.description}
          status:                #{market.status}
          outcome:               #{market.outcome || "—"}
          category:              #{market.category}
          creator:               #{short(market.creator_account_id)}
          deposit:               #{format_xmr(market.deposit_amount)}
          pool:                  YES=#{format_pool_side(market.pool.yes)}  NO=#{format_pool_side(market.pool.no)}
          unit_size:             #{format_xmr(market.unit_size)}/contract
          expiry:                #{market.expiry}
          resolution_deadline:   #{market.resolution_deadline}
          created_at:            #{market.created_at}
          resolved_at:           #{market.resolved_at || "—"}

          votes:                 up=#{vote_counts.up}  down=#{vote_counts.down}  net=#{vote_counts.up - vote_counts.down}
          reputation:            #{market.reputation}

          disputes:              live=#{live_disputes} total=#{total_disputes}  (acknowledged=#{market.disputes_acknowledged_count}, unacked=#{unacked})
          position_holders:      #{Facade.count_distinct_position_holders(market_id)}
          dispute_threshold:     #{Moderation.scaled_threshold(Facade.count_distinct_position_holders(market_id))} (floor=#{Moderation.dispute_floor()}, ratio=#{Moderation.dispute_ratio()})
          settle_blocked:        #{settle_blocked?(unacked, market_id)}

          positions:             open=#{position_counts.open}  winner=#{position_counts.settled_winner}  loser=#{position_counts.settled_loser}  refunded=#{position_counts.refunded}  paid_out=#{position_counts.paid_out}
        """)

        market

      {:error, :not_found} = err ->
        IO.puts("Market #{market_id} not found.")
        err
    end
  end

  # --- State-Changing Commands ---

  @doc """
  Submits the operator's outcome for an `:expired` market and
  transitions it to `:resolving`. Opens the dispute window — settle
  via `settle/1` after the window closes (and after acknowledging
  disputes if any accumulate).

  Returns `{:ok, market}` or `{:error, reason}`.
  """
  @spec submit_resolution(binary(), Market.outcome()) ::
          {:ok, Market.t()} | {:error, atom()}
  def submit_resolution(market_id, outcome)
      when is_binary(market_id) and outcome in [:yes, :no, :void] do
    case Facade.override_resolution(market_id, outcome) do
      {:ok, market} ->
        FederationFacade.record_audit(:markets_resolution_submitted, %{
          market_id: market.id,
          outcome: outcome,
          at: DateTime.utc_now()
        })

        IO.puts("Submitted #{short(market.id)} → :resolving with outcome=#{outcome}")

        IO.puts(
          "Dispute window is open. Run `acknowledge_disputes/1` or `reverse_resolution/2` if disputes accumulate."
        )

        {:ok, market}

      {:error, reason} = err ->
        IO.puts("submit_resolution refused: #{inspect(reason)}")
        err
    end
  end

  @doc """
  Records guardian acknowledgement of all currently-flagged disputes
  on a `:resolving` market. Clears the settle gate. Fresh disputes
  filed afterwards must again cross the threshold to re-block.

  Returns `{:ok, market}` or `{:error, reason}`.
  """
  @spec acknowledge_disputes(binary()) :: {:ok, Market.t()} | {:error, atom()}
  def acknowledge_disputes(market_id) when is_binary(market_id) do
    # Live count matches what the resolver pins in the market row —
    # reporting the total here would overstate what the ack covers.
    count = Facade.live_dispute_count(market_id)
    IO.puts("Acknowledging #{count} live dispute(s) on #{short(market_id)}.")

    case Facade.acknowledge_disputes(market_id) do
      {:ok, market} ->
        FederationFacade.record_audit(:markets_disputes_acknowledged, %{
          market_id: market.id,
          dispute_count: count,
          at: DateTime.utc_now()
        })

        IO.puts("Acknowledged. Settle is now permitted (until fresh disputes cross threshold again).")
        {:ok, market}

      {:error, reason} = err ->
        IO.puts("acknowledge_disputes refused: #{inspect(reason)}")
        err
    end
  end

  @doc """
  Reverses the recorded outcome on a `:resolving` market. Implicitly
  acknowledges any flagged disputes — reversing IS the review.

  Returns `{:ok, market}` or `{:error, reason}`.
  """
  @spec reverse_resolution(binary(), Market.outcome()) ::
          {:ok, Market.t()} | {:error, atom()}
  def reverse_resolution(market_id, new_outcome)
      when is_binary(market_id) and new_outcome in [:yes, :no, :void] do
    case Facade.get_market(market_id) do
      {:ok, %Market{outcome: previous}} ->
        IO.puts("Reversing #{short(market_id)}: #{previous} → #{new_outcome}")

        case Facade.reverse_resolution(market_id, new_outcome) do
          {:ok, market} ->
            FederationFacade.record_audit(:markets_resolution_reversed, %{
              market_id: market.id,
              previous_outcome: previous,
              new_outcome: new_outcome,
              at: DateTime.utc_now()
            })

            IO.puts("Reversed. Disputes implicitly acknowledged.")
            {:ok, market}

          {:error, reason} = err ->
            IO.puts("reverse_resolution refused: #{inspect(reason)}")
            err
        end

      {:error, :not_found} = err ->
        IO.puts("Market #{market_id} not found.")
        err
    end
  end

  @doc """
  Settles a `:resolving` market. Pays winners, consumes losers,
  atomic. Refuses if unacknowledged disputes are past the threshold.

  Prints a winner/loser/refund summary and prompts for confirmation
  before committing.
  """
  @spec settle(binary()) :: {:ok, Market.t()} | {:error, atom() | :cancelled}
  def settle(market_id) when is_binary(market_id) do
    with {:ok, market} <- Facade.get_market(market_id) do
      positions = Facade.list_positions_for_market(market_id)
      open_positions = Enum.filter(positions, &(&1.status == :open))
      {winners, losers} = partition_by_outcome(open_positions, market.outcome)
      # Live count, not total: cancelled/unfunded dispute rows must
      # not wedge the operator's settle preview forever.
      dispute_count = Facade.live_dispute_count(market_id)
      unacked = max(dispute_count - market.disputes_acknowledged_count, 0)
      holders = Facade.count_distinct_position_holders(market_id)
      threshold = Moderation.scaled_threshold(holders)

      IO.puts("""

      Settle preview for #{short(market_id)}:
        outcome:               #{market.outcome}
        open positions:        #{length(open_positions)}
        will become winners:   #{length(winners)}
        will become losers:    #{length(losers)}
        disputes (unacked):    #{unacked} / threshold #{threshold} (holders=#{holders})
      """)

      if Moderation.dispute_review_required?(unacked, holders) do
        IO.puts(
          "Settle is blocked: #{unacked} unacked disputes ≥ scaled threshold #{threshold}. Run acknowledge_disputes/1 first."
        )

        {:error, :unacknowledged_disputes}
      else
        confirm_and_apply(
          "Proceed with settle?",
          fn -> Facade.settle_market(market_id) end,
          fn settled ->
            FederationFacade.record_audit(:markets_settled, %{
              market_id: settled.id,
              outcome: settled.outcome,
              winners: length(winners),
              losers: length(losers),
              at: DateTime.utc_now()
            })
          end
        )
      end
    end
  end

  @doc """
  Voids a `:resolving` or `:expired` market. Refunds every open
  position, atomic. Used when the outcome is undecidable or the
  resolution deadline was missed.

  Prints a refund-count summary and prompts for confirmation.
  """
  @spec void(binary()) :: {:ok, Market.t()} | {:error, atom() | :cancelled}
  def void(market_id) when is_binary(market_id) do
    with {:ok, _market} <- Facade.get_market(market_id) do
      positions = Facade.list_positions_for_market(market_id)
      open_positions = Enum.filter(positions, &(&1.status == :open))
      total_refund = Enum.reduce(open_positions, 0, &(&1.amount_paid + &2))

      IO.puts("""

      Void preview for #{short(market_id)}:
        open positions:        #{length(open_positions)}
        will be refunded:      #{format_xmr(total_refund)}
      """)

      confirm_and_apply(
        "Proceed with void?",
        fn -> Facade.void_market(market_id) end,
        fn voided ->
          FederationFacade.record_audit(:markets_voided, %{
            market_id: voided.id,
            refunded_positions: length(open_positions),
            total_refund_piconeros: total_refund,
            at: DateTime.utc_now()
          })
        end
      )
    end
  end

  # --- Helpers ---

  defp short(id) when is_binary(id) and byte_size(id) >= 8, do: String.slice(id, 0, 8)
  defp short(id), do: to_string(id)

  defp format_xmr(piconeros) when is_integer(piconeros) do
    xmr = piconeros / 1_000_000_000_000
    "#{:erlang.float_to_binary(xmr, decimals: 6)} XMR"
  end

  # Pool reserves are stored as AMM subunits (see `AMM` moduledoc).
  # Operator console shows contract-count plus parenthesised raw
  # subunits, so both granularities are inspectable when debugging.
  defp format_pool_side(subunits) when is_integer(subunits) and subunits >= 0 do
    scale = AMM.pool_scale()
    contracts = subunits / scale
    "#{:erlang.float_to_binary(contracts, decimals: 3)} contracts (#{subunits} su)"
  end

  defp settle_blocked?(unacked, market_id) do
    holders = Facade.count_distinct_position_holders(market_id)
    if Moderation.dispute_review_required?(unacked, holders), do: "yes", else: "no"
  end

  defp position_status_counts(positions) do
    base = %{
      open: 0,
      settled_winner: 0,
      settled_loser: 0,
      refunded: 0,
      paid_out: 0
    }

    Enum.reduce(positions, base, fn p, acc ->
      Map.update(acc, p.status, 1, &(&1 + 1))
    end)
  end

  defp vote_direction_counts(votes) do
    Enum.reduce(votes, %{up: 0, down: 0}, fn
      %{direction: :up}, acc -> %{acc | up: acc.up + 1}
      %{direction: :down}, acc -> %{acc | down: acc.down + 1}
    end)
  end

  defp partition_by_outcome(positions, outcome) when outcome in [:yes, :no] do
    Enum.split_with(positions, &(&1.side == outcome))
  end

  defp partition_by_outcome(positions, _other), do: {[], positions}

  defp print_section(_title, [], _printer), do: :ok

  defp print_section(title, rows, printer) do
    IO.puts("\n[#{title}] (#{length(rows)})")
    Enum.each(rows, printer)
  end

  defp print_queue_row(market) do
    IO.puts("  #{short(market.id)}  #{market.description}")
  end

  defp print_resolving_row(market, threshold) do
    live_disputes = Facade.live_dispute_count(market.id)
    unacked = max(live_disputes - market.disputes_acknowledged_count, 0)
    flag = if unacked >= threshold, do: " ⚠ NEEDS REVIEW", else: ""

    IO.puts(
      "  #{short(market.id)}  outcome=#{market.outcome}  live_disputes=#{live_disputes} (unacked=#{unacked})#{flag}  #{market.description}"
    )
  end

  defp confirm_and_apply(prompt, action, on_success) do
    case IO.gets("#{prompt} (yes/N) ") do
      "yes\n" ->
        case action.() do
          {:ok, market} ->
            on_success.(market)
            IO.puts("Applied. Market #{short(market.id)} → #{market.status}.")
            {:ok, market}

          {:error, reason} = err ->
            IO.puts("Refused: #{inspect(reason)}")
            err
        end

      _ ->
        IO.puts("Cancelled.")
        {:error, :cancelled}
    end
  end
end
