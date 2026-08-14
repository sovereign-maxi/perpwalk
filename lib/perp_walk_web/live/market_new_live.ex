defmodule PerpWalkWeb.MarketNewLive do
  @moduledoc """
  Market creation LiveView at `/markets/new`.

  Authenticated users propose new markets. The proposal enters
  `:pending` state and goes through community listing voting before
  activating. Operator dials (unit size, initial pool reserves,
  creation deposit, resolution window) are baked into config; users
  specify the question, category, and closing time.

  See `PerpWalk.Markets.Services.Maker.create_market/1` for the
  domain entry point and `PerpWalk.Markets.Market.new/1` for the
  validation rules.
  """

  use PerpWalkWeb, :live_view

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Markets, as: MarketsEvents
  alias PerpWalk.Markets.{Categories, Facade}
  alias PerpWalkWeb.Live.Components.Modal
  alias PerpWalkWeb.Live.Helpers
  alias PerpWalkWeb.Live.RateLimit.Shared, as: SharedRateLimit
  alias PerpWalkWeb.Messages

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:current_account_id] == nil do
      {:ok,
       socket
       |> put_flash(:error, Messages.login_required(:propose))
       |> push_navigate(to: ~p"/auth/login")}
    else
      if connected?(socket) do
        Helpers.subscribe_to_pip_events()
        EventBus.subscribe(MarketsEvents.MarketDepositObserved)
        EventBus.subscribe(MarketsEvents.MarketDepositConfirmed)
      end

      {:ok,
       socket
       |> assign(:page_title, Messages.page_title_propose_market())
       |> assign(:form_data, default_form_data())
       |> assign(:deposit_constraints, deposit_constraints())
       |> assign(:errors, [])
       |> assign(:pending_market, nil)
       |> assign(:payment_observed, false)
       |> assign(:health, Helpers.fetch_footer_health())}
    end
  end

  @impl true
  def handle_info(
        %MarketsEvents.MarketDepositObserved{market_id: id},
        %{assigns: %{pending_market: %{id: id}}} = socket
      ) do
    {:noreply, assign(socket, :payment_observed, true)}
  end

  def handle_info(%MarketsEvents.MarketDepositObserved{}, socket), do: {:noreply, socket}

  def handle_info(
        %MarketsEvents.MarketDepositConfirmed{market_id: id},
        %{assigns: %{pending_market: %{id: id}}} = socket
      ) do
    {:noreply,
     socket
     |> put_flash(:success, Messages.market_proposed())
     |> push_navigate(to: ~p"/markets/#{id}")}
  end

  def handle_info(%MarketsEvents.MarketDepositConfirmed{}, socket), do: {:noreply, socket}

  def handle_info(msg, socket) do
    case Helpers.handle_pip_event(msg, socket) do
      :pass -> {:noreply, socket}
      handled -> handled
    end
  end

  # An unauthenticated client could bypass the mount/3 redirect by
  # sending a "create" event over the raw WebSocket. Re-check the
  # current_account_id here so the LiveView edge stays fail-closed
  # even if the navigation reply is dropped.
  @impl true
  def handle_event("create", _params, %{assigns: %{current_account_id: nil}} = socket) do
    {:noreply, push_navigate(socket, to: ~p"/auth/login")}
  end

  def handle_event("create", %{"market" => params}, socket) do
    case SharedRateLimit.check(socket.assigns.current_account_id, :create_market) do
      :ok ->
        do_create_market(params, socket)

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, Messages.rate_limited(:create_market))}
    end
  end

  def handle_event("liquidity:close", _params, socket) do
    case socket.assigns[:pending_market] do
      %{id: id} ->
        {:noreply,
         socket
         |> put_flash(:success, Messages.market_proposed())
         |> push_navigate(to: ~p"/markets/#{id}")}

      _ ->
        {:noreply, assign(socket, :pending_market, nil)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # --- Create / Validate ---

  defp do_create_market(params, socket) do
    case create(socket.assigns.current_account_id, params) do
      {:ok, market} ->
        # Show the liquidity modal in-place rather than navigating away
        # immediately. The QR + amount + address come up next to the
        # form the user just submitted; closing the modal navigates
        # to the market detail page. If the user dismisses without
        # sending, the market still sits as :awaiting_deposit and
        # gets auto-voided by the Scheduler if no deposit confirms
        # in the configured window.
        {:noreply,
         socket
         |> assign(:pending_market, market)
         |> assign(:payment_observed, false)}

      {:error, errors} ->
        {:noreply,
         socket
         |> assign(:errors, errors)
         |> assign(:form_data, params)}
    end
  end

  defp create(account_id, params) do
    with {:ok, opts} <- build_opts(account_id, params),
         {:ok, market} <- Facade.create_market(opts) do
      {:ok, market}
    else
      {:error, reason} -> {:error, [reason]}
    end
  rescue
    # Covers the race where a peer drops between page render and submit.
    PerpWalk.Guards.SystemHaltedError -> {:error, [:halted]}
  end

  defp build_opts(account_id, params) do
    with {:ok, description} <- parse_description(params["description"]),
         {:ok, criterion} <- parse_criterion(params["resolution_criterion"]),
         {:ok, category} <- parse_category(params["category"]),
         {:ok, expiry} <- parse_datetime(params["expires_at"], :expires_at),
         :ok <- validate_expiry_in_future(expiry),
         {:ok, deposit_piconeros} <- parse_deposit(params["deposit_xmr"]) do
      base = [
        description: description,
        resolution_criterion: criterion,
        category: category,
        expiry: expiry,
        creator_account_id: account_id
      ]

      # Only forward the deposit when the creator specified one;
      # otherwise let Maker fall back to its configured default.
      opts = if deposit_piconeros, do: base ++ [deposit_amount: deposit_piconeros], else: base

      {:ok, opts}
    end
  end

  defp parse_description(nil), do: {:error, :description_required}
  defp parse_description(""), do: {:error, :description_required}

  defp parse_description(s) when is_binary(s) do
    trimmed = String.trim(s)

    cond do
      String.length(trimmed) < 12 -> {:error, :description_too_short}
      String.length(trimmed) > 200 -> {:error, :description_too_long}
      true -> {:ok, trimmed}
    end
  end

  defp parse_criterion(nil), do: {:error, :criterion_required}
  defp parse_criterion(""), do: {:error, :criterion_required}

  defp parse_criterion(s) when is_binary(s) do
    trimmed = String.trim(s)

    cond do
      String.length(trimmed) < 30 -> {:error, :criterion_too_short}
      String.length(trimmed) > 1000 -> {:error, :criterion_too_long}
      true -> {:ok, trimmed}
    end
  end

  defp parse_category(nil), do: {:error, :category_required}

  defp parse_category(s) when is_binary(s) do
    atom = String.to_existing_atom(s)
    if Categories.valid?(atom), do: {:ok, atom}, else: {:error, :invalid_category}
  rescue
    ArgumentError -> {:error, :invalid_category}
  end

  defp parse_datetime(nil, field), do: {:error, {:datetime_required, field}}
  defp parse_datetime("", field), do: {:error, {:datetime_required, field}}

  defp parse_datetime(s, field) when is_binary(s) do
    # datetime-local inputs come in as "2026-05-12T14:30" (no seconds, no zone).
    iso = if String.contains?(s, ":") and not String.contains?(s, "Z"), do: s <> ":00Z", else: s

    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, {:invalid_datetime, field}}
    end
  end

  defp validate_expiry_in_future(expiry) do
    if DateTime.compare(expiry, DateTime.utc_now()) == :gt,
      do: :ok,
      else: {:error, :expiry_in_past}
  end

  # Deposit comes in as an XMR string ("1", "0.01", "5.25"). Converted
  # to piconeros for the backend (multiply by 10^12, round to int).
  # Mainnet defaults render as whole XMR ("1"); stagenet renders sub-
  # XMR ("0.01") — the parser handles both. Empty / missing = fall
  # back to the configured floor (Maker.min_deposit_piconeros).
  @piconeros_per_xmr 1_000_000_000_000

  defp parse_deposit(nil), do: {:ok, nil}
  defp parse_deposit(""), do: {:ok, nil}

  defp parse_deposit(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Float.parse(trimmed) do
      {xmr, ""} when xmr > 0 ->
        piconeros = round(xmr * @piconeros_per_xmr)
        if piconeros > 0, do: {:ok, piconeros}, else: {:error, :deposit_invalid}

      _ ->
        {:error, :deposit_invalid}
    end
  end

  # --- Form Defaults ---

  defp default_form_data do
    expiry = DateTime.add(DateTime.utc_now(), 7 * 86_400, :second)

    %{
      "description" => "",
      "resolution_criterion" => "",
      "category" => "politics",
      "expires_at" => format_for_input(expiry),
      "deposit_xmr" => Messages.format_xmr_short(Facade.min_deposit_piconeros())
    }
  end

  # Deposit input bounds derived from Markets config. Rendered into the
  # `<input type="number">` attributes so the browser enforces the same
  # rules the Maker enforces server-side (min/max range, step = unit
  # size). Values are XMR strings — the parser normalises back to
  # piconeros on submit.
  defp deposit_constraints do
    %{
      min: Messages.format_xmr_short(Facade.min_deposit_piconeros()),
      max: Messages.format_xmr_short(Facade.max_deposit_piconeros()),
      step: Messages.format_xmr_short(Facade.deposit_step_piconeros())
    }
  end

  defp format_for_input(%DateTime{} = dt) do
    dt
    |> DateTime.to_iso8601()
    |> String.slice(0, 16)
  end

  # --- Error Formatting ---

  defp error_message(:description_required), do: Messages.description_required()
  defp error_message(:description_too_short), do: Messages.description_too_short()
  defp error_message(:description_too_long), do: Messages.description_too_long()
  defp error_message(:criterion_required), do: Messages.criterion_required()
  defp error_message(:criterion_too_short), do: Messages.criterion_too_short()
  defp error_message(:criterion_too_long), do: Messages.criterion_too_long()
  defp error_message(:category_required), do: Messages.category_required()
  defp error_message(:invalid_category), do: Messages.category_invalid()
  defp error_message({:datetime_required, :expires_at}), do: Messages.expires_at_required()
  defp error_message({:invalid_datetime, :expires_at}), do: Messages.expires_at_invalid()
  defp error_message(:expiry_in_past), do: Messages.expiry_in_past()
  defp error_message(:deposit_invalid), do: Messages.deposit_invalid()
  defp error_message({:deposit_not_unit_multiple, _, _}), do: Messages.deposit_not_unit_multiple()
  defp error_message({:deposit_not_step_multiple, _, _}), do: Messages.deposit_not_step_multiple()
  defp error_message({:deposit_below_min, _, min}), do: Messages.deposit_below_min(min)
  defp error_message({:deposit_above_max, _, max}), do: Messages.deposit_above_max(max)
  defp error_message({:subaddress_provider_failed, _}), do: Messages.deposit_provider_offline()
  defp error_message(:halted), do: Messages.venue_halted()
  defp error_message(:market_already_exists), do: Messages.market_already_exists()
  # Generic fallback — never inspect the raw reason because it can carry
  # upstream stacktraces, RPC URLs, or other internal detail.
  defp error_message(_other), do: Messages.create_market_failed_generic()

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <Helpers.app_header current_handle={@current_handle} current_page={:market_create} />
    <Helpers.app_sub_nav current_handle={@current_handle} current_page={:market_create} />

    <main class="bp-root">
      <h1 class="bp-sr-only">{Messages.panel_propose_market()}</h1>
      <div class="bp-page bp-page-form">
        <.panel title={Messages.panel_propose_market()}>
          <div class="bp-stack-lg bp-pad-lg">
            <div class="bp-stack-md">
              <p class="bp-lead">{Messages.propose_intro()}</p>
            </div>

            <form id="market-create-form" phx-submit="create" class="bp-stack-lg" autocomplete="off">
              <div class="bp-field">
                <label for="market-description" class="bp-label">{Messages.label_question()}</label>
                <input
                  type="text"
                  id="market-description"
                  name="market[description]"
                  class="bp-input"
                  required
                  maxlength="200"
                  minlength="12"
                  placeholder={Messages.placeholder_question()}
                  value={@form_data["description"]}
                />
                <p class="bp-help">{Messages.help_question()}</p>
              </div>

              <div class="bp-field">
                <label for="market-criterion" class="bp-label">{Messages.label_resolution_criterion()}</label>
                <textarea
                  id="market-criterion"
                  name="market[resolution_criterion]"
                  class="bp-input bp-field-textarea"
                  required
                  rows="4"
                  maxlength="1000"
                  minlength="30"
                  placeholder={Messages.placeholder_resolution_criterion()}
                >{@form_data["resolution_criterion"]}</textarea>
                <p class="bp-help">{Messages.help_resolution_criterion()}</p>
              </div>

              <div class="bp-field">
                <label for="market-category" class="bp-label">{Messages.label_category()}</label>
                <select
                  id="market-category"
                  name="market[category]"
                  class="bp-input"
                  required
                >
                  <option
                    :for={cat <- Categories.all()}
                    value={cat}
                    selected={@form_data["category"] == to_string(cat)}
                  >
                    {Helpers.category_label(cat)}
                  </option>
                </select>
              </div>

              <div class="bp-field">
                <label for="market-expires" class="bp-label">{Messages.label_betting_closes()}</label>
                <input
                  type="datetime-local"
                  id="market-expires"
                  name="market[expires_at]"
                  class="bp-input"
                  required
                  value={@form_data["expires_at"]}
                />
                <p class="bp-help">{Messages.help_betting_closes()}</p>
              </div>

              <div class="bp-field">
                <label for="market-deposit" class="bp-label">{Messages.label_deposit_xmr()}</label>
                <input
                  type="number"
                  id="market-deposit"
                  name="market[deposit_xmr]"
                  class="bp-input"
                  inputmode="decimal"
                  step={@deposit_constraints.step}
                  min={@deposit_constraints.min}
                  max={@deposit_constraints.max}
                  value={@form_data["deposit_xmr"]}
                />
                <p class="bp-help">{Messages.help_deposit_xmr()}</p>
              </div>

              <div :if={@errors != []} class="pw-create-errors">
                <p :for={error <- @errors} class="pw-create-error">{error_message(error)}</p>
              </div>

              <div class="bp-btn-row-wrap">
                <button type="submit" class="bp-btn bp-btn-primary">{Messages.action_propose_market()}</button>
              </div>
            </form>
          </div>
        </.panel>
      </div>

      <Helpers.app_footer health={@health} />
    </main>

    <.liquidity_modal
      :if={@pending_market}
      market={@pending_market}
      monero_status={@health.monero}
      payment_observed={@payment_observed}
    />
    """
  end

  # --- Liquidity Modal ---
  #
  # Shown after a successful proposal so the creator sees the deposit
  # subaddress + amount + QR in the same flow that produced them. The
  # `payment_observed` flag flips on the first mempool/unconfirmed
  # observation of the deposit so the QR can grey out before the full
  # confirmation threshold lands — same UX as the trade-deposit flow.
  # Final activation still requires the Poller to see the deposit
  # confirmed and Maker to transition the market to `:pending`.

  attr(:market, :map, required: true)
  attr(:monero_status, :atom, default: :ok)
  attr(:payment_observed, :boolean, default: false)

  defp liquidity_modal(assigns) do
    ~H"""
    <Modal.modal
      title={Messages.modal_title_initial_liquidity()}
      title_id="liquidity-modal-title"
      click_away="liquidity:close"
    >
      <Modal.deposit_block
        subaddress={@market.deposit_subaddress}
        copy_button_id={"market-liquidity-copy-#{@market.id}"}
        copy_aria_label={Messages.aria_copy_market_deposit_address()}
        monero_status={@monero_status}
        amount_piconeros={@market.deposit_amount}
        show_copy={false}
        payment_observed={@payment_observed}
      >
        <:lead>
          <p class="bp-lead">
            {Messages.initial_liquidity_modal_lead(Helpers.format_xmr(@market.deposit_amount))}
          </p>
        </:lead>
      </Modal.deposit_block>

      <div class="bp-btn-row">
        <button type="button" class="bp-btn bp-btn-default" phx-click="liquidity:close">
          {if @payment_observed, do: Messages.action_hide(), else: Messages.action_close()}
        </button>
      </div>
    </Modal.modal>
    """
  end
end
