defmodule PerpWalk.Markets.Facade do
  @moduledoc """
  Published Language facade for the Markets bounded context.

  The only legal cross-domain entry point. Returns plain structs
  from the Markets domain (`Market.t()`, `Position.t()`, `Vote.t()`)
  and `{:ok, _} | {:error, atom()}` tuples — never service-internal
  state.
  """

  alias PerpWalk.Markets.{
    AMM,
    Dispute,
    History,
    Market,
    Moderation,
    Position,
    Quote,
    Status,
    Store,
    Vote
  }

  alias PerpWalk.Markets.Comments.{Composer, Inbox}
  alias PerpWalk.Markets.Federation.Ledger, as: FederationLedger
  alias PerpWalk.Markets.Leaderboard
  alias PerpWalk.Markets.Services.{Cashier, Disputer, Maker, Resolver, Trader, Voter}

  # --- Commands ---

  @doc "See `PerpWalk.Markets.Services.Maker.create_market/1`."
  @spec create_market(keyword()) :: {:ok, Market.t()} | {:error, term()}
  defdelegate create_market(opts), to: Maker

  @doc "See `PerpWalk.Markets.Services.Maker.confirm_deposit/1`."
  @spec confirm_market_deposit(binary()) :: {:ok, Market.t()} | {:error, atom()}
  defdelegate confirm_market_deposit(market_id), to: Maker, as: :confirm_deposit

  @doc "Configured floor for creator deposits (piconeros)."
  @spec min_deposit_piconeros() :: pos_integer()
  defdelegate min_deposit_piconeros(), to: Maker

  @doc "Configured ceiling for creator deposits (piconeros)."
  @spec max_deposit_piconeros() :: pos_integer()
  defdelegate max_deposit_piconeros(), to: Maker

  @doc "Configured AMM unit size — deposits must be exact multiples (piconeros)."
  @spec unit_size_piconeros() :: pos_integer()
  defdelegate unit_size_piconeros(), to: Maker

  @doc "Configured form-facing deposit granularity (piconeros). Independent of unit_size."
  @spec deposit_step_piconeros() :: pos_integer()
  defdelegate deposit_step_piconeros(), to: Maker

  @doc "See `PerpWalk.Markets.Services.Voter.cast_vote/3`."
  @spec cast_vote(binary(), binary(), :up | :down) ::
          {:ok, Market.t()} | {:error, atom()}
  defdelegate cast_vote(account_id, market_id, direction), to: Voter

  @doc """
  Creates a pending Quote with a fresh deposit subaddress. The
  position only materialises once the deposit confirms via
  `fill_quote/2`. See `PerpWalk.Markets.Services.Trader.create_quote/5`
  for opts.
  """
  @spec create_quote(binary(), binary(), AMM.side(), pos_integer()) ::
          {:ok, Quote.t()} | {:error, term()}
  @spec create_quote(binary(), binary(), AMM.side(), pos_integer(), keyword()) ::
          {:ok, Quote.t()} | {:error, term()}
  def create_quote(account_id, market_id, side, contracts, opts \\ []),
    do: Trader.create_quote(account_id, market_id, side, contracts, opts)

  @doc """
  Fills a Quote into a Position once its deposit has confirmed on-chain.
  Called by the Monero deposit poller. See
  `PerpWalk.Markets.Services.Trader.fill_quote/2`.
  """
  @spec fill_quote(binary()) :: {:ok, Position.t()} | {:error, term()}
  @spec fill_quote(binary(), keyword()) :: {:ok, Position.t()} | {:error, term()}
  def fill_quote(quote_id, opts \\ []), do: Trader.fill_quote(quote_id, opts)

  @doc """
  Validates a settled-winner or refunded position and enqueues a
  Payout with the federation. The request is processed
  asynchronously by the federation signer.

  Requires `claimant_account_id` — the authenticated account
  attempting the claim. Refuses with `:not_owner` if the position
  doesn't belong to the claimant.

  Returns the Payout synchronously. Position transitions to
  `:paid_out` only when the federation completes signing and
  submits the on-chain transaction.

  See `PerpWalk.Markets.Services.Cashier.claim_payout/3` and
  `PerpWalk.Federation.Facade.enqueue_payout/3`.
  """
  @spec claim_payout(binary(), binary(), String.t()) ::
          {:ok, PerpWalk.Federation.Payout.t()} | {:error, term()}
  def claim_payout(position_id, claimant_account_id, destination),
    do: Cashier.claim_payout(position_id, claimant_account_id, destination)

  @doc """
  Marks a position `:paid_out` once the Federation has submitted
  the payout on-chain. Single entry point used by
  `Federation.Signer` after multisig submission — Markets owns
  the Position.pay_out transition and the WAL-backed write.

  See `PerpWalk.Markets.Services.Cashier.mark_paid_out/2`.
  """
  @spec mark_position_paid_out(binary(), String.t()) ::
          {:ok, Position.t()}
          | {:error, :position_not_found | :invalid_transition | :already_paid_out | term()}
  def mark_position_paid_out(position_id, txid),
    do: Cashier.mark_paid_out(position_id, txid)

  @doc """
  Validates a resolved dispute and enqueues a refund Payout. See
  `PerpWalk.Markets.Services.Cashier.claim_dispute_refund/3`.
  """
  @spec claim_dispute_refund(binary(), binary(), String.t()) ::
          {:ok, PerpWalk.Federation.Payout.t()} | {:error, term()}
  defdelegate claim_dispute_refund(account_id, market_id, destination), to: Cashier

  @doc """
  Marks a dispute `:refunded_full` / `:refunded_partial` once the
  Federation has submitted the refund on-chain. Single entry point
  for `Federation.Signer`'s dispute-refund finalisation. See
  `PerpWalk.Markets.Services.Cashier.mark_dispute_refunded/2`.
  """
  @spec mark_dispute_refunded(binary(), binary()) ::
          {:ok, Dispute.t()}
          | {:error, :dispute_not_found | :invalid_transition | term()}
  defdelegate mark_dispute_refunded(account_id, market_id), to: Cashier

  @doc """
  Enqueues a creator liquidity return on a settled or voided market.
  See `PerpWalk.Markets.Services.Cashier.claim_creator_lp_return/3`.
  """
  @spec claim_creator_lp_return(binary(), binary(), String.t()) ::
          {:ok, PerpWalk.Federation.Payout.t()} | {:error, term()}
  defdelegate claim_creator_lp_return(account_id, market_id, destination), to: Cashier

  @doc """
  Deterministic LP return amount in piconeros for a settled or
  voided market. Returns 0 for non-terminal statuses. Used by the
  portfolio UI to render the claim preview.
  """
  @spec creator_lp_return_amount(PerpWalk.Markets.Market.t()) :: non_neg_integer()
  defdelegate creator_lp_return_amount(market), to: Cashier, as: :lp_return_amount

  @doc """
  Stamps a market's `creator_lp_paid_out_at` after the Federation
  has submitted the LP return on-chain. Single entry point for
  `Federation.Signer`'s creator-LP finalisation. See
  `PerpWalk.Markets.Services.Cashier.mark_creator_lp_returned/2`.
  """
  @spec mark_creator_lp_returned(binary(), String.t()) ::
          {:ok, Market.t()}
          | {:error, :market_not_found | :already_paid_out | term()}
  defdelegate mark_creator_lp_returned(market_id, txid), to: Cashier

  @doc """
  Applies a list of WAL entries to the local Markets ETS tables.
  Storage-domain entry point used by `Storage.Replicator`; in the
  symmetric bi-directional model every node applies entries from
  its peers. Fans out to `Store` (markets, positions, votes,
  quotes, disputes) and `Comments.Inbox` (Nostr comment cache);
  each filters for its own WAL types.
  """
  @spec replicate_entries([Locker.WAL.Entry.t()]) :: :ok
  def replicate_entries(entries) when is_list(entries) do
    Store.replicate_entries(entries)
    Inbox.replicate_entries(entries)
    :ok
  end

  @doc "Transitions a `:pending` market to `:active`."
  @spec activate_market(binary()) :: {:ok, Market.t()} | {:error, atom()}
  defdelegate activate_market(market_id), to: Resolver, as: :activate

  @doc "Transitions an `:active` market to `:expired`."
  @spec expire_market(binary()) :: {:ok, Market.t()} | {:error, atom()}
  defdelegate expire_market(market_id), to: Resolver, as: :expire

  @doc """
  Creator submits a resolution outcome on an `:expired` market.
  Auth-checked — `account_id` must be the market's creator. Outcomes
  are constrained to `:yes | :no`; `:void` is operator-only via
  `override_resolution/2`. A creator who can't resolve should let
  the deadline lapse — Scheduler auto-voids as `:creator_no_show`.
  """
  @spec submit_resolution(binary(), binary(), :yes | :no) ::
          {:ok, Market.t()} | {:error, atom()}
  defdelegate submit_resolution(account_id, market_id, outcome),
    to: Resolver,
    as: :submit_resolution_by_creator

  @doc """
  Operator-only override of resolution submission. Bypasses the
  creator auth check — used by `Markets.Console` when the creator
  is unavailable or pulled a houdini.
  """
  @spec override_resolution(binary(), Market.outcome()) ::
          {:ok, Market.t()} | {:error, atom()}
  defdelegate override_resolution(market_id, outcome),
    to: Resolver,
    as: :submit_resolution

  @doc "Reverses a `:resolving` market's outcome inside the dispute window."
  @spec reverse_resolution(binary(), Market.outcome()) ::
          {:ok, Market.t()} | {:error, atom()}
  defdelegate reverse_resolution(market_id, outcome), to: Resolver

  @doc """
  Starts a community dispute against a `:resolving` market. Allocates
  a Monero subaddress, persists the dispute as `:awaiting_deposit`,
  returns the dispute (with deposit instructions) to the caller.
  See `Disputer.start_dispute/3`.
  """
  @spec start_dispute(binary(), binary()) ::
          {:ok, PerpWalk.Markets.Dispute.t()} | {:error, term()}
  defdelegate start_dispute(account_id, market_id), to: Disputer

  @doc """
  Marks a dispute's deposit as confirmed on-chain. Idempotent.
  Used by `Monero.Poller`. See `Disputer.confirm_deposit/2`.
  """
  @spec confirm_dispute_deposit(binary(), binary()) ::
          {:ok, PerpWalk.Markets.Dispute.t()} | {:error, atom()}
  defdelegate confirm_dispute_deposit(account_id, market_id),
    to: Disputer,
    as: :confirm_deposit

  @doc """
  Cancels a pending (`:awaiting_deposit`) dispute. Called from the
  market detail LiveView when the dispute modal closes without
  funding so the row doesn't linger in the user's portfolio.
  See `Disputer.cancel_pending/2`.
  """
  @spec cancel_dispute(binary(), binary()) ::
          {:ok, PerpWalk.Markets.Dispute.t()}
          | {:error, :dispute_not_found | :invalid_transition | term()}
  defdelegate cancel_dispute(account_id, market_id), to: Disputer, as: :cancel_pending

  @doc "Records guardian acknowledgement of current disputes (clears settle gate)."
  @spec acknowledge_disputes(binary()) :: {:ok, Market.t()} | {:error, atom()}
  defdelegate acknowledge_disputes(market_id), to: Resolver

  @doc "Settles `:resolving` market — pays winners, consumes losers, atomic."
  @spec settle_market(binary()) :: {:ok, Market.t()} | {:error, atom()}
  defdelegate settle_market(market_id), to: Resolver, as: :settle

  @doc "Voids a market — refunds every open position, atomic."
  @spec void_market(binary()) :: {:ok, Market.t()} | {:error, atom()}
  defdelegate void_market(market_id), to: Resolver, as: :void

  # --- Reads (delegate to Store) ---

  @doc "Fetches a market by id."
  @spec get_market(binary()) :: {:ok, Market.t()} | {:error, :not_found}
  defdelegate get_market(id), to: Store

  @doc "All known markets."
  @spec list_markets() :: [Market.t()]
  defdelegate list_markets(), to: Store

  @doc "Markets filtered by lifecycle status."
  @spec list_markets_by_status(Market.status()) :: [Market.t()]
  defdelegate list_markets_by_status(status), to: Store

  @doc "Markets filtered by category."
  @spec list_markets_by_category(atom()) :: [Market.t()]
  defdelegate list_markets_by_category(category), to: Store

  @doc "Markets created by a given account, across all statuses."
  @spec list_markets_for_creator(binary()) :: [Market.t()]
  defdelegate list_markets_for_creator(account_id), to: Store

  @doc "Fetches a position by id."
  @spec get_position(binary()) :: {:ok, Position.t()} | {:error, :not_found}
  defdelegate get_position(id), to: Store

  @doc "All positions on a market (any status)."
  @spec list_positions_for_market(binary()) :: [Position.t()]
  defdelegate list_positions_for_market(market_id), to: Store

  @doc """
  Count of distinct account_ids holding positions on this market.
  Used as the trader-population denominator for the scale-invariant
  dispute review threshold. See `Moderation.scaled_threshold/1`.
  """
  @spec count_distinct_position_holders(binary()) :: non_neg_integer()
  defdelegate count_distinct_position_holders(market_id), to: Store

  @doc """
  All positions across every market. One ETS pass — prefer this
  over iterating markets and calling `list_positions_for_market/1`
  per market when callers need the complete set (sim Reporter,
  Lifecycle invariant, etc.).
  """
  @spec list_all_positions() :: [Position.t()]
  defdelegate list_all_positions(), to: Store, as: :list_positions

  @doc "All positions held by an account."
  @spec list_positions_for_account(binary()) :: [Position.t()]
  defdelegate list_positions_for_account(account_id), to: Store

  @doc "Positions filtered by lifecycle status."
  @spec list_positions_by_status(Position.status()) :: [Position.t()]
  defdelegate list_positions_by_status(status), to: Store

  @doc "All votes cast on a market."
  @spec list_votes_for_market(binary()) :: [Vote.t()]
  defdelegate list_votes_for_market(market_id), to: Store

  @doc "True if `account_id` already has a vote on `market_id`."
  @spec has_voted?(binary(), binary()) :: boolean()
  defdelegate has_voted?(account_id, market_id), to: Store

  @doc "Fetches a dispute by `(account_id, market_id)`."
  @spec get_dispute(binary(), binary()) :: {:ok, Dispute.t()} | {:error, :not_found}
  defdelegate get_dispute(account_id, market_id), to: Store

  @doc "Every dispute, all statuses, across all markets."
  @spec list_disputes() :: [Dispute.t()]
  defdelegate list_disputes(), to: Store

  @doc "All disputes flagged against a market's resolution."
  @spec list_disputes_for_market(binary()) :: [Dispute.t()]
  defdelegate list_disputes_for_market(market_id), to: Store

  @doc "All disputes filed by an account, across markets."
  @spec list_disputes_for_account(binary()) :: [Dispute.t()]
  defdelegate list_disputes_for_account(account_id), to: Store

  @doc "Disputes filtered by lifecycle status."
  @spec list_disputes_by_status(Dispute.status()) :: [Dispute.t()]
  defdelegate list_disputes_by_status(status), to: Store

  @doc "True if `account_id` already flagged a dispute on `market_id`."
  @spec has_flagged?(binary(), binary()) :: boolean()
  defdelegate has_flagged?(account_id, market_id), to: Store

  @doc "Number of disputes currently flagged on the market (any status)."
  @spec dispute_count(binary()) :: non_neg_integer()
  defdelegate dispute_count(market_id), to: Store

  @doc """
  Number of `:live` disputes (deposit confirmed) on the market.
  Threshold logic uses this — unfunded disputes are noise.
  """
  @spec live_dispute_count(binary()) :: non_neg_integer()
  defdelegate live_dispute_count(market_id), to: Store

  @doc "Fetches a pending quote by id."
  @spec get_quote(binary()) :: {:ok, Quote.t()} | {:error, :not_found}
  defdelegate get_quote(id), to: Store

  @doc """
  O(1) lookup of a Quote / Dispute / Market by the Monero
  subaddress index allocated for its deposit. Used by
  `Monero.Poller.lookup_subaddress/1` to attribute incoming
  deposits without scanning the full entity table on every poll.
  """
  @spec get_quote_by_subaddress(non_neg_integer()) :: {:ok, Quote.t()} | {:error, :not_found}
  defdelegate get_quote_by_subaddress(subaddress_index), to: Store

  @spec get_dispute_by_subaddress(non_neg_integer()) :: {:ok, Dispute.t()} | {:error, :not_found}
  defdelegate get_dispute_by_subaddress(subaddress_index), to: Store

  @spec get_market_by_subaddress(non_neg_integer()) :: {:ok, Market.t()} | {:error, :not_found}
  defdelegate get_market_by_subaddress(subaddress_index), to: Store

  @doc "All pending quotes (any market, any account)."
  @spec list_quotes() :: [Quote.t()]
  defdelegate list_quotes(), to: Store

  @doc "All pending quotes on a market."
  @spec list_quotes_for_market(binary()) :: [Quote.t()]
  defdelegate list_quotes_for_market(market_id), to: Store

  @doc "All pending quotes for an account."
  @spec list_quotes_for_account(binary()) :: [Quote.t()]
  defdelegate list_quotes_for_account(account_id), to: Store

  @doc "True if a Quote has elapsed its expiry as of `now`."
  @spec quote_expired?(Quote.t(), DateTime.t()) :: boolean()
  defdelegate quote_expired?(quote, now), to: Quote, as: :expired?

  @doc """
  Quotes whose `expires_at` is at-or-before `now`. Backed by the
  `QuotesByExpiry` ordered-set index so the scheduler tick pops
  expired entries in O(K) instead of full-scanning every quote.
  """
  @spec list_quotes_expired(DateTime.t()) :: [Quote.t()]
  defdelegate list_quotes_expired(now), to: Store

  @doc "Time-series of YES probability for `market_id` derived from the WAL."
  @spec odds_history(binary()) ::
          {:ok, [PerpWalk.Markets.History.odds_point()]} | {:error, term()}
  defdelegate odds_history(market_id), to: History

  # --- Status Predicates ---
  #
  # Semantic questions about a Market status atom. Web layers use
  # these instead of pattern-matching on raw atoms so the
  # bucketing stays consistent with the state machine.

  @doc "See `PerpWalk.Markets.Status.trading?/1`."
  @spec status_trading?(Market.status()) :: boolean()
  defdelegate status_trading?(status), to: Status, as: :trading?

  @doc "See `PerpWalk.Markets.Status.listing_window?/1`."
  @spec status_listing_window?(Market.status()) :: boolean()
  defdelegate status_listing_window?(status), to: Status, as: :listing_window?

  @doc "See `PerpWalk.Markets.Status.awaiting_creator_resolution?/1`."
  @spec status_awaiting_creator_resolution?(Market.status()) :: boolean()
  defdelegate status_awaiting_creator_resolution?(status),
    to: Status,
    as: :awaiting_creator_resolution?

  @doc "See `PerpWalk.Markets.Status.in_dispute_window?/1`."
  @spec status_in_dispute_window?(Market.status()) :: boolean()
  defdelegate status_in_dispute_window?(status), to: Status, as: :in_dispute_window?

  @doc "See `PerpWalk.Markets.Status.awaiting_operator_action?/1`."
  @spec status_awaiting_operator_action?(Market.status()) :: boolean()
  defdelegate status_awaiting_operator_action?(status),
    to: Status,
    as: :awaiting_operator_action?

  @doc "See `PerpWalk.Markets.Status.terminal?/1`."
  @spec status_terminal?(Market.status()) :: boolean()
  defdelegate status_terminal?(status), to: Status, as: :terminal?

  @doc "See `PerpWalk.Markets.Status.in_flight?/1`."
  @spec status_in_flight?(Market.status()) :: boolean()
  defdelegate status_in_flight?(status), to: Status, as: :in_flight?

  # --- Display Projections ---

  @doc """
  Payout in piconeros for `position` against a market with the
  given `unit_size`. Display-only — equals `position.contracts *
  unit_size` for winning/refunded positions.
  """
  @spec position_payout(Position.t(), pos_integer()) :: non_neg_integer()
  defdelegate position_payout(position, unit_size), to: Position, as: :payout

  @doc "Mid-market YES/NO probability tuple as `{numerator, denominator}` integers."
  @spec mid_probability(AMM.t(), AMM.side()) :: {non_neg_integer(), pos_integer()}
  defdelegate mid_probability(pool, side), to: AMM

  @doc "AMM constant-product invariant `yes * no` for `pool`."
  @spec pool_invariant(AMM.t()) :: non_neg_integer()
  defdelegate pool_invariant(pool), to: AMM, as: :invariant

  @doc "AMM quote breakdown for a contract count on the given side. See `AMM.quote_breakdown/3`."
  @spec quote_breakdown(AMM.t(), AMM.side(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  defdelegate quote_breakdown(pool, side, contracts), to: AMM

  @doc "Converts a user-facing contract count to AMM subunits. See `AMM.to_subunits/1`."
  @spec contracts_to_subunits(non_neg_integer()) :: non_neg_integer()
  defdelegate contracts_to_subunits(contracts), to: AMM, as: :to_subunits

  @doc "Converts AMM subunit cost to piconeros for a given unit size. See `AMM.cost_to_piconeros/2`."
  @spec subunits_to_piconeros(non_neg_integer(), pos_integer()) :: non_neg_integer()
  defdelegate subunits_to_piconeros(subunits, unit_size), to: AMM, as: :cost_to_piconeros

  # --- Leaderboard ---

  @doc "Computes the trader leaderboard. See `Leaderboard.compute/1`."
  @spec compute_leaderboard(keyword()) :: [map()]
  defdelegate compute_leaderboard(opts \\ []), to: Leaderboard, as: :compute

  # --- Comments (web-facing) ---

  @doc "Publishes a market comment to Nostr. See `Comments.Composer.publish/4`."
  @spec publish_comment(binary(), binary(), binary(), String.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate publish_comment(seckey, venue_pubkey_hex, market_id, content),
    to: Composer,
    as: :publish

  @doc "Lists comments for a market. See `Comments.Inbox.list_for_market/1`."
  @spec list_comments_for_market(binary()) :: [map()]
  defdelegate list_comments_for_market(market_id), to: Inbox, as: :list_for_market

  @doc """
  Federation-revenue breakdown across slashed dispute stakes and
  forfeited creator deposits. See `PerpWalk.Markets.Federation.Ledger.breakdown/0`.
  Now O(1) — backed by incremental counters in the store rather
  than per-call index folds.
  """
  @spec federation_ledger() :: FederationLedger.breakdown()
  defdelegate federation_ledger(), to: FederationLedger, as: :breakdown

  @doc """
  Dispute stake required to file on a market — fixed percentage
  (default 10%) of the creator's initial liquidity. Display-only;
  the Disputer recomputes on `start_dispute/2` so a stale UI read
  can't underpay.
  """
  @spec dispute_stake_for_market(pos_integer()) :: pos_integer()
  defdelegate dispute_stake_for_market(deposit_amount), to: Moderation

  # --- Comments ---

  @doc """
  Cross-domain entry point for ingesting a verified Nostr comment.
  Called by `PerpWalk.Nostr.Relay.Subscriber` after BIP-340 sig
  verification and topic-tag extraction. Markets owns the inbox
  (dedup by event_id, per-market index, `CommentReceived` emission);
  the Nostr substrate just delivers the verified payload here.
  """
  @spec ingest_comment(map()) ::
          {:ok, :new | :duplicate | :unknown_market | :oversized | :inbox_full}
          | {:error, term()}
  defdelegate ingest_comment(attrs), to: Inbox, as: :ingest
end
