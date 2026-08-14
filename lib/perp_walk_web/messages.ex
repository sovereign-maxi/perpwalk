defmodule PerpWalkWeb.Messages do
  @moduledoc """
  Centralised user-facing strings. Every flash, banner, disabled-button
  tooltip, and validation error routes through here so the venue speaks
  with one voice and copy changes happen in one file.

  Functions of a single atom are preferred where the caller already has
  the reason atom; this keeps the call site cheap
  (`Messages.market_not_found()`) and the audit easy
  (`grep market_not_found` finds every site).

  Pure functions, no process state, no IO. Safe to call from any
  context: LiveView render, controllers, components.
  """

  alias PerpWalk.Markets.Facade, as: MarketsFacade

  alias PerpWalk.Monero.Address
  alias Phoenix.HTML

  # Helpers whose copy embeds inline `<strong>` / `<a>` tags return the
  # string via `HTML.raw/1` so HEEx call sites (`{Messages.foo()}`) render
  # the markup instead of escaping it. Interpolated values (amounts,
  # outcomes) come from `format_xmr` / atom-labels and carry no user
  # HTML — safe to inline. Do NOT expand raw() to helpers that concat
  # user-supplied text.

  # --- Operational ---

  @doc "Flash + disabled-button copy when `PerpWalk.Guards` refuses writes."
  def venue_halted, do: "Trading is currently halted. Please try again shortly"

  @doc """
  Banner body when the system is halted. Embeds the operator-supplied
  or auto-derived reason from `PerpWalk.Telemetry.Health.System.halt_reason/0`,
  HTML-escaped.
  """
  def venue_halted_banner(_reason),
    do: "Normal services should resume shortly. Existing positions are unaffected"

  # --- Auth ---

  @doc "Flash variant of \"log in\" — context-specific verb per call site."
  def login_required(:trade), do: "Log in to trade"
  def login_required(:vote), do: "Log in to vote"
  def login_required(:dispute), do: "Log in to dispute"
  def login_required(:resolve), do: "Log in to resolve"
  def login_required(:comment), do: "Log in to comment"
  def login_required(:portfolio), do: "Log in to see your portfolio"
  def login_required(:propose), do: "Log in to propose a market"

  @doc "Tooltip variant — sits on disabled-button `title=`."
  def login_tooltip(:trade), do: "Log in to trade"
  def login_tooltip(:vote), do: "Log in to vote"
  def login_tooltip(:dispute), do: "Log in to dispute"

  @doc "Login success flash with the user's handle interpolated."
  def logged_in_as(handle) when is_binary(handle), do: "Logged in as #{handle}"

  @doc "Logout success flash (controller flow)."
  def logged_out, do: "Logged out"

  @doc "Surfaced when a live session is revoked out-of-band."
  def session_revoked, do: "You have been logged out"

  @doc "Surfaced when the comment composer can't find a signing key."
  def comment_session_expired, do: "Session expired. Log in again"

  @doc "Empty / missing keyphrase on the login form."
  def access_code_required, do: "Enter your access code"

  @doc "Generic failure on the login form. Does not distinguish bad from oversized."
  def access_code_invalid, do: "Invalid access code"

  # --- Rate Limit ---

  @doc "Per-action rate-limit message. `kind` matches the bucket name."
  def rate_limited(:trade), do: "Too many trade attempts. Slow down"
  def rate_limited(:comment), do: "Too many comments. Slow down"
  def rate_limited(:vote), do: "Too many vote attempts"
  def rate_limited(:dispute), do: "Too many dispute attempts"
  def rate_limited(:resolution), do: "Too many resolution attempts"
  def rate_limited(:claim), do: "Too many claim attempts"
  def rate_limited(:create_market), do: "Too many market proposals. Try again later"

  # --- Lookup Failures ---

  @doc "Generic lookup failures, reused across services."
  def market_not_found, do: "Market not found"
  def position_not_found, do: "Position not found"
  def dispute_not_found, do: "Dispute not found"

  # --- Trading ---

  @doc "Surfaced when a trade lands on a market that's already past `:active`."
  def market_no_longer_active, do: "This market is no longer active"

  @doc "Flash when trading_open?/1 fails for a generic non-active market."
  def trading_closed_for_market, do: "Trading is closed for this market"

  @doc "Generic fallback when trading fails for an unmapped reason."
  def trade_failed_generic, do: "Could not place the trade. Try again"

  def insufficient_liquidity, do: "Insufficient liquidity on this side"
  def insufficient_liquidity_tooltip, do: "Insufficient liquidity on this side"

  @doc """
  Short uppercase label that replaces the XMR cost on a Buy button
  when the requested contract count would empty one side of the
  pool. The button stays sized for the cost-format glyphs so the
  short form keeps the layout from jumping when the ticker tips
  past available liquidity.
  """
  def no_liquidity_short, do: "NO LIQUIDITY"

  def creator_cannot_trade, do: "You created this market"
  def creator_cannot_trade_tooltip, do: "You created this market"

  def contracts_must_be_positive, do: "Contracts must be a positive integer"

  def deposit_provider_offline, do: "Deposit address service offline. Try again in a moment"

  def cannot_allocate_address, do: "Could not allocate a deposit address. Try again"

  @doc "Quote modal info flash when the lock window elapses without a deposit."
  def quote_expired_info, do: "Quote expired. Click Buy again to open a fresh one"

  @doc "Quote modal success flash on QuoteFilled."
  def position_confirmed, do: "Position confirmed"

  # --- Listing Vote ---

  @doc "Vote success flash. `direction` is `:up | :down` or its string form."
  def voted(direction) when direction in [:up, :down], do: "Voted #{direction}"
  def voted(direction) when is_binary(direction), do: "Voted #{direction}"

  def voting_closed, do: "Voting is closed for this market"
  def voting_closed_tooltip, do: "Voting closed"
  def creator_cannot_vote, do: "Can't vote on your own market"
  def created_this_market_tooltip, do: "You created this market"

  # --- Disputes ---

  def dispute_flagged, do: "Dispute flagged"
  def market_not_in_dispute_window, do: "This market is not in a dispute window"
  def creator_cannot_dispute, do: "You created this market"
  def creator_cannot_dispute_tooltip, do: "You created this market"
  def only_traders_can_dispute, do: "Only traders on this market can dispute"
  def only_traders_can_dispute_tooltip, do: "Only traders on this market can dispute"
  def already_disputed_tooltip, do: "You already disputed this market"

  # --- Resolution ---

  @doc "Short flash used by the portfolio resolution flow."
  def resolution_submitted_short, do: "Resolution submitted. Dispute window now open"

  @doc "Long flash used by the market-detail resolution flow. Names the chosen outcome."
  def resolution_submitted_long(outcome) when outcome in [:yes, :no, :void] do
    "Resolution submitted as #{outcome |> Atom.to_string() |> String.upcase()}. " <>
      "Dispute window is now open."
  end

  def only_creator_can_resolve, do: "Only the market creator can resolve this market"
  def only_creator_can_submit_resolution, do: "Only the market creator can submit a resolution"
  def market_not_awaiting_resolution, do: "This market is not awaiting resolution"
  def market_no_longer_resolvable, do: "This market can no longer be resolved"
  def invalid_outcome, do: "Invalid outcome"
  def invalid_outcome_for_creator, do: "Creators can only resolve YES or NO"
  def no_market_selected_for_resolution, do: "No market selected for resolution"

  @doc "Fallback flash when the service returns an unmapped resolution error."
  def resolution_failed(reason) when is_atom(reason),
    do: "Resolution failed: #{Atom.to_string(reason)}"

  # --- Claims ---

  @doc "Single success flash for all payout kinds (winnings, refund, LP return)."
  def claim_submitted, do: "Claim submitted. Payout will land in your wallet shortly"

  def position_not_payable, do: "This position is not payable"
  def dispute_not_refundable, do: "This dispute is not refundable yet"
  def refund_already_pending, do: "Refund already in flight"
  def payout_already_pending, do: "Already claimed. Payout is in flight"
  def dispute_not_owner, do: "This dispute belongs to another account"
  def lp_return_pending, do: "Liquidity return already in flight"
  def lp_already_returned, do: "Liquidity has already been returned for this market"

  def market_not_lp_returnable,
    do: "The market is not yet at a state where liquidity can be returned"

  def only_creator_for_lp_return, do: "Only the market creator can claim this liquidity return"
  def invalid_claim_state, do: "Invalid claim state. Try again"

  @doc "Fallback flash when the service returns an unmapped claim error."
  def claim_failed(reason) when is_atom(reason),
    do: "Claim failed: #{Atom.to_string(reason)}"

  def claim_failed_generic, do: "Claim failed. Try again"

  @doc "Tooltip on the 'needs review' pill — a payout held in :awaiting_operator."
  def payout_needs_review_tooltip,
    do:
      "Held for review. Notifications have been sent and this will be processed shortly — no action needed on your end."

  @doc "Tooltip on the 'under review' pill — a payout held in :settlement_unknown."
  def payout_under_review_tooltip,
    do:
      "Broadcast status is being reconciled. If the transaction went through you will see it shortly — no action needed on your end."

  # --- Destination Address ---

  def destination_required, do: "Enter a destination address"
  def destination_too_long, do: "Destination address is too long"
  def destination_invalid, do: "Destination address is invalid"

  @doc "Verbose validator hint used when the user pastes a non-Monero address."
  def destination_invalid_detail do
    "Invalid Monero address. Expected 95 chars (standard) or 106 chars (integrated), " <>
      "starts with #{Address.prefix_description()}, base58 alphabet (no 0/O/I/l)."
  end

  # --- Comments ---

  def comment_posted, do: "Comment posted"
  def comment_empty, do: "Write something before posting"
  def comment_too_long, do: "Comment is too long (5000 byte cap)"
  def comment_failed, do: "Could not post the comment. Try again"
  def comment_keyphrase_required, do: "Re-enter your keyphrase to sign comments"
  def comment_signer_offline, do: "Comment signer offline. Try again in a moment"

  # --- Market Creation ---

  def description_required, do: "Question is required"
  def description_too_short, do: "Question must be at least 12 characters"
  def description_too_long, do: "Question must be at most 200 characters"
  def criterion_required, do: "Resolution criterion is required"
  def criterion_too_short, do: "Resolution criterion must be at least 30 characters"
  def criterion_too_long, do: "Resolution criterion must be at most 1000 characters"
  def category_required, do: "Category is required"
  def category_invalid, do: "Invalid category"
  def expires_at_required, do: "Closing time is required"
  def expires_at_invalid, do: "Closing time is invalid"
  def expiry_in_past, do: "Closing time must be in the future"
  def market_already_exists, do: "A market with that question already exists"
  def market_proposed, do: "Market proposed. Once your deposit confirms, the listing vote opens"
  def create_market_failed_generic, do: "Could not create market. Try again"

  # --- Market Status (disabled tooltips) ---

  @doc "Tooltip on the Buy panel when the market isn't in `:active`."
  def market_status_tooltip(:pending), do: "Market is not active yet"
  def market_status_tooltip(:voided), do: "Market is voided"
  def market_status_tooltip(:rejected), do: "Market is rejected"
  def market_status_tooltip(:expired), do: "Market is awaiting resolution"
  def market_status_tooltip(:resolving), do: "Market is resolving"
  def market_status_tooltip(:settled), do: "Market is settled"
  def market_status_tooltip(_), do: "Market is not active"

  # --- Section Headings ---

  @doc "Heading above the odds chart on the market detail page."
  def market_consensus_label, do: "MARKET CONSENSUS"

  # --- Panel Titles ---

  def panel_account, do: "ACCOUNT"
  def panel_markets, do: "MARKETS"
  def panel_my_markets, do: "MY MARKETS"
  def panel_my_disputes, do: "MY DISPUTES"
  def panel_my_positions, do: "MY POSITIONS"
  def panel_leaderboard, do: "LEADERBOARD"
  def panel_calibration, do: "CALIBRATION"
  def panel_propose_market, do: "PROPOSE MARKET"

  # --- Stat-Row Labels ---

  def label_handle, do: "Handle"
  def label_account_id, do: "Account ID"

  # --- Action Affordances (buttons / links) ---

  def action_claim, do: "Claim"
  def action_clear, do: "CLEAR"
  # `panel_action_claim/0` is the uppercase variant for the
  # `.bp-panel-meta pw-panel-action` panel-header chrome. `action_claim/0`
  # stays mixed-case for the primary in-row buttons (Portfolio per-row
  # CLAIM).
  def panel_action_claim, do: "CLAIM"
  def action_cancel, do: "Cancel"
  def action_review, do: "Review"
  def action_back, do: "Back"
  def action_confirm, do: "Confirm"
  def action_resolve, do: "Resolve"
  def action_vote, do: "Vote"
  def action_dispute, do: "Dispute"
  def action_propose, do: "Propose"
  def action_buy, do: "Buy"
  def action_log_out, do: "Log out"
  def action_log_in, do: "Log in"
  def action_generate, do: "Generate access code"

  # --- Busy-State Labels (phx-disable-with) ---

  def busy_reviewing, do: "Reviewing…"
  def busy_queueing, do: "Queueing…"
  def busy_submitting, do: "Submitting…"
  def busy_voting, do: "Voting…"
  def busy_disputing, do: "Disputing…"
  def busy_resolving, do: "Resolving…"
  def busy_buying, do: "Buying…"
  def busy_generating, do: "Generating…"

  # --- Aria-Label / Title ---

  def aria_copy_destination, do: "Copy address to clipboard"
  def aria_copy_keyphrase, do: "Copy keyphrase to clipboard"

  # --- Table Column Headers ---

  def column_handle, do: "HANDLE"
  def column_signed_up, do: "SIGNED UP"
  def column_lifetime_revshare, do: "LIFETIME REVSHARE"
  def column_markets_settled, do: "MARKETS SETTLED"
  def column_last_active, do: "LAST ACTIVE"
  def column_market, do: "MARKET"
  def column_meta, do: "META"
  def column_pool, do: "POOL"
  def column_volume_24h, do: "VOL 24H"
  def column_trades_24h, do: "TRADES 24H"
  def column_time_to_close, do: "TIME TO CLOSE"
  def column_status, do: "STATUS"
  def column_action_txid, do: "ACTION / TXID"
  def column_side, do: "SIDE"
  def column_contracts, do: "CONTRACTS"
  def column_paid, do: "PAID"
  def column_stake, do: "STAKE"
  def column_refund, do: "REFUND"
  def column_rank, do: "RANK"
  def column_resolved, do: "RESOLVED"
  def column_score, do: "SCORE"
  def column_question, do: "QUESTION"

  # --- Empty States ---

  def empty_no_markets, do: "NO MARKETS YET"
  def empty_no_positions, do: "NO POSITIONS YET"
  def empty_no_disputes, do: "NO DISPUTES YET"
  def empty_no_settlements, do: "NO SETTLEMENTS YET"
  def empty_leaderboard, do: "NO RESOLVED MARKETS YET"

  # --- Paginator Labels ---

  def paginator_label_markets, do: "markets"
  def paginator_label_my_markets, do: "my markets"
  def paginator_label_my_disputes, do: "my disputes"
  def paginator_label_my_positions, do: "my positions"
  def paginator_label_leaderboard, do: "ranked accounts"

  # --- Modal Titles ---

  def modal_title_confirm_claim, do: "CONFIRM CLAIM"
  def modal_title_claim, do: "CLAIM"
  def modal_title_confirm, do: "CONFIRM"
  def modal_title_resolve, do: "RESOLVE MARKET"
  def modal_title_dispute, do: "DISPUTE RESOLUTION"

  # --- Form Fields ---

  def field_destination_label, do: "Monero destination address"
  def field_destination_placeholder, do: "4... (95-char Monero address)"

  # --- Confirm Modal Labels ---

  def confirm_label_amount, do: "AMOUNT"
  def confirm_label_destination, do: "DESTINATION"
  def confirm_label_market, do: "MARKET"

  # --- Warnings ---

  def warning_irreversible_lead, do: "This is irreversible"

  def warning_irreversible_body,
    do: "Once you confirm, a payout is queued to that address. Please double-check it"

  # --- Relative Time ---

  @doc """
  Formats a seconds-delta as a relative-time string. Returns `"—"` on
  `nil` so callers can pass through missing timestamps without
  branching.
  """
  def relative_time(nil), do: "—"
  def relative_time(seconds) when is_integer(seconds) and seconds < 60, do: "#{seconds}s ago"

  def relative_time(seconds) when is_integer(seconds) and seconds < 3600,
    do: "#{div(seconds, 60)}m ago"

  def relative_time(seconds) when is_integer(seconds) and seconds < 86_400,
    do: "#{div(seconds, 3600)}h ago"

  def relative_time(seconds) when is_integer(seconds), do: "#{div(seconds, 86_400)}d ago"

  # --- Brand Chrome ---

  def brand_name, do: "PERP WALK"
  def brand_tagline, do: "Markets Without Permission"

  # --- Page Titles ---

  def page_title_portfolio, do: "PERP WALK - PORTFOLIO"
  def page_title_markets, do: "PERP WALK - MARKETS"
  def page_title_leaderboard, do: "PERP WALK - LEADERBOARD"
  def page_title_market, do: "PERP WALK - MARKET"
  def page_title_market_not_found, do: "PERP WALK - MARKET NOT FOUND"
  def page_title_propose_market, do: "PERP WALK - PROPOSE MARKET"

  # --- Sr-Only Headings ---

  def sr_portfolio, do: "Portfolio"
  def sr_market_not_found, do: "Market not found"
  def sr_comment_content, do: "Comment content"

  # --- More Panel Titles ---

  def panel_market, do: "MARKET"
  def panel_market_not_found, do: "MARKET NOT FOUND"
  def panel_comments, do: "COMMENTS"
  def panel_stats, do: "STATS"
  def panel_initial_liquidity, do: "INITIAL LIQUIDITY"
  def panel_listing_vote, do: "LISTING VOTE"
  def panel_dispute, do: "DISPUTE"
  def panel_trade, do: "TRADE"
  def panel_submit_resolution, do: "SUBMIT RESOLUTION"
  def panel_awaiting_resolution, do: "AWAITING RESOLUTION"
  def panel_market_closed, do: "MARKET CLOSED"
  def panel_market_pending, do: "MARKET PENDING"

  # --- More Modal Titles ---

  def modal_title_buy_side(:yes), do: "BUY YES"
  def modal_title_buy_side(:no), do: "BUY NO"
  def modal_title_initial_liquidity, do: "INITIAL LIQUIDITY"

  def modal_title_refund_address(:yes), do: "BUY YES — REFUND ADDRESS"
  def modal_title_refund_address(:no), do: "BUY NO — REFUND ADDRESS"
  def modal_title_underpaid, do: "PAYMENT AMOUNT MISMATCH"

  # --- Welcome Modal (first-visit phishing defense + orientation) ---

  def modal_title_welcome, do: "PERP WALK"

  def welcome_on_host_prefix, do: "You are on:"

  def welcome_verify_instruction do
    "Verify this matches your address bar. Bookmark it. Phishing clones exist."
  end

  def welcome_description do
    "Private prediction market. XMR settlement. Tor-only. No KYC, no email, no recovery. " <>
      "Positions are hold-to-resolution. No sell-back."
  end

  def action_continue, do: "CONTINUE"

  # --- More Actions ---

  def action_post, do: "Post"
  def action_propose_market, do: "Propose Market"
  def action_vote_up, do: "Vote up"
  def action_vote_down, do: "Vote down"
  def action_resolve_yes, do: "Resolve YES"
  def action_resolve_no, do: "Resolve NO"
  def action_outcome_yes, do: "YES"
  def action_outcome_no, do: "NO"
  def action_disputed_cast, do: "Disputed"
  def action_hide, do: "Hide"
  def action_close, do: "Close"
  def action_confirm_and_send, do: "Confirm & send"
  def action_next, do: "Next"

  # --- Form-Field Labels (panel-internal) ---

  def label_resolution_criterion, do: "RESOLUTION CRITERION"
  def label_contracts, do: "CONTRACTS"
  def label_question, do: "QUESTION"
  def label_category, do: "CATEGORY"
  def label_betting_closes, do: "BETTING CLOSES"
  def label_deposit_xmr, do: "MARKET DEPOSIT (XMR)"
  def label_filter_markets_by_status, do: "Filter markets by status"

  # --- Side Pills ---

  def side_yes, do: "YES"
  def side_no, do: "NO"

  # --- More Column Headers ---

  def column_cost, do: "COST"
  def column_payout_if_wins, do: "PAYOUT IF WINS"
  def column_time, do: "TIME"
  def column_wins, do: "WINS"
  def column_losses, do: "LOSSES"
  def column_win_pct, do: "WIN RATE"

  # --- Stat-Row Labels (market detail) ---

  def stat_label_pool, do: "Pool"
  def stat_label_volume_24h, do: "Volume 24h"
  def stat_label_total_trades, do: "Total trades"
  def stat_label_expiry, do: "Expiry"
  def stat_label_resolution_deadline, do: "Resolution deadline"
  def stat_label_created, do: "Created"
  def stat_label_creator, do: "Creator"
  def stat_label_resolved, do: "Resolved"
  def stat_label_outcome, do: "Outcome"

  # --- Placeholders + Help Copy (market-create form) ---

  def placeholder_comment, do: "Share your thesis"
  def placeholder_question, do: "Will [specific event] happen by [specific date]?"

  def placeholder_resolution_criterion do
    "Resolves YES if [specific verifiable condition]. " <>
      "Resolves NO if [specific opposite condition]. " <>
      "Sources: [where the answer can be verified]."
  end

  def placeholder_em_dash, do: "—"

  def help_question do
    "Write a clear yes or no question with a verifiable resolution. " <>
      "Unclear or duplicate proposals get downvoted out, and a community rejection burns your deposit. " <>
      "Must be answerable as YES or NO."
  end

  def help_resolution_criterion do
    "Be specific about what counts as YES or NO " <>
      "and where the answer is verified. This is what voters and disputers will read."
  end

  def help_betting_closes do
    "After this time, no new positions can be opened. " <>
      "You'll have 24 hours to submit a resolution before the market auto-voids " <>
      "and every position refunds in full, including your deposit."
  end

  def help_deposit_xmr do
    min = format_xmr_short(MarketsFacade.min_deposit_piconeros())
    max = format_xmr_short(MarketsFacade.max_deposit_piconeros())
    step = format_xmr_short(MarketsFacade.deposit_step_piconeros())

    "Your deposit seeds the market's initial liquidity. The larger the deposit, the more volume the market can absorb before slippage becomes an issue. " <>
      "Between #{min} and #{max} XMR in #{step} XMR increments."
  end

  @doc """
  Renders piconeros as the shortest natural XMR number ("1", "0.01",
  "100", "0.0125") — no trailing zeros, no "XMR" suffix. Used inline
  in help copy that already names the unit, and to seed form inputs
  with config-driven defaults (e.g. the propose form's deposit field).
  """
  @spec format_xmr_short(pos_integer()) :: String.t()
  def format_xmr_short(piconeros) when is_integer(piconeros) and piconeros > 0 do
    divisor = 1_000_000_000_000
    whole = div(piconeros, divisor)
    frac = rem(piconeros, divisor)

    if frac == 0 do
      Integer.to_string(whole)
    else
      frac_str =
        frac
        |> Integer.to_string()
        |> String.pad_leading(12, "0")
        |> String.trim_trailing("0")

      "#{whole}.#{frac_str}"
    end
  end

  def deposit_invalid, do: "Deposit must be a whole positive number in XMR (e.g. 1, 2, 5, 10)"
  def deposit_not_unit_multiple, do: "Deposit must be a whole number of XMR"

  def deposit_not_step_multiple do
    step = format_xmr_short(MarketsFacade.deposit_step_piconeros())
    "Deposit must be a multiple of #{step} XMR."
  end

  def deposit_below_min(min_piconeros) do
    "Deposit is below the minimum of #{format_piconeros_xmr(min_piconeros)} XMR."
  end

  def deposit_above_max(max_piconeros) do
    "Deposit is above the maximum of #{format_piconeros_xmr(max_piconeros)} XMR."
  end

  # --- Refund Address (two-step trade modal) ---

  def label_refund_address, do: "REFUND ADDRESS"

  def refund_address_lead do
    "Enter a Monero address to receive any refund if this trade doesn't complete " <>
      "as expected. Use a fresh subaddress from your wallet for privacy."
  end

  def refund_address_required, do: "Refund address is required"
  def refund_address_invalid, do: "Invalid Monero address. Expected a valid mainnet address (starts with 4 or 8)"

  # --- Underpaid State ---

  def underpaid_headline, do: "Amount received was less than expected. No position was opened"

  def underpaid_label_sent, do: "AMOUNT SENT"
  def underpaid_label_required, do: "AMOUNT REQUIRED"
  def underpaid_label_shortfall, do: "SHORTFALL"
  def underpaid_label_refunding_to, do: "REFUNDING TO"

  defp format_piconeros_xmr(piconeros) when is_integer(piconeros) do
    xmr = piconeros / 1_000_000_000_000
    :erlang.float_to_binary(xmr, decimals: 2)
  end

  # --- Aria-Labels / Tooltip Titles ---

  def aria_filter_markets_by_category, do: "Filter markets by category"
  def aria_copy_market_deposit_address, do: "Copy market deposit address"
  def aria_copy_dispute_deposit_address, do: "Copy dispute deposit address"
  def aria_copy_side_deposit_address(:yes), do: "Copy yes deposit address"
  def aria_copy_side_deposit_address(:no), do: "Copy no deposit address"
  def aria_decrease_contracts, do: "Decrease contracts"
  def aria_increase_contracts, do: "Increase contracts"
  def aria_your_positions_on_market, do: "Your positions on this market"
  def aria_quote_locked_at, do: "Quote locked at"
  def aria_quote_expires_in, do: "Quote expires in"

  # --- More Empty States + Links ---

  def empty_no_comments, do: "NO COMMENTS YET"
  def empty_no_market_with_id(id), do: "No market with id #{id}"
  def empty_no_rankings, do: "NO RANKINGS YET"
  def link_back_to_markets, do: "← back to markets"
  def link_here, do: "here"
  def claim_from_portfolio_prefix, do: "Claim from"

  # --- Filter Labels ---

  def filter_all, do: "ALL"
  def status_filter_label(:all), do: "ALL"

  def status_filter_label(status) when is_atom(status),
    do: status |> Atom.to_string() |> String.upcase()

  # --- Payout-Status Pills (portfolio) ---

  def payout_status_paid_out, do: "paid out"
  def payout_status_submitted, do: "submitted"
  def payout_status_queued, do: "queued"
  def payout_status_needs_review, do: "needs review"
  def payout_status_under_review, do: "under review"

  # --- More Warnings ---

  def warning_resolve_honestly_lead, do: "Pick honestly"

  def warning_resolve_honestly_body do
    "A wrong resolution can be community-disputed and reversed — " <>
      "and it will tank your reputation. " <>
      "If the question is genuinely undecidable, " <>
      "let the deadline lapse and the market will auto-void."
  end

  # --- Long-Form Leads (market detail panels) ---

  def propose_intro do
    "This is where you stake a claim on what's worth asking. " <>
      "Your deposit is your commitment to a well-formed question; " <>
      "the community and the market decide whether you were right."
  end

  def initial_liquidity_lead(amount) do
    HTML.raw(
      "Send <strong>#{amount}</strong> to the address below. " <>
        "Your liquidity seeds the pool that price discovery runs against; " <>
        "you earn a share of every trade's spread and your liquidity returns " <>
        "at resolution minus any losses to winning traders."
    )
  end

  def initial_liquidity_modal_lead(amount) do
    HTML.raw(
      "Send <strong>#{amount}</strong> to the address below. " <>
        "Your liquidity seeds the market's pool and activates the listing window."
    )
  end

  def dispute_panel_lead(outcome, stake) do
    HTML.raw(
      "The creator submitted <strong>#{outcome}</strong> as the resolution. " <>
        "If you traded on this market and believe the outcome is wrong, " <>
        "stake <strong>#{stake}</strong> to dispute. " <>
        "Rejected disputes lose <strong>50%</strong> of their stake; " <>
        "upheld disputes are fully refunded."
    )
  end

  def trade_panel_lead(unit_size) do
    HTML.raw(
      "Each winning contract pays <strong>#{unit_size}</strong>; losing contracts pay 0. " <>
        "Prices reflect the current odds: " <>
        "Buy YES @ 0.50 means a coin-flip, @ 0.70 means the market thinks YES is likely."
    )
  end

  def trade_deposit_lead(amount),
    do: HTML.raw("Send <strong>#{amount}</strong> to the address below.")

  def dispute_deposit_lead(amount) do
    HTML.raw(
      "Send <strong>#{amount}</strong> to register your dispute. " <>
        "If the community upholds the original resolution, 50% of your stake is slashed. " <>
        "If they reverse it, you get a full refund."
    )
  end

  def buy_side_label(:yes, odds), do: "Buy YES @ #{odds}"
  def buy_side_label(:no, odds), do: "Buy NO @ #{odds}"

  def creator_resolution_lead(tail) do
    HTML.raw(
      "Trading is closed. As the market creator, you submit the outcome — " <>
        "<strong>YES</strong> or <strong>NO</strong>. " <>
        "A 24-hour dispute window opens after submission. #{tail}"
    )
  end

  def market_voided_lead, do: "This market was voided. Every open position has been refunded"
  def listing_window_closed, do: "Listing window closed"

  def listing_vote_lead_open(time) do
    "Activates in #{time} unless the community rejects it. " <>
      "A strong downvote consensus and the creator of this market will forfeit their liquidity."
  end

  def closed_market_settled_lead(outcome) do
    "This market settled #{outcome}. Winners can claim their payouts from /portfolio."
  end

  def closed_market_rejected_lead do
    "This market was community-rejected during the listing window — " <>
      "no positions were ever taken on it."
  end

  def closed_market_awaiting_deposit_lead do
    "This market is waiting for the creator's deposit to confirm on-chain before it goes live."
  end

  def closed_market_default_lead, do: "No actions available on this market"

  def creator_resolution_tail_overdue do
    "The resolution deadline has passed — " <>
      "the market will auto-void shortly if you don't submit a resolution."
  end

  def creator_resolution_tail_pre_deadline do
    "If the question is genuinely undecidable, " <>
      "do nothing and the market will auto-void after the resolution deadline."
  end

  def non_creator_resolution_lead_overdue(time) do
    "Trading is closed. The resolution deadline passed #{time}. " <>
      "The market will auto-void shortly if the creator doesn't submit a resolution, " <>
      "and every position will be refunded."
  end

  def non_creator_resolution_lead_pre_deadline(time) do
    "Trading is closed. The market creator has up to #{time} to submit a resolution. " <>
      "If they don't, the market auto-voids and every position is refunded."
  end

  # --- Auth (login + welcome) ---

  def auth_login_sr_heading, do: "Login or Register"
  def auth_login_panel_title, do: "Login / Register"
  def auth_keyphrase_label, do: "Access code"
  def auth_keyphrase_placeholder, do: "WORD-WORD-WORD-WORD-WORD-WORD"
  def auth_button_login, do: "Login"
  def auth_button_generate, do: "Generate"

  def auth_login_help_body do
    "PERP WALK uses a 6-word access code — paste yours to log in, or generate a new one. " <>
      "No email, no password, no recovery."
  end

  def auth_welcome_sr_heading, do: "Save your access code"
  def auth_welcome_panel_title, do: "Save your access code"
  def auth_welcome_help_handle_prefix, do: "You'll be known as"
  def auth_welcome_help_handle_suffix, do: "on PERP WALK"

  def auth_welcome_help_save_lead,
    do: "Write the access code down or paste it into a password manager"

  def auth_welcome_help_save_emphasis, do: "now"

  def auth_welcome_help_save_tail,
    do: "— it's shown exactly once and there is no recovery"

  def auth_welcome_continue_button, do: "I've saved it — continue"

  # --- Announcements ---

  def announcement_experimental_software do
    ~s(PERP WALK is experimental software. <strong>Use at your own risk.</strong> ) <>
      ~s(Start with small amounts. See <a href="https://perpwalk.is/protocol/#threat-model" ) <>
      ~s(target="_blank" rel="noopener">here</a> for more information.)
  end

  def announcement_venue_paused_lead, do: ~s(<strong>Trading is currently halted.</strong> )

  # --- Sub-Nav Stat Labels ---

  def sub_nav_label_markets, do: "Markets"
  def sub_nav_label_active, do: "Active"
  def sub_nav_label_pending, do: "Pending"
  def sub_nav_label_tvl, do: "TVL"

  # --- Page-Nav Dropdown Trigger (UPPERCASE) ---

  def nav_dropdown_label_markets, do: "MARKETS"
  def nav_dropdown_label_leaderboard, do: "LEADERBOARD"
  def nav_dropdown_label_portfolio, do: "PORTFOLIO"
  def nav_dropdown_label_profile, do: "PROFILE"
  def nav_dropdown_label_propose, do: "PROPOSE"
  def nav_dropdown_label_market, do: "MARKET"
  def nav_dropdown_label_menu, do: "MENU"

  # --- Page-Nav Dropdown Menu Items (mixed case) ---

  def nav_dropdown_item_propose, do: "Propose"
  def nav_dropdown_item_markets, do: "Markets"
  def nav_dropdown_item_leaderboard, do: "Leaderboard"
  def nav_dropdown_item_portfolio, do: "Portfolio"

  # --- Footer Pips ---

  def footer_pip_tor, do: "Tor"
  def footer_pip_monero, do: "Monero"
  def footer_pip_federation(online, total), do: "Federation #{online}/#{total}"

  # --- Market State Label (state_label/1, UPPERCASE pill) ---

  def market_state_pending, do: "PENDING"
  def market_state_active, do: "ACTIVE"
  def market_state_expired, do: "EXPIRED"
  def market_state_resolving, do: "RESOLVING"
  def market_state_settled, do: "SETTLED"
  def market_state_voided, do: "VOIDED"
  def market_state_rejected, do: "REJECTED"

  # --- Market Status (collapsed, status_label/1) ---

  def market_status_pending, do: "PENDING"
  def market_status_active, do: "ACTIVE"
  def market_status_closed, do: "CLOSED"
  def market_status_settled, do: "SETTLED"
  def market_status_rejected, do: "REJECTED"
  def market_status_voided, do: "VOIDED"

  # --- Position-Status Labels (lowercase) ---

  def position_status_open, do: "open"
  def position_status_winner, do: "winner"
  def position_status_loser, do: "loser"
  def position_status_refunded, do: "refunded"
  def position_status_paid_out, do: "paid out"

  # --- Dispute-Status Labels (lowercase) ---

  def dispute_status_awaiting_deposit, do: "awaiting deposit"
  def dispute_status_live, do: "live"
  def dispute_status_resolved_for, do: "rejected"
  def dispute_status_resolved_against, do: "upheld"
  def dispute_status_refunded_full, do: "refunded"
  def dispute_status_refunded_partial, do: "refunded (slashed)"

  # --- Time_until/2 Unitised Relative Time ---

  def time_now, do: "now"
  def time_days_ago(n), do: "#{n}d ago"
  def time_hours_ago(n), do: "#{n}h ago"
  def time_minutes_ago(n), do: "#{n}m ago"
  def time_seconds_ago(n), do: "#{n}s ago"
  def time_seconds(n), do: "#{n}s"
  def time_minutes(n), do: "#{n}m"
  def time_hours_minutes(h, m), do: "#{h}h #{m}m"
  def time_days(n), do: "#{n}d"

  # --- Category Labels (uppercase pill) ---

  def category_politics, do: "POLITICS"
  def category_crypto, do: "CRYPTO"
  def category_finance, do: "FINANCE"
  def category_sports, do: "SPORTS"
  def category_entertainment, do: "ENT"
  def category_science_tech, do: "SCI/TECH"
  def category_culture, do: "CULTURE"
end
