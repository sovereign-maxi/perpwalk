defmodule PerpWalkWeb.Live.Helpers do
  @moduledoc """
  Display helpers for the Markets LiveView surfaces — render-time
  chrome (header/footer), tag derivation, AMM-derived odds
  formatting, XMR-amount formatting, and relative time formatting
  for both past and future timestamps.

  Pure functions only. No process state, no IO.
  """

  use PerpWalkWeb, :html

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents
  alias PerpWalk.Events.Telemetry, as: TelemetryEvents
  alias PerpWalk.Federation.Facade, as: FederationFacade
  alias PerpWalk.Guards
  alias PerpWalk.Markets.{AMM, Facade, Market, Position}
  alias PerpWalk.Telemetry.Facade, as: TelemetryFacade
  alias PerpWalkWeb.Messages

  # --- App Chrome (header / footer wrappers) ---

  @doc """
  Standard PERP WALK app header — used at the top of every public
  LiveView.

  Brand + tagline on the left, auth control (Log in / Log out) on
  the right. Navigation between pages happens through the dropdown
  on `app_sub_nav/1` — keeping the top nav clean and putting
  navigation next to the viewer's handle (where the eye already
  goes for identity context).

  `current_page` is still accepted (and threaded into `app_sub_nav`
  via the caller) so the dropdown can highlight the current page
  and elide it from the menu.
  """
  attr(:current_handle, :string, default: nil)
  attr(:current_page, :atom, default: :markets)

  def app_header(assigns) do
    ~H"""
    <.header
      logo_text={Messages.brand_name()}
      logo_href="/markets"
      tagline={Messages.brand_tagline()}
    >
      <:nav>
        <div class="bp-auth-nav">
          <%= if @current_handle do %>
            <form action="/auth/logout" method="post" class="bp-auth-form">
              <input
                type="hidden"
                name="_csrf_token"
                value={Phoenix.Controller.get_csrf_token()}
              />
              <button type="submit" class="bp-btn bp-btn-primary bp-btn-sm">
                {Messages.action_log_out()}
              </button>
            </form>
          <% else %>
            <a href="/auth/login" class="bp-btn bp-btn-primary bp-btn-sm">{Messages.action_log_in()}</a>
          <% end %>
        </div>
      </:nav>
    </.header>
    """
  end

  @doc """
  Standard PERP WALK sub-nav — shown on every public page so the
  Markets stats are always visible from anywhere on the site
  (including auth pages).

  Hosts the page-nav dropdown on the left edge (acts as a
  breadcrumb + nav: the trigger label is the current page name, so
  the viewer always knows where they are without reading the URL),
  followed by `@handle` for logged-in viewers. Operational stats
  stay flush right.

  Dropdown contents (each elides the current page so the menu only
  shows what the viewer can navigate *to*):

    * Logged out → MARKETS, LEADERBOARD
    * Logged in  → PROPOSE, MARKETS, LEADERBOARD, PORTFOLIO

  Toggle uses `Phoenix.LiveView.JS.toggle/1` to flip the `hidden`
  attribute on the menu — no server round-trip. `phx-click-away`
  hides the menu when the user clicks anywhere outside the trigger.
  """
  attr(:current_handle, :string, default: nil)
  attr(:current_page, :atom, default: :markets)
  attr(:stats, :list, default: nil)

  def app_sub_nav(assigns) do
    stats = assigns.stats || default_stats()

    assigns =
      assigns
      |> assign(:stats, stats)
      |> assign(:dropdown_label, dropdown_label(assigns.current_page))
      |> assign(:dropdown_items, dropdown_items(assigns.current_page, assigns.current_handle))

    ~H"""
    <.sub_nav stats={@stats}>
      <.nav_dropdown label={@dropdown_label} items={@dropdown_items} />
      <span :if={@current_handle} class="bp-auth-handle">@{@current_handle}</span>
    </.sub_nav>
    """
  end

  defp default_stats do
    markets = Facade.list_markets()
    counts = sub_nav_counts(markets)
    pool_xmr = sub_nav_pool_xmr(markets)

    [
      %{label: Messages.sub_nav_label_markets(), value: "#{counts.total}"},
      %{label: Messages.sub_nav_label_active(), value: "#{counts.active}"},
      %{label: Messages.sub_nav_label_pending(), value: "#{counts.pending}"},
      %{label: Messages.sub_nav_label_tvl(), value: pool_xmr, class: "accent", right: true}
    ]
  end

  # Map `current_page` atoms to the trigger label. Keep these short
  # — they're the breadcrumb the viewer reads at a glance. New
  # routes should be added here AND to `dropdown_items/2` below.
  defp dropdown_label(:markets), do: Messages.nav_dropdown_label_markets()
  defp dropdown_label(:leaderboard), do: Messages.nav_dropdown_label_leaderboard()
  defp dropdown_label(:portfolio), do: Messages.nav_dropdown_label_portfolio()
  defp dropdown_label(:profile), do: Messages.nav_dropdown_label_profile()
  defp dropdown_label(:market_create), do: Messages.nav_dropdown_label_propose()
  defp dropdown_label(:market_detail), do: Messages.nav_dropdown_label_market()
  defp dropdown_label(_), do: Messages.nav_dropdown_label_menu()

  # Returns the list of `{label, href}` pairs to render in the
  # dropdown for the given viewer. The current page is elided so
  # the menu only shows navigation targets. Logged-out viewers
  # don't see PROPOSE or PORTFOLIO — both require an account.
  defp dropdown_items(current_page, current_handle) do
    items = [
      {:market_create, Messages.nav_dropdown_item_propose(), "/markets/new", _logged_in_only = true},
      {:markets, Messages.nav_dropdown_item_markets(), "/markets", false},
      {:leaderboard, Messages.nav_dropdown_item_leaderboard(), "/leaderboard", false},
      {:portfolio, Messages.nav_dropdown_item_portfolio(), "/portfolio", true}
    ]

    items
    |> Enum.reject(fn {page, _, _, logged_in_only} ->
      page == current_page or (logged_in_only and is_nil(current_handle))
    end)
    |> Enum.map(fn {_page, label, href, _} -> {label, href} end)
  end

  # `:awaiting_deposit` and `:pending` both render as PENDING in the
  # state pill, so bucket them together for the header stat.
  defp sub_nav_counts(markets) do
    Enum.reduce(markets, %{total: length(markets), active: 0, pending: 0}, fn market, acc ->
      case market.status do
        :active -> %{acc | active: acc.active + 1}
        s when s in [:awaiting_deposit, :pending] -> %{acc | pending: acc.pending + 1}
        _ -> acc
      end
    end)
  end

  # TVL = real XMR currently held against in-flight market activity.
  # Total custody across markets that haven't reached a terminal
  # state: creator deposits + trader collateral + live dispute stakes.
  # `Status.in_flight?/1` owns the in-flight market set so this read
  # stays consistent with the state machine as new statuses appear.
  #
  # Dispute stakes in `:live` count toward TVL because they're in
  # federation custody, not withdrawable, and committed to the
  # resolution process — same character as open positions.
  # Resolved-but-unclaimed disputes are excluded for the same reason
  # settled-winner positions are: they're designated to leave the
  # venue (claim-pending payout), not still in flight within it.
  defp sub_nav_pool_xmr(markets) do
    in_flight_markets = Enum.filter(markets, &Facade.status_in_flight?(&1.status))
    in_flight_ids = MapSet.new(in_flight_markets, & &1.id)

    wagered =
      Facade.list_all_positions()
      |> Enum.filter(&MapSet.member?(in_flight_ids, &1.market_id))
      |> pool_wagered_piconeros()

    deposits = Enum.reduce(in_flight_markets, 0, fn m, acc -> acc + m.deposit_amount end)

    live_dispute_stakes =
      Facade.list_disputes_by_status(:live)
      |> Enum.filter(&MapSet.member?(in_flight_ids, &1.market_id))
      |> Enum.reduce(0, fn d, acc -> acc + d.stake_amount_piconeros end)

    format_xmr_compact(wagered + deposits + live_dispute_stakes)
  end

  @doc """
  Empty-state slot for a `.bp-table-scroll` panel — wraps
  `empty_state` in the `.bp-empty .bp-empty-fill` host div that
  centres the message inside the available scroll area. Used on
  every browse/list view (markets, leaderboard, portfolio, the
  detail comments panel) so the empty look is uniform.
  """
  attr(:message, :string, required: true)

  def table_empty_state(assigns) do
    ~H"""
    <div class="bp-empty bp-empty-fill">
      <.empty_state message={@message} />
    </div>
    """
  end

  @doc """
  Standard announcement items rendered at the top of every public
  page. Single warning at launch; expand the list for incidents,
  scheduled maintenance, etc.
  """
  @spec announcements() :: [%{message: String.t(), variant: String.t()}]
  def announcements do
    base = [
      %{
        message: Messages.announcement_experimental_software(),
        variant: "warning"
      }
    ]

    # Halted = `PerpWalk.Guards` refuses writes. Same gate the services
    # consult, so a banner shown here matches what the user would see
    # if they tried to act anyway. Reason flows from
    # `HealthSystem.halt_reason/0` so the message reflects the
    # underlying trigger (quorum lost, disk critical, operator halt)
    # rather than guessing one cause.
    if Guards.operational?() do
      base
    else
      [
        %{
          message:
            Messages.announcement_venue_paused_lead() <>
              Messages.venue_halted_banner(TelemetryFacade.halt_reason()),
          variant: "critical"
        }
        | base
      ]
    end
  end

  @doc """
  Standard PERP WALK app footer.

  Three pips for the dependencies the public surface actually
  relies on:

  - **Federation** — leading pip, shows quorum status (e.g.
    "Federation 3/3"). Reads from `Federation.Facade` rather than
    Cartel directly so the cross-domain boundary is clean. This
    is the load-bearing trust signal — when the federation has
    quorum, no single party can move user funds.
  - **Tor** — the only network path in.
  - **Monero** — settlement asset.

  Storage, Markets, and System pips live on the admin footer only;
  they aren't load-bearing for users.
  """
  attr(:health, :map, required: true)

  def app_footer(assigns) do
    ~H"""
    <.footer
      pips={[
        %{label: @health.federation_label, status: @health.federation},
        %{label: Messages.footer_pip_tor(), status: @health.tor},
        %{label: Messages.footer_pip_monero(), status: @health.monero}
      ]}
      commit_hash={PerpWalk.Version.git_sha()}
    />
    """
  end

  defp pip_status(:healthy), do: :ok
  defp pip_status(:degraded), do: :degraded
  defp pip_status(:critical), do: :critical
  defp pip_status(:halted), do: :critical
  defp pip_status(_), do: :offline

  # Federation pip status lives on the Federation.Facade so admin and
  # user surfaces render from the same source. See its @doc.
  defp federation_pip_status, do: FederationFacade.pip_status()

  defp federation_label do
    online = FederationFacade.online_peer_count() + 1
    total = FederationFacade.member_count()
    Messages.footer_pip_federation(online, total)
  end

  # --- Footer Health ---
  #
  # `app_footer/1` is a pure renderer: it takes a `:health` map and
  # renders the pips. Each LiveView keeps `:health` in its socket
  # assigns, fetches it on mount via `fetch_footer_health/0`, and
  # re-fetches when any pip-relevant event lands in `handle_info`.
  #
  # The list of event modules every public LiveView should subscribe
  # to lives at `pip_event_subscriptions/0` so the subscription
  # surface stays consistent across pages.

  @pip_event_subscriptions [
    FederationEvents.SigningHalted,
    FederationEvents.SigningResumed,
    FederationEvents.MultisigAddressMismatch,
    FederationEvents.PeerLost,
    FederationEvents.PeerJoined,
    FederationEvents.QuorumLost,
    FederationEvents.QuorumRestored,
    TelemetryEvents.SystemStatusChanged,
    TelemetryEvents.TorDown,
    TelemetryEvents.TorDegraded,
    TelemetryEvents.TorRecovered
  ]

  @doc """
  Event modules a public LiveView should subscribe to so the footer
  pips stay live without page reload. Returns a list of struct
  modules suitable for `Enum.each(modules, &EventBus.subscribe/1)`.
  """
  @spec pip_event_subscriptions() :: [module()]
  def pip_event_subscriptions, do: @pip_event_subscriptions

  @doc """
  Subscribes the current process to every pip-relevant event. Call
  from `mount/3` under `connected?(socket)` so reconnecting clients
  pick up live transitions.
  """
  @spec subscribe_to_pip_events() :: :ok
  def subscribe_to_pip_events do
    Enum.each(@pip_event_subscriptions, &EventBus.subscribe/1)
    :ok
  end

  @doc """
  Fetches footer health: Tor, Monero, and federation states, plus the
  federation peer-count label. Called from `mount/3` and again from
  each pip-event `handle_info/2`.
  """
  @spec fetch_footer_health() :: %{
          tor: atom(),
          monero: atom(),
          federation: atom(),
          federation_label: String.t()
        }
  def fetch_footer_health do
    components = PerpWalk.Telemetry.Facade.health_components()

    %{
      tor: pip_status(Map.get(components, :tor, :unknown)),
      monero: pip_status(Map.get(components, :monero, :unknown)),
      federation: federation_pip_status(),
      federation_label: federation_label()
    }
  end

  @doc """
  Catch-all `handle_info/2` delegate that refreshes `:health` when
  `msg` is one of `pip_event_subscriptions/0`. Returns the
  `{:noreply, socket}` tuple on a match, or `:pass` so the caller
  can fall through to its own default. Use:

      def handle_info(msg, socket) do
        case Helpers.handle_pip_event(msg, socket) do
          :pass -> {:noreply, socket}
          handled -> handled
        end
      end
  """
  @spec handle_pip_event(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()} | :pass
  def handle_pip_event(%mod{}, socket) when mod in @pip_event_subscriptions do
    {:noreply, assign(socket, :health, fetch_footer_health())}
  end

  def handle_pip_event(_msg, _socket), do: :pass

  @piconeros_per_xmr 1_000_000_000_000

  @doc """
  Returns `{label, severity}` for the per-row STATE column.

  Non-terminal statuses surface the status itself (PENDING /
  ACTIVE / EXPIRED / RESOLVING). Terminal statuses surface the
  outcome (YES / NO / VOID) for settled markets, VOID for voided,
  and REJECTED for community-rejected. Severity is the standard
  health-style classification: `:ok | :info | :warning |
  :critical | :muted`.
  """
  @spec state_label(Market.t()) :: {String.t(), String.t()}
  # `:awaiting_deposit` and `:pending` both render as PENDING to
  # users — they're both "not tradeable yet" from the public-facing
  # perspective. The functional distinction (creator liquidity not
  # yet confirmed vs listing-vote window open) is communicated by
  # the action panel content on the detail page, not the label.
  # Admin surfaces still distinguish them in count widgets.
  def state_label(%Market{status: :awaiting_deposit}), do: {Messages.market_state_pending(), "muted"}
  def state_label(%Market{status: :pending}), do: {Messages.market_state_pending(), "muted"}
  def state_label(%Market{status: :active}), do: {Messages.market_state_active(), "active"}
  # `:expired` and `:resolving` are distinct user-facing states per
  # the canonical state outline (see /docs/#states): EXPIRED means
  # trading frozen and awaiting creator resolution; RESOLVING means
  # creator submitted and the dispute window is open. The action
  # prompt is different for non-creators (wait vs decide-to-dispute),
  # so the badge should distinguish them.
  def state_label(%Market{status: :expired}), do: {Messages.market_state_expired(), "warning"}
  def state_label(%Market{status: :resolving}), do: {Messages.market_state_resolving(), "warning"}
  # Status badges describe the market's lifecycle STATE per the
  # canonical state outline at /docs/#states — never the resolution
  # outcome. The outcome (YES / NO / VOID) is a separate piece of
  # information that lives on the detail page, not in the status
  # column. Conflating them was semantically wrong: a settled-YES
  # market and a settled-NO market are in the same state (`:settled`);
  # they just resolved to different outcomes.
  def state_label(%Market{status: :settled}), do: {Messages.market_state_settled(), "muted"}
  def state_label(%Market{status: :voided}), do: {Messages.market_state_voided(), "muted"}
  def state_label(%Market{status: :rejected}), do: {Messages.market_state_rejected(), "critical"}
  def state_label(%Market{status: status}), do: {status_label(status), "muted"}

  # --- AMM-Derived Display ---

  @doc """
  Returns `{yes_cents, no_cents}` — mid-probability of each side
  expressed as integer cents on a 100-unit scale. Sums to 100.
  """
  @spec mid_cents(AMM.t()) :: {non_neg_integer(), non_neg_integer()}
  def mid_cents(%AMM{} = pool) do
    {yes_num, denom} = Facade.mid_probability(pool, :yes)
    yes = round(yes_num * 100 / denom)
    {yes, 100 - yes}
  end

  @doc """
  Returns `{yes, no}` mid-probability as decimal strings rounded
  to two places — the canonical row-display format. XMR-native
  pricing uses unitless decimals (`"0.62"`) rather than fiat-style
  cents.
  """
  @spec mid_decimals(AMM.t()) :: {String.t(), String.t()}
  def mid_decimals(%AMM{} = pool) do
    {yes_cents, no_cents} = mid_cents(pool)
    {format_decimal(yes_cents), format_decimal(no_cents)}
  end

  defp format_decimal(cents) when is_integer(cents) do
    :erlang.float_to_binary(cents / 100, decimals: 2)
  end

  @doc """
  Renders a 10-segment YES/NO bar. Returns `{yes_segments, no_segments}`
  where the two sum to 10.
  """
  @spec odds_bar_segments(AMM.t()) :: {non_neg_integer(), non_neg_integer()}
  def odds_bar_segments(%AMM{} = pool) do
    {yes, _no} = mid_cents(pool)
    yes_segs = round(yes / 10)
    {yes_segs, 10 - yes_segs}
  end

  # --- Pool / Amount Formatting ---

  @doc """
  Sum of real XMR (in piconeros) that traders have wagered across
  the supplied positions — i.e. the actual money currently held in
  custody (or that was held, for terminal positions). Distinct from
  the AMM's virtual `(yes + no) × unit_size` reserves, which are
  bookkeeping for pricing-curve math and don't represent real money.

  `Federation.Rules` keeps its own curve-based pool calc — the
  rate-cap-per-market gate is correctly bounded by max-possible
  drainage, not by what's actually been wagered.
  """
  @spec pool_wagered_piconeros([Position.t()]) :: non_neg_integer()
  def pool_wagered_piconeros(positions) when is_list(positions) do
    Enum.reduce(positions, 0, fn p, acc -> acc + p.amount_paid end)
  end

  @doc """
  Total custody backing this market's open contracts. Sum of the
  creator's initial LP deposit plus all trader collateral committed.
  This is what backs the maximum-payout obligation on the venue:
  winning-side contracts × unit_size is bounded by this total.

  Public stat surfaces should use this rather than
  `pool_wagered_piconeros/1` alone — the latter omits the creator
  seed and lets users do a `max_payout > pool` sanity check that
  fails for no good reason.
  """
  @spec pool_total_piconeros([Position.t()], non_neg_integer()) :: non_neg_integer()
  def pool_total_piconeros(positions, deposit_amount)
      when is_list(positions) and is_integer(deposit_amount) and deposit_amount >= 0 do
    pool_wagered_piconeros(positions) + deposit_amount
  end

  @doc "Pool size formatted as `\"NN.N XMR\"` (compact). Trader-wagered only — see `format_pool_total/2` for the surface users do payout-sanity checks against."
  @spec format_pool([Position.t()]) :: String.t()
  def format_pool(positions) when is_list(positions) do
    positions
    |> pool_wagered_piconeros()
    |> format_xmr_compact()
  end

  @doc """
  Total custody (creator deposit + trader wagered) formatted for
  public stat panels. Use this on the market detail stats so a user
  can sanity-check their max payout against the displayed pool
  without the creator deposit being silently omitted.
  """
  @spec format_pool_total([Position.t()], non_neg_integer()) :: String.t()
  def format_pool_total(positions, deposit_amount) do
    positions
    |> pool_total_piconeros(deposit_amount)
    |> format_xmr_compact()
  end

  @doc """
  Format an atomic-piconero amount as XMR with **exact** precision.

  No floating-point math, no rounding — the displayed value matches
  the on-chain amount byte-for-byte. This is the default formatter
  for every "send this exact amount" surface (trade modal, dispute
  stake, market deposit, position payouts) so the number the user
  sees ALWAYS matches the amount encoded into the deposit QR.

  Trailing zeros after the decimal are stripped for readability, but
  a single trailing `.0` is preserved when the amount has no
  fractional piconeros so the unit reads naturally (`"1.0 XMR"`
  rather than `"1 XMR"`).

  For summary / aggregate displays where a rounded compact form is
  preferred (TVL on the dashboard, pool size on the browse view, the
  24h volume tile), use `format_xmr_compact/1` explicitly. The
  default stays exact so a future caller reaching for `format_xmr/1`
  without thinking inherits the safe precision behaviour rather than
  the rounding one — money-display rounding bugs read OK in code
  review and break operator/user trust when they ship.
  """
  @spec format_xmr(non_neg_integer()) :: String.t()
  def format_xmr(piconeros) when is_integer(piconeros) and piconeros >= 0 do
    whole = div(piconeros, @piconeros_per_xmr)
    fractional = rem(piconeros, @piconeros_per_xmr)

    if fractional == 0 do
      "#{whole}.0 XMR"
    else
      frac_str =
        fractional
        |> Integer.to_string()
        |> String.pad_leading(12, "0")
        |> String.trim_trailing("0")

      "#{whole}.#{frac_str} XMR"
    end
  end

  @doc """
  Truncates a long address to `<first 12>…<last 12>`. Used in
  confirm-style modal rows where the full address wraps ugly; pair
  with `title={full_address}` on the wrapping element so the full
  string is available on hover / for copy-paste tooling.
  """
  @spec short_address(String.t()) :: String.t()
  def short_address(addr) when is_binary(addr) and byte_size(addr) > 24 do
    "#{String.slice(addr, 0, 12)}…#{String.slice(addr, -12, 12)}"
  end

  def short_address(addr) when is_binary(addr), do: addr

  @doc """
  Compact XMR display for summary contexts. Delegates to
  `format_xmr/1` for anything under 1000 XMR — so a compact reading
  matches its exact-transactional counterpart digit-for-digit — and
  falls back to a `k`-suffix at 1-decimal truncation for the rare
  dashboard-tile case where the aggregate exceeds 1000 XMR.

      520_200_000            → "0.0005202 XMR"
      10_520_200_000         → "0.0105202 XMR"
      500_000_000_000        → "0.5 XMR"
      1_500_000_000_000      → "1.5 XMR"
      500_000_000_000_000    → "500 XMR"
      12_500_000_000_000_000 → "12.5k XMR"
      0                      → "0 XMR"
  """
  @spec format_xmr_compact(non_neg_integer()) :: String.t()
  def format_xmr_compact(0), do: "0 XMR"

  def format_xmr_compact(piconeros)
      when is_integer(piconeros) and piconeros >= 1000 * @piconeros_per_xmr do
    tenths_of_k = div(piconeros, 100 * @piconeros_per_xmr)
    whole = div(tenths_of_k, 10)
    frac = rem(tenths_of_k, 10)
    if frac == 0, do: "#{whole}k XMR", else: "#{whole}.#{frac}k XMR"
  end

  def format_xmr_compact(piconeros) when is_integer(piconeros) and piconeros > 0 do
    piconeros
    |> format_xmr()
    |> strip_trailing_dot_zero()
  end

  # `format_xmr/1` emits `"N.0 XMR"` for whole-XMR amounts to preserve
  # the currency decimal marker on exact surfaces. In a compact tile
  # that trailing `.0` reads as fake precision — strip it so `500.0`
  # displays as `500`.
  defp strip_trailing_dot_zero(str) do
    if String.ends_with?(str, ".0 XMR") do
      binary_part(str, 0, byte_size(str) - 6) <> " XMR"
    else
      str
    end
  end

  @doc "Lower-case label for a position status atom."
  @spec position_status_label(atom()) :: String.t()
  def position_status_label(:open), do: Messages.position_status_open()
  def position_status_label(:settled_winner), do: Messages.position_status_winner()
  def position_status_label(:settled_loser), do: Messages.position_status_loser()
  def position_status_label(:refunded), do: Messages.position_status_refunded()
  def position_status_label(:paid_out), do: Messages.position_status_paid_out()
  def position_status_label(other) when is_atom(other), do: Atom.to_string(other)

  @doc "`bp-pill` severity variant for a position status."
  @spec position_status_variant(atom()) :: String.t()
  def position_status_variant(:open), do: "muted"
  def position_status_variant(:settled_winner), do: "active"
  def position_status_variant(:settled_loser), do: "critical"
  def position_status_variant(:refunded), do: "muted"
  def position_status_variant(:paid_out), do: "active"
  def position_status_variant(_), do: "muted"

  @doc "`bp-pill` severity variant for a YES/NO side."
  @spec side_label_variant(:yes | :no) :: String.t()
  def side_label_variant(:yes), do: "active"
  def side_label_variant(:no), do: "muted"

  @doc "Lower-case label for a dispute status atom."
  @spec dispute_status_label(atom()) :: String.t()
  def dispute_status_label(:awaiting_deposit), do: Messages.dispute_status_awaiting_deposit()
  def dispute_status_label(:live), do: Messages.dispute_status_live()
  def dispute_status_label(:resolved_for), do: Messages.dispute_status_resolved_for()
  def dispute_status_label(:resolved_against), do: Messages.dispute_status_resolved_against()
  def dispute_status_label(:refunded_full), do: Messages.dispute_status_refunded_full()
  def dispute_status_label(:refunded_partial), do: Messages.dispute_status_refunded_partial()
  def dispute_status_label(other) when is_atom(other), do: Atom.to_string(other)

  @doc "`bp-pill` severity variant for a dispute status."
  @spec dispute_status_variant(atom()) :: String.t()
  def dispute_status_variant(:awaiting_deposit), do: "muted"
  def dispute_status_variant(:live), do: "active"
  def dispute_status_variant(:resolved_for), do: "critical"
  def dispute_status_variant(:resolved_against), do: "active"
  def dispute_status_variant(:refunded_full), do: "muted"
  def dispute_status_variant(:refunded_partial), do: "muted"
  def dispute_status_variant(_), do: "muted"

  # --- Time Formatting ---

  @doc """
  Relative time string symmetric around the present:
  `"67d"`, `"6h 32m"`, `"15m"` for future targets; `"3d ago"`,
  `"4h ago"`, `"15m ago"` for past targets; `"now"` only when target
  equals the reference instant. Past-rendering keeps surfaces like
  the market header honest after expiry/resolution dates lapse —
  "now" was technically true at the moment of crossing but misleads
  every subsequent render.
  """
  @spec time_until(DateTime.t(), DateTime.t()) :: String.t()
  def time_until(%DateTime{} = target, %DateTime{} = now) do
    diff = DateTime.diff(target, now, :second)

    cond do
      diff < -86_400 -> Messages.time_days_ago(div(-diff, 86_400))
      diff < -3_600 -> Messages.time_hours_ago(div(-diff, 3_600))
      diff < -60 -> Messages.time_minutes_ago(div(-diff, 60))
      diff < 0 -> Messages.time_seconds_ago(-diff)
      diff == 0 -> Messages.time_now()
      diff < 60 -> Messages.time_seconds(diff)
      diff < 3_600 -> Messages.time_minutes(div(diff, 60))
      diff < 86_400 -> Messages.time_hours_minutes(div(diff, 3_600), div(rem(diff, 3_600), 60))
      true -> Messages.time_days(div(diff, 86_400))
    end
  end

  @doc """
  Past-relative time string like `"4h ago"`. Re-exports
  `Blueprint.FormatHelpers.relative_time/2` for symmetry with
  `time_until/2`.
  """
  @spec time_since(DateTime.t(), DateTime.t()) :: String.t()
  defdelegate time_since(dt, now), to: Blueprint.FormatHelpers, as: :relative_time

  # --- Status Display ---

  @doc "Human label for a market status."
  @spec status_label(Market.status()) :: String.t()
  # User-facing — `:awaiting_deposit` displays as PENDING (see
  # `state_label/1` comment for rationale).
  def status_label(:awaiting_deposit), do: Messages.market_status_pending()
  def status_label(:pending), do: Messages.market_status_pending()
  def status_label(:active), do: Messages.market_status_active()
  # `:expired` + `:resolving` collapse into CLOSED for user-facing
  # surfaces — see `state_label/1` for the rationale.
  def status_label(:expired), do: Messages.market_status_closed()
  def status_label(:resolving), do: Messages.market_status_closed()
  def status_label(:settled), do: Messages.market_status_settled()
  def status_label(:rejected), do: Messages.market_status_rejected()
  def status_label(:voided), do: Messages.market_status_voided()
  def status_label(_), do: ""

  @doc "Human label for a category atom."
  @spec category_label(atom()) :: String.t()
  def category_label(:politics), do: Messages.category_politics()
  def category_label(:crypto), do: Messages.category_crypto()
  def category_label(:finance), do: Messages.category_finance()
  def category_label(:sports), do: Messages.category_sports()
  def category_label(:entertainment), do: Messages.category_entertainment()
  def category_label(:science_tech), do: Messages.category_science_tech()
  def category_label(:culture), do: Messages.category_culture()
  def category_label(_), do: ""
end
