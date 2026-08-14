defmodule PerpWalk.Reserves.Snapshot do
  @moduledoc """
  Single translation point between Vault's unit-agnostic snapshot
  fields (`:total_held`, `:outstanding`) and PERP WALK's
  `_piconeros`-keyed public surface.

  Vault itself does no unit interpretation — it just sums, compares,
  and serializes whatever atomic integer the host application
  supplies. PERP WALK is piconero-denominated (1 XMR =
  1_000_000_000_000 piconero); we rename the fields at this seam so
  every public surface speaks the right unit.

  ## Invariant

  Every public-facing surface — the `/api/reserves` HTTP endpoint,
  the NIP-33 Nostr event content, the admin solvency widget — calls
  `to_piconeros/1` to obtain a piconero-keyed map. No public
  surface reads `Vault.Snapshot` fields directly. This is the
  single place that knows the translation.

  ## Why not a struct

  Returning a plain map keeps the helper trivially serialisable for
  JSON and Jason encoding, and avoids forcing every caller to alias
  a new struct. The shape is documented via `@type t`.
  """

  @typedoc """
  Reserve ratio. `:infinity` when liabilities are zero — preserved
  as the upstream atom so each downstream surface can render it in
  its own conventions (HTTP JSON emits `1.0` for infinity, the
  Nostr event content emits the string `"infinity"`, etc.).
  """
  @type ratio :: :infinity | number()

  @type t :: %{
          ratio: ratio(),
          held_piconeros: non_neg_integer(),
          outstanding_piconeros: non_neg_integer(),
          delta_piconeros: integer(),
          captured_at: DateTime.t() | nil,
          metadata: map(),
          asset_ids: [binary()]
        }

  @doc """
  Translates a `Vault.Snapshot` (or any map carrying the same
  `:total_held` / `:outstanding` fields) into the piconero-keyed
  shape used by every PERP WALK public surface.

  `nil` input yields the empty/zero shape so callers can chain
  `Vault.Generator.latest() |> Map.get(:snapshot) |> to_piconeros/1`
  without a pre-check.
  """
  @spec to_piconeros(map() | nil) :: t()
  def to_piconeros(nil), do: empty()

  def to_piconeros(%{total_held: held, outstanding: outstanding} = snap)
      when is_integer(held) and is_integer(outstanding) do
    %{
      ratio: Map.get(snap, :reserve_ratio, 1.0),
      held_piconeros: held,
      outstanding_piconeros: outstanding,
      delta_piconeros: held - outstanding,
      captured_at: Map.get(snap, :captured_at),
      metadata: Map.get(snap, :metadata, %{}),
      asset_ids: Map.get(snap, :asset_ids, [])
    }
  end

  def to_piconeros(_), do: empty()

  @doc """
  Solvency percentage clamped to `[0, 999]`. `999` represents
  "effectively infinite coverage" (outstanding == 0 or held vastly
  exceeds outstanding) — same cap the admin dashboard renders
  rather than the literal arithmetic value.
  """
  @spec solvency_pct(t()) :: non_neg_integer()
  def solvency_pct(%{held_piconeros: _, outstanding_piconeros: 0}), do: 999

  def solvency_pct(%{held_piconeros: held, outstanding_piconeros: outstanding})
      when is_integer(held) and is_integer(outstanding) and outstanding > 0 do
    min(round(held / outstanding * 100), 999)
  end

  def solvency_pct(_), do: 0

  defp empty do
    %{
      ratio: 1.0,
      held_piconeros: 0,
      outstanding_piconeros: 0,
      delta_piconeros: 0,
      captured_at: nil,
      metadata: %{},
      asset_ids: []
    }
  end
end
