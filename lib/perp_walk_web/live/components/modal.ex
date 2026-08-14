defmodule PerpWalkWeb.Live.Components.Modal do
  @moduledoc """
  Shared modal chrome and the deposit-address block that lives
  inside most of our modals.

  Three places use these:

    * `MarketNewLive` — creator liquidity modal after a successful
      proposal.
    * `MarketLive` — trade and dispute modals, plus the inline
      `:awaiting_deposit` action panel (which reuses just
      `deposit_block/1` inside a `<.panel>`, not a real modal).
    * `PortfolioLive` — claim-entry / claim-confirm / resolve modals.

  Before extraction each of these hand-rolled the
  `bp-modal-overlay > bp-box.bp-modal-card > bp-panel-header +
  bp-panel-body > bp-btn-row` scaffolding and (for the deposit
  variants) the `bp-lead + bp-modal-qr + bp-secret-block`
  triplet. Now they pass a slot and a few attrs.
  """

  use Phoenix.Component

  attr(:title, :string, required: true)
  attr(:title_id, :string, default: "modal-title", doc: "id used for aria-labelledby")
  attr(:click_away, :string, required: true, doc: "phx-click-away event name")

  attr(:side_class, :string,
    default: nil,
    doc: "optional side-accent class on the card (e.g. `pw-trade-modal-yes`)"
  )

  slot(:header_action, doc: "optional right-side element in the header (e.g. countdown timer)")
  slot(:inner_block, required: true)

  def modal(assigns) do
    ~H"""
    <div
      id={"#{@title_id}-overlay"}
      class="bp-modal-overlay"
      phx-hook="ModalFocusTrap"
      data-close-event={@click_away}
    >
      <div
        class={["bp-modal-card", @side_class]}
        role="dialog"
        aria-modal="true"
        aria-labelledby={@title_id}
        phx-click-away={@click_away}
      >
        <div class="bp-panel-header">
          <h2 id={@title_id} class="bp-panel-title">{@title}</h2>
          {render_slot(@header_action)}
        </div>
        <div class="bp-panel-body bp-stack">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  attr(:subaddress, :string, required: true)
  attr(:copy_button_id, :string, required: true)
  attr(:copy_aria_label, :string, default: "Copy deposit address")

  attr(:monero_status, :atom,
    default: :ok,
    doc:
      "Current Monero RPC pip status — when not :ok, the block renders " <>
        "a confirmation-tracking-paused notice so the user knows the " <>
        "deposit is safe but credit may be delayed."
  )

  attr(:amount_piconeros, :integer,
    default: nil,
    doc:
      "Amount expected at the deposit address. When provided, the QR " <>
        "encodes a `monero:` URI with `tx_amount` so the user's wallet " <>
        "pre-fills the amount on scan instead of just the address."
  )

  attr(:show_copy, :boolean,
    default: true,
    doc:
      "Renders a Copy button alongside the address text. Disabled for " <>
        "creator-liquidity contexts where the QR-and-text combination is " <>
        "the intended interaction — paying-from-cold-wallet flows scan, " <>
        "and the address is select-copyable as a fallback."
  )

  attr(:payment_observed, :boolean,
    default: false,
    doc:
      "When true (e.g. once the deposit hits the mempool but isn't yet " <>
        "confirmed), the QR is greyed and a PAYMENT DETECTED badge " <>
        "appears beneath the lead so the user knows further sends are " <>
        "unnecessary."
  )

  slot(:lead, required: true, doc: "the lead paragraph above the QR")

  def deposit_block(assigns) do
    ~H"""
    {render_slot(@lead)}

    <div :if={@monero_status != :ok} class="bp-color-warn bp-callout" role="alert">
      <strong>Confirmation tracking paused.</strong> Your Monero deposit is safe — we'll credit it as soon as our
      wallet connection recovers. No action needed.
    </div>

    <div :if={@payment_observed} class="bp-color-accent bp-callout" role="status">
      <strong>Payment detected.</strong> Waiting for confirmation.
    </div>

    <div class={"bp-modal-qr #{if @payment_observed, do: "bp-modal-qr-faded"}"} aria-hidden="true">
      {Phoenix.HTML.raw(qr_svg(monero_uri(@subaddress, @amount_piconeros)))}
    </div>

    <div :if={@show_copy} class="bp-copy-block">
      <code class="bp-secret-block">{@subaddress}</code>
      <button
        type="button"
        id={@copy_button_id}
        class="bp-btn bp-btn-default bp-copy-btn"
        phx-hook="CopyOnClick"
        data-copy-text={@subaddress}
        aria-label={@copy_aria_label}
      >
        Copy
      </button>
    </div>

    <code :if={not @show_copy} class="bp-secret-block">{@subaddress}</code>
    """
  end

  defp qr_svg(text) when is_binary(text) do
    text
    |> EQRCode.encode()
    |> EQRCode.svg(width: 220, viewbox: true)
  end

  # Monero URI per BIP-style spec: `monero:<address>?tx_amount=<xmr_decimal>`.
  # Wallets that recognise the scheme pre-fill the amount on scan; wallets
  # that don't still extract the address. Amount is rendered with up to
  # 12 decimal places (full piconero precision), trailing zeros trimmed.
  defp monero_uri(address, nil), do: address

  defp monero_uri(address, amount_piconeros)
       when is_integer(amount_piconeros) and amount_piconeros > 0 do
    "monero:" <> address <> "?tx_amount=" <> piconeros_to_decimal(amount_piconeros)
  end

  defp piconeros_to_decimal(amount_piconeros) do
    whole = div(amount_piconeros, 1_000_000_000_000)
    frac = rem(amount_piconeros, 1_000_000_000_000)

    case frac do
      0 -> Integer.to_string(whole)
      _ -> Integer.to_string(whole) <> "." <> trim_frac(frac)
    end
  end

  defp trim_frac(frac) do
    frac
    |> Integer.to_string()
    |> String.pad_leading(12, "0")
    |> String.trim_trailing("0")
  end
end
