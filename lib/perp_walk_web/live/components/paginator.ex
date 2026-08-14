defmodule PerpWalkWeb.Live.Components.Paginator do
  @moduledoc """
  Fixed-height pagination bar pinned to the bottom of a panel.

  Renders `← PREV   N–M of T (page X / Y)   NEXT →`. Both buttons
  are disabled at the bounds. Wire `phx-click` to a handler in the
  parent LiveView; the component emits `phx-value-page` with the
  target 1-indexed page.

  ## Example

      <.paginator page={@page} total={@total} per_page={@per_page} />

      def handle_event("paginate", %{"page" => page}, socket) do
        {:noreply, assign(socket, :page, parse_page(page))}
      end

  Always rendered, even when there's only one page — keeps the
  panel layout stable when rows are added or removed.
  """

  use Phoenix.Component

  attr(:page, :integer, required: true, doc: "current 1-indexed page")
  attr(:total, :integer, required: true, doc: "total row count across all pages")
  attr(:per_page, :integer, default: 25)
  attr(:event, :string, default: "paginate", doc: "phx-click event name")
  attr(:throttle, :integer, default: 250, doc: "phx-throttle ms — drops mash clicks")

  attr(:label, :string,
    default: "results",
    doc:
      "What is being paginated (e.g. \"markets\", \"positions\"). Used to scope the `<nav aria-label>` so multiple paginators on the same page (Portfolio has three) read distinctly to assistive tech."
  )

  def paginator(assigns) do
    total = max(0, assigns.total)
    per_page = max(1, assigns.per_page)
    total_pages = max(1, div(total + per_page - 1, per_page))
    page = assigns.page |> max(1) |> min(total_pages)

    start_row = if total == 0, do: 0, else: (page - 1) * per_page + 1
    end_row = min(page * per_page, total)

    assigns =
      assigns
      |> assign(:total_pages, total_pages)
      |> assign(:current_page, page)
      |> assign(:start_row, start_row)
      |> assign(:end_row, end_row)
      |> assign(:total, total)

    ~H"""
    <nav class="bp-paginator" aria-label={"Pagination for #{@label}"}>
      <button
        type="button"
        class="bp-paginator-btn"
        phx-click={@event}
        phx-value-page={@current_page - 1}
        phx-throttle={@throttle}
        disabled={@current_page <= 1}
        aria-label="Previous page"
      >
        ◀ PREV
      </button>

      <span class="bp-paginator-status" aria-live="polite">
        <span class="bp-paginator-range">{@start_row}–{@end_row}</span>
        <span class="bp-paginator-sep">of</span>
        <span class="bp-paginator-total">{@total}</span>
        <span class="bp-paginator-page">· PAGE {@current_page} / {@total_pages}</span>
      </span>

      <button
        type="button"
        class="bp-paginator-btn"
        phx-click={@event}
        phx-value-page={@current_page + 1}
        phx-throttle={@throttle}
        disabled={@current_page >= @total_pages}
        aria-label="Next page"
      >
        NEXT ▶
      </button>
    </nav>
    """
  end

  @doc """
  Slices `rows` to the given 1-indexed `page` of size `per_page`.
  Returns the slice. The caller is responsible for clamping the
  page if the underlying list shrinks (e.g., after a filter
  change) — this function will return `[]` if the page is out of
  range, which the paginator UI displays as page 1 of 1.
  """
  @spec slice(list(), pos_integer(), pos_integer()) :: list()
  def slice(rows, page, per_page)
      when is_list(rows) and is_integer(page) and page >= 1 and is_integer(per_page) and
             per_page >= 1 do
    Enum.slice(rows, (page - 1) * per_page, per_page)
  end

  @doc """
  Returns the page number to use given the current page and the
  new total row count. Clamps to `[1, max_page]`. Use after a
  filter change or when an event changes the row count.
  """
  @spec clamp_page(integer(), non_neg_integer(), pos_integer()) :: pos_integer()
  def clamp_page(page, total, per_page) do
    max_page = max(1, div(max(0, total) + per_page - 1, per_page))
    page |> max(1) |> min(max_page)
  end
end
