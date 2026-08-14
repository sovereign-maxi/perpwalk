defmodule PerpWalk.Markets.Categories do
  @moduledoc """
  Fixed list of allowed market categories.

  Categories are part of the published surface and exhibit a closed
  set: users select from this list when creating a market and the
  browse UI groups markets by these labels. Adding or removing a
  category is a deliberate, code-level change.
  """

  # --- Categories ---

  @categories [
    :politics,
    :crypto,
    :finance,
    :sports,
    :entertainment,
    :science_tech,
    :culture
  ]

  # --- Public API ---

  @doc "Returns the canonical list of category atoms."
  @spec all() :: [atom()]
  def all, do: @categories

  @doc "Returns true if `category` is one of the canonical categories."
  @spec valid?(term()) :: boolean()
  def valid?(category), do: category in @categories
end
