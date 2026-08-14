defmodule PerpWalk.Markets.Services.Disputer do
  @moduledoc """
  Records community dispute flags against a market's submitted
  resolution and signals the guardian federation when re-review
  is mandatory.

  Disputes are STAKED. Filing a dispute requires depositing XMR
  to a per-dispute Monero subaddress. The dispute is recorded
  immediately as `:awaiting_deposit` and only counts toward the
  review threshold once the deposit confirms on-chain
  (transitioning to `:live`).

  Stake size is a fixed percentage (default 10%) of the creator's
  initial liquidity — see `Markets.Moderation.dispute_stake_for_market/1`.
  Deterministic, scales with the creator's own commitment, ignores
  traded volume (so wash-trading cannot influence the stake).

  ## Flow

      start_dispute(account_id, market_id)
        ↓
      market is :resolving, allocate per-dispute subaddress, mint
      Dispute in :awaiting_deposit, persist, return to caller
      ↓ user sends XMR ↓
      Poller observes confirmed deposit, calls confirm_deposit/2
        ↓
      Dispute → :live, threshold count includes this dispute, if
      threshold crossed publish DisputeReReviewTriggered

  Idempotency:
  - One dispute per `(account_id, market_id)`. Re-calling
    `start_dispute` for an already-disputing account returns the
    existing dispute (don't double-allocate subaddresses).
  - `confirm_deposit/2` is idempotent — calling on a `:live`
    dispute returns `{:ok, dispute}` unchanged.
  """

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Guards
  alias PerpWalk.Markets.{Dispute, Market, Moderation, Store}
  alias PerpWalk.Monero.Facade, as: MoneroFacade

  @doc """
  Starts a dispute on a `:resolving` market. Allocates a Monero
  subaddress, persists the dispute as `:awaiting_deposit`, and
  returns it. The caller (LiveView) renders the deposit
  instructions to the user.

  Returns `{:ok, dispute}` (with deposit instructions on the
  struct) or `{:error, reason}`.
  """
  @spec start_dispute(binary(), binary(), keyword()) ::
          {:ok, Dispute.t()}
          | {:error,
             :market_not_found
             | :market_not_resolving
             | :creator_cannot_dispute_own_market
             | :must_have_traded_on_market
             | {:subaddress_provider_failed, term()}
             | atom()}
  def start_dispute(account_id, market_id, opts \\ [])
      when is_binary(account_id) and is_binary(market_id) do
    Guards.ensure_operational!()

    with {:ok, market} <- fetch_market(market_id),
         :ok <- ensure_resolving(market),
         :ok <- ensure_not_creator(market, account_id),
         :ok <- ensure_has_traded(market.id, account_id) do
      record_or_return_existing(market, account_id, opts)
    end
  end

  # Voter forbids self-vote with the same shape; disputes deserve
  # the same asymmetry. A creator filing against their own market
  # is at best a self-slash if guardians acknowledge, and at worst
  # a sock-puppet vector to inflate the live count toward the
  # re-review threshold.
  defp ensure_not_creator(market, account_id) do
    if PerpWalk.Markets.Market.creator?(market, account_id),
      do: {:error, :creator_cannot_dispute_own_market},
      else: :ok
  end

  # Disputes are the trader's recourse against a wrong-outcome
  # resolution. A viewer with no position has no skin in the game
  # and no economic standing to challenge — same shape as
  # `ensure_not_creator` but on the other side. Refusing non-traders
  # also keeps the dispute pool free of speculative trolls who
  # would otherwise stake against every market in turn.
  defp ensure_has_traded(market_id, account_id) do
    market_id
    |> Store.list_positions_for_market()
    |> Enum.any?(&(&1.account_id == account_id))
    |> case do
      true -> :ok
      false -> {:error, :must_have_traded_on_market}
    end
  end

  @doc """
  Marks a dispute's deposit as confirmed on-chain. Idempotent —
  calling on an already-`:live` dispute is a no-op success.
  Publishes `DisputeFlagged` and (when threshold is crossed for
  the first time) `DisputeReReviewTriggered`.
  """
  @spec confirm_deposit(binary(), binary()) ::
          {:ok, Dispute.t()} | {:error, atom()}
  def confirm_deposit(account_id, market_id)
      when is_binary(account_id) and is_binary(market_id) do
    Guards.ensure_operational!()

    with {:ok, dispute} <- fetch_dispute(account_id, market_id) do
      do_confirm(dispute)
    end
  end

  defp do_confirm(%Dispute{status: :live} = dispute), do: {:ok, dispute}

  defp do_confirm(%Dispute{} = dispute) do
    with {:ok, confirmed} <- Dispute.confirm_deposit(dispute),
         :ok <- Store.put_dispute(confirmed) do
      publish_flagged_and_maybe_review(confirmed)
      {:ok, confirmed}
    end
  end

  @doc """
  Cancels a pending (`:awaiting_deposit`) dispute. Used when the
  dispute modal is dismissed without funding so the row doesn't
  linger in the user's portfolio. Idempotent on
  `:cancelled`. Refuses on funded statuses (`:live` and beyond) —
  once a deposit confirms, the dispute is committed.

  Publishes nothing — `:awaiting_deposit` never triggered a
  `DisputeFlagged` event in the first place, so cancellation has
  no downstream consumers to notify.
  """
  @spec cancel_pending(binary(), binary()) ::
          {:ok, Dispute.t()}
          | {:error, :dispute_not_found | :invalid_transition | term()}
  def cancel_pending(account_id, market_id)
      when is_binary(account_id) and is_binary(market_id) do
    Guards.ensure_operational!()

    with {:ok, dispute} <- fetch_dispute(account_id, market_id) do
      do_cancel(dispute)
    end
  end

  defp do_cancel(%Dispute{status: :cancelled} = dispute), do: {:ok, dispute}

  defp do_cancel(%Dispute{} = dispute) do
    with {:ok, cancelled} <- Dispute.cancel(dispute),
         :ok <- Store.put_dispute(cancelled) do
      {:ok, cancelled}
    end
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

  defp fetch_dispute(account_id, market_id) do
    case Store.get_dispute(account_id, market_id) do
      {:ok, dispute} -> {:ok, dispute}
      {:error, :not_found} -> {:error, :dispute_not_found}
    end
  end

  defp record_or_return_existing(market, account_id, opts) do
    case Store.get_dispute(account_id, market.id) do
      # A previously-cancelled record shouldn't block a fresh
      # dispute — the user clicked Flag, dismissed the modal, and
      # now wants to try again. Treat as not_found.
      {:ok, %Dispute{status: :cancelled}} -> create_new(market, account_id, opts)
      {:ok, existing} -> {:ok, existing}
      {:error, :not_found} -> create_new(market, account_id, opts)
    end
  end

  defp create_new(%Market{} = market, account_id, opts) do
    stake = Moderation.dispute_stake_for_market(market.deposit_amount)
    provider = resolve_subaddress_provider(opts)

    with {:ok, %{address: address, address_index: index}} <- allocate_subaddress(provider),
         {:ok, dispute} <-
           Dispute.new(
             account_id: account_id,
             market_id: market.id,
             stake_amount_piconeros: stake,
             deposit_subaddress: address,
             deposit_subaddress_index: index
           ),
         :ok <- Store.put_dispute(dispute) do
      {:ok, dispute}
    end
  end

  defp publish_flagged_and_maybe_review(%Dispute{} = dispute) do
    market_id = dispute.market_id
    new_count = Store.live_dispute_count(market_id)
    position_holders = Store.count_distinct_position_holders(market_id)
    threshold = Moderation.scaled_threshold(position_holders)
    now = DateTime.utc_now()

    EventBus.publish(%MarketsEvents.DisputeFlagged{
      market_id: market_id,
      account_id: dispute.account_id,
      dispute_count: new_count,
      timestamp: now
    })

    # Fire ReReviewTriggered exactly once per acknowledgement cycle,
    # on the dispute that crosses the (scale-adjusted) threshold.
    # `live_dispute_count` already counts ONLY the current cohort —
    # acknowledge/reverse resolve every live dispute at ack time — so
    # the acknowledgement watermark must NOT be subtracted here:
    # doing so fired the re-review a full cohort late while the
    # settle gate blocked on the raw live count, and the scheduler
    # auto-voided with nobody paged.
    fresh_count = new_count
    fresh_before = fresh_count - 1

    if fresh_count > 0 and
         Moderation.dispute_review_required?(fresh_count, position_holders) and
         not Moderation.dispute_review_required?(fresh_before, position_holders) do
      EventBus.publish(%MarketsEvents.DisputeReReviewTriggered{
        market_id: market_id,
        dispute_count: new_count,
        threshold: threshold,
        timestamp: now
      })
    end

    :ok
  end

  defp resolve_subaddress_provider(opts) do
    opts
    |> Keyword.get(
      :subaddress_provider,
      Application.get_env(:perpwalk, :subaddress_provider, &MoneroFacade.create_subaddress/0)
    )
    |> normalize_provider()
  end

  # Accept either a 0-arity function or a `{Module, :function, args}`
  # MFA tuple (the form `config :perpwalk, :subaddress_provider, ...`
  # supports — application env can't hold function captures).
  defp normalize_provider(fun) when is_function(fun, 0), do: fun

  defp normalize_provider({mod, fun, args})
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    fn -> apply(mod, fun, args) end
  end

  defp allocate_subaddress(provider) when is_function(provider, 0) do
    case provider.() do
      {:ok, %{address: _, address_index: _}} = ok -> ok
      {:error, reason} -> {:error, {:subaddress_provider_failed, reason}}
      other -> {:error, {:subaddress_provider_failed, other}}
    end
  rescue
    e -> {:error, {:subaddress_provider_failed, e}}
  catch
    :exit, reason -> {:error, {:subaddress_provider_failed, reason}}
  end
end
