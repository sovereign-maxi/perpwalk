defmodule PerpWalk.Sim.Reporter do
  @moduledoc """
  Produces the post-run summary report.

  Pulls a snapshot from `PerpWalk.Sim.Metrics`, the markets +
  federation state from the live stores, and any invariant
  violations recorded during the run. Outputs as a structured
  map; callers can `Jason.encode!/1` to serialize for log output
  or write to disk.

  Pure module — no GenServer state. Read-only.
  """

  alias PerpWalk.Federation.Facade, as: FederationFacade
  alias PerpWalk.Markets.Facade, as: MarketsFacade
  alias PerpWalk.Sim.Metrics

  @type summary :: %{
          required(:counters) => %{term() => integer()},
          required(:markets) => map(),
          required(:positions) => map(),
          required(:disputes) => map(),
          required(:payouts) => map(),
          required(:federation_ledger) => map(),
          required(:invariants) => map(),
          required(:run) => map()
        }

  # --- Public API ---

  @doc """
  Builds the run summary. Pass `run_meta` (seed, scenario,
  duration, etc.) so the report includes the run's identity, and
  `violations` (a list of invariant-violation tuples recorded by
  the validator).
  """
  @spec build(keyword(), [term()]) :: summary()
  def build(run_meta, violations) do
    %{
      counters: Metrics.snapshot(),
      markets: market_summary(),
      positions: position_summary(),
      disputes: dispute_summary(),
      payouts: payout_summary(),
      federation_ledger: federation_ledger_summary(),
      invariants: invariant_summary(violations),
      run: Map.new(run_meta)
    }
  end

  @doc "Encodes a summary as pretty JSON. Convenience for CLI output."
  @spec to_json!(summary()) :: String.t()
  def to_json!(summary) do
    summary
    |> normalize_for_json()
    |> Jason.encode!(pretty: true)
  end

  # --- Internal ---

  defp market_summary do
    markets = MarketsFacade.list_markets()

    %{
      total: length(markets),
      by_status: Enum.frequencies_by(markets, & &1.status)
    }
  end

  defp position_summary do
    positions = MarketsFacade.list_all_positions()

    %{
      total: length(positions),
      by_status: Enum.frequencies_by(positions, & &1.status)
    }
  end

  defp dispute_summary do
    disputes = MarketsFacade.list_disputes()

    %{
      total: length(disputes),
      by_status: Enum.frequencies_by(disputes, & &1.status)
    }
  end

  defp payout_summary do
    payouts = FederationFacade.list_requests()

    %{
      total: length(payouts),
      by_status: Enum.frequencies_by(payouts, & &1.status),
      by_kind: Enum.frequencies_by(payouts, & &1.kind)
    }
  end

  defp federation_ledger_summary do
    MarketsFacade.federation_ledger()
  end

  defp invariant_summary(violations) do
    %{
      passed: violations == [],
      violation_count: length(violations),
      violations: violations
    }
  end

  # Atom keys and atom-tuple keys aren't directly JSON-friendly.
  # Walk the structure once and stringify everything that isn't a
  # primitive. Keeps the report readable when piped to `jq`.
  defp normalize_for_json(%DateTime{} = dt), do: dt
  defp normalize_for_json(%Date{} = d), do: d
  defp normalize_for_json(%NaiveDateTime{} = ndt), do: ndt
  defp normalize_for_json(%Time{} = t), do: t

  defp normalize_for_json(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> normalize_for_json()
  end

  defp normalize_for_json(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {stringify(k), normalize_for_json(v)} end)
  end

  defp normalize_for_json(value) when is_list(value) do
    Enum.map(value, &normalize_for_json/1)
  end

  defp normalize_for_json(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&normalize_for_json/1)
  end

  defp normalize_for_json(value) when is_atom(value) and not is_nil(value) and value not in [true, false] do
    Atom.to_string(value)
  end

  # Raw binaries (Monero txids, Nostr event ids, signature bytes, etc.)
  # aren't guaranteed UTF-8 and will crash `Jason.encode!/1`. Hex-encode
  # anything that isn't valid UTF-8 so the report survives regardless
  # of what sneaks into a violation payload.
  defp normalize_for_json(value) when is_binary(value) do
    if String.valid?(value), do: value, else: Base.encode16(value, case: :lower)
  end

  defp normalize_for_json(value), do: value

  defp stringify(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify(key) when is_binary(key), do: key
  defp stringify(key) when is_tuple(key), do: key |> Tuple.to_list() |> Enum.map_join(":", &stringify/1)
  defp stringify(key), do: inspect(key)
end
