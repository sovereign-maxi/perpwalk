defmodule PerpWalkWeb.Live.Components.Badges do
  @moduledoc """
  Atomic pill primitives for the Markets surfaces:

  - `category_badge/1` — category label rendered as `bp-pill.active`
    (brand-orange highlight).
  - `state_label/1` — market lifecycle state pill rendered with
    severity variants (`active` / `muted` / `critical`) on the
    same `bp-pill` chrome.
  - `side_pill/1` — YES/NO position side pill, variant comes from
    `Helpers.side_label_variant/1`.
  - `position_status_pill/1` — position lifecycle status pill,
    variant + label come from `Helpers.position_status_*`.

  All render the universal pill chrome — same look as the filter
  buttons on `/markets` — so categorisation, state, side, and
  filters all share one visual vocabulary. Styling lives in
  `priv/static/assets/app.css`.
  """

  use Phoenix.Component

  alias PerpWalk.Markets.Market
  alias PerpWalkWeb.Live.Helpers

  attr(:category, :atom, required: true, doc: "category atom from PerpWalk.Markets.Categories")

  def category_badge(assigns) do
    ~H"""
    <span class="bp-pill active">
      {Helpers.category_label(@category)}
    </span>
    """
  end

  attr(:market, Market, required: true)

  def state_label(assigns) do
    {label, variant} = Helpers.state_label(assigns.market)

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:variant, variant)

    ~H"""
    <span class={"bp-pill #{@variant}"}>{@label}</span>
    """
  end

  attr(:side, :atom, required: true, doc: ":yes or :no")

  def side_pill(assigns) do
    ~H"""
    <span class={"bp-pill #{Helpers.side_label_variant(@side)}"}>
      {@side |> Atom.to_string() |> String.upcase()}
    </span>
    """
  end

  attr(:status, :atom, required: true, doc: "position lifecycle status atom")

  def position_status_pill(assigns) do
    ~H"""
    <span class={"bp-pill #{Helpers.position_status_variant(@status)}"}>
      {Helpers.position_status_label(@status)}
    </span>
    """
  end
end
