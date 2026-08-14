defmodule PerpWalk.TestHelpers.MarketsHelpers do
  @moduledoc """
  Test setup helpers for the Markets domain.

  Provides `start_isolated_store/0` — boots a `Locker.WAL` against a
  unique tmp directory and a `PerpWalk.Markets.Store` against unique
  ETS table names, registering an `on_exit` callback to tear them down.
  Returns a context map ready to merge into an ExUnit test context:

      setup do
        MarketsHelpers.start_isolated_store()
      end

  The returned map has `:store`, `:wal`, `:wal_dir`, and `:tables`
  (with `:markets`, `:positions`, `:votes` table-name atoms).
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias PerpWalk.Markets.{AMM, Dispute, Facade, Market, Quote, Store, Vote}
  alias PerpWalk.Markets.Services.{Maker, Trader}
  alias PerpWalk.TestHelpers.ProcessHelpers

  @doc "Starts an isolated WAL + Store pair. Returns an ExUnit-style context map."
  @spec start_isolated_store() :: %{
          store: atom(),
          wal: atom(),
          wal_dir: binary(),
          tables: %{
            markets: atom(),
            positions: atom(),
            votes: atom(),
            quotes: atom(),
            disputes: atom()
          }
        }
  def start_isolated_store do
    suffix = :erlang.unique_integer([:positive, :monotonic])

    wal_dir = Path.join(System.tmp_dir!(), "perpwalk_store_wal_#{suffix}")
    File.mkdir_p!(wal_dir)

    wal_name = :"wal_#{suffix}"
    store_name = :"store_#{suffix}"
    test_marker = "Test#{suffix}"

    tables = %{
      markets: Module.concat(Store.Markets, test_marker),
      positions: Module.concat(Store.Positions, test_marker),
      votes: Module.concat(Store.Votes, test_marker),
      quotes: Module.concat(Store.Quotes, test_marker),
      disputes: Module.concat(Store.Disputes, test_marker),
      positions_by_market: Module.concat(Store.PositionsByMarket, test_marker),
      votes_by_market: Module.concat(Store.VotesByMarket, test_marker),
      markets_by_status: Module.concat(Store.MarketsByStatus, test_marker),
      positions_by_account: Module.concat(Store.PositionsByAccount, test_marker),
      positions_by_status: Module.concat(Store.PositionsByStatus, test_marker),
      disputes_by_market: Module.concat(Store.DisputesByMarket, test_marker),
      disputes_by_account: Module.concat(Store.DisputesByAccount, test_marker),
      quotes_by_market: Module.concat(Store.QuotesByMarket, test_marker),
      quotes_by_account: Module.concat(Store.QuotesByAccount, test_marker),
      markets_by_category: Module.concat(Store.MarketsByCategory, test_marker),
      markets_by_creator: Module.concat(Store.MarketsByCreator, test_marker),
      disputes_by_status: Module.concat(Store.DisputesByStatus, test_marker),
      quotes_by_subaddress: Module.concat(Store.QuotesBySubaddress, test_marker),
      disputes_by_subaddress: Module.concat(Store.DisputesBySubaddress, test_marker),
      markets_by_subaddress: Module.concat(Store.MarketsBySubaddress, test_marker),
      ledger_counters: Module.concat(Store.LedgerCounters, test_marker)
    }

    {:ok, wal_pid} =
      Locker.WAL.start_link(
        name: wal_name,
        wal_dir: wal_dir,
        types: PerpWalk.Storage.WAL.type_map()
      )

    {:ok, store_pid} =
      Store.start_link(
        name: store_name,
        wal_server: wal_name,
        markets_table: tables.markets,
        positions_table: tables.positions,
        votes_table: tables.votes,
        quotes_table: tables.quotes,
        disputes_table: tables.disputes,
        positions_by_market_table: tables.positions_by_market,
        votes_by_market_table: tables.votes_by_market,
        markets_by_status_table: tables.markets_by_status,
        positions_by_account_table: tables.positions_by_account,
        positions_by_status_table: tables.positions_by_status,
        disputes_by_market_table: tables.disputes_by_market,
        disputes_by_account_table: tables.disputes_by_account,
        quotes_by_market_table: tables.quotes_by_market,
        quotes_by_account_table: tables.quotes_by_account,
        markets_by_category_table: tables.markets_by_category,
        markets_by_creator_table: tables.markets_by_creator,
        disputes_by_status_table: tables.disputes_by_status,
        quotes_by_subaddress_table: tables.quotes_by_subaddress,
        disputes_by_subaddress_table: tables.disputes_by_subaddress,
        markets_by_subaddress_table: tables.markets_by_subaddress,
        ledger_counters_table: tables.ledger_counters
      )

    on_exit(fn ->
      ProcessHelpers.safe_stop(store_pid)
      ProcessHelpers.safe_stop(wal_pid)
      File.rm_rf!(wal_dir)
    end)

    %{store: store_name, wal: wal_name, wal_dir: wal_dir, tables: tables}
  end

  @doc """
  Restarts the Store under the same name and tables, leaving the WAL
  running so `init/1` replays the prior writes. Returns the new pid.
  """
  @spec restart_store(map()) :: pid()
  def restart_store(%{store: store_name, wal: wal_name, tables: tables}) do
    ProcessHelpers.safe_stop(store_name)

    {:ok, pid} =
      Store.start_link(
        name: store_name,
        wal_server: wal_name,
        markets_table: tables.markets,
        positions_table: tables.positions,
        votes_table: tables.votes,
        quotes_table: tables.quotes,
        disputes_table: tables.disputes,
        positions_by_market_table: tables.positions_by_market,
        votes_by_market_table: tables.votes_by_market,
        markets_by_status_table: tables.markets_by_status,
        positions_by_account_table: tables.positions_by_account,
        positions_by_status_table: tables.positions_by_status,
        disputes_by_market_table: tables.disputes_by_market,
        disputes_by_account_table: tables.disputes_by_account,
        quotes_by_market_table: tables.quotes_by_market,
        quotes_by_account_table: tables.quotes_by_account,
        markets_by_category_table: tables.markets_by_category,
        markets_by_creator_table: tables.markets_by_creator,
        disputes_by_status_table: tables.disputes_by_status,
        quotes_by_subaddress_table: tables.quotes_by_subaddress,
        disputes_by_subaddress_table: tables.disputes_by_subaddress,
        markets_by_subaddress_table: tables.markets_by_subaddress,
        ledger_counters_table: tables.ledger_counters
      )

    pid
  end

  @doc """
  Returns a `Market.t()` built from sensible defaults, with optional
  keyword overrides. Defaults to `:pending` status (post-deposit-
  confirmation) for tests that just need a listable market.

  Bypasses the Maker, so this helper supplies the operator-dial keys
  (`:unit_size`, `:pool`, `:deposit_amount`, `:resolution_deadline`)
  that `Market.new/1` requires — pulled from `:perpwalk, :markets`
  config so test and prod stay aligned. Per-test overrides for any
  of those are still honoured via the `overrides` keyword.
  """
  @spec build_market(keyword()) :: Market.t()
  def build_market(overrides \\ []) do
    base = market_opts(overrides)
    expiry = Keyword.fetch!(base, :expiry)

    unit_size = markets_config(:unit_size_piconeros, 10_000_000_000)
    deposit = markets_config(:min_deposit_piconeros, 1_000_000_000_000)
    pool_depth = div(deposit, unit_size)

    opts =
      base
      |> Keyword.put_new(:unit_size, unit_size)
      |> Keyword.put_new(:pool, AMM.new(pool_depth, pool_depth))
      |> Keyword.put_new(:deposit_amount, deposit)
      |> Keyword.put_new(
        :resolution_deadline,
        DateTime.add(expiry, markets_config(:resolution_window_seconds, 86_400), :second)
      )
      |> Keyword.merge(Keyword.take(overrides, [:unit_size, :pool, :deposit_amount, :resolution_deadline]))
      |> Keyword.put_new(:deposit_subaddress, "test-subaddr-#{System.unique_integer([:positive])}")
      |> Keyword.put_new(:deposit_subaddress_index, System.unique_integer([:positive]))
      |> Keyword.put_new(:status, :pending)

    {:ok, market} = Market.new(opts)
    market
  end

  @doc """
  Default `Maker.create_market/1` opts as a keyword list, with
  overrides applied. `:unit_size`, `:pool`, and `:resolution_deadline`
  are operator dials in `:perpwalk, :markets` config and are rejected
  if passed here — set the config in your test setup if you need to
  vary them. `:deposit_amount` IS caller-tunable within operator-set
  bounds; passing it here forwards to Maker.
  """
  @spec market_opts(keyword()) :: keyword()
  def market_opts(overrides \\ []) do
    [
      description: "Will Trump pardon Snowden by July 4 2026?",
      resolution_criterion:
        "Resolves YES if a presidential pardon is officially issued for Edward Snowden " <>
          "before 2026-07-04 23:59:59 UTC, as reported by primary White House communications " <>
          "or major news outlets (Reuters, AP, BBC).",
      category: :politics,
      expiry: DateTime.add(DateTime.utc_now(), 86_400, :second),
      creator_account_id: "creator-hash"
    ]
    |> Keyword.merge(Keyword.drop(overrides, [:unit_size, :pool, :resolution_deadline]))
  end

  defp markets_config(key, default) do
    :perpwalk |> Application.get_env(:markets, []) |> Keyword.get(key, default)
  end

  @doc """
  Stubs a subaddress provider for `Maker.create_market/1`. Tests
  that go through the Maker (rather than `Market.new/1` directly)
  should call this in their setup.
  """
  @spec stub_subaddress_provider() :: :ok
  def stub_subaddress_provider do
    Application.put_env(
      :perpwalk,
      :subaddress_provider,
      fn ->
        idx = System.unique_integer([:positive])
        {:ok, %{address: "test_addr_#{idx}_" <> String.duplicate("a", 80), address_index: idx}}
      end
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:perpwalk, :subaddress_provider)
    end)

    :ok
  end

  @doc """
  Drives a market from `:awaiting_deposit` to `:pending` by
  confirming its creation deposit. Convenience helper for tests
  that need a `:pending` market produced via the full Maker flow.
  """
  @spec confirm_deposit!(Market.t()) :: Market.t()
  def confirm_deposit!(%Market{} = market) do
    {:ok, confirmed} = Maker.confirm_deposit(market.id)
    confirmed
  end

  @doc """
  Creates a market via `Maker.create_market/1` AND confirms its
  creation deposit, returning a `:pending` market. Most tests that
  need to exercise downstream logic want this — only the maker's
  own tests should care about the intermediate `:awaiting_deposit`
  state.
  """
  @spec pending_market!(keyword()) :: Market.t()
  def pending_market!(overrides \\ []) do
    {:ok, raw} = Maker.create_market(market_opts(overrides))
    confirmed = confirm_deposit!(raw)

    # Maker derives `resolution_deadline` from `expiry +
    # :resolution_window_seconds` and refuses any caller-supplied
    # value. Tests that need a deliberately past deadline (auto-void
    # scenarios, scheduler edge cases) pass it as an override here;
    # we patch it onto the persisted market post-create so the rest
    # of the Maker flow is exercised normally.
    case Keyword.fetch(overrides, :resolution_deadline) do
      :error ->
        confirmed

      {:ok, deadline} ->
        patched = %{confirmed | resolution_deadline: deadline}
        :ok = Store.put_market(patched)
        patched
    end
  end

  @doc "Builds a `Vote.t()` with the given `account_id`, `market_id`, and direction."
  @spec build_vote(binary(), binary(), :up | :down) :: Vote.t()
  def build_vote(account_id, market_id, direction) do
    Vote.new(account_id, market_id, direction)
  end

  @doc """
  Simulates the full dispute flow synchronously: start the dispute,
  then confirm the deposit. Returns the `:live` dispute. Use this
  in tests that just need a funded dispute on a market without
  driving the Monero poller / RPC machinery.

  If the disputing account doesn't already hold a position on the
  market, a 1-contract YES position is opened first so the dispute
  passes `Disputer.ensure_has_traded`. Tests that specifically want
  to exercise the "must have traded" refusal should call
  `Facade.start_dispute/2` directly with a fresh account.
  """
  @spec dispute!(binary(), binary()) :: Dispute.t()
  def dispute!(account_id, market_id) do
    :ok = ensure_traded(account_id, market_id)
    {:ok, _pending} = Facade.start_dispute(account_id, market_id)
    {:ok, live} = Facade.confirm_dispute_deposit(account_id, market_id)
    live
  end

  defp ensure_traded(account_id, market_id) do
    market_id
    |> Store.list_positions_for_market()
    |> Enum.any?(&(&1.account_id == account_id))
    |> case do
      true -> :ok
      false -> place_minimal_position(account_id, market_id)
    end
  end

  defp place_minimal_position(account_id, market_id) do
    case Trader.place_position(account_id, market_id, :yes, 1) do
      {:ok, _position} -> :ok
      {:error, :market_not_active} -> :ok
      other -> raise "dispute!: failed to seed position: #{inspect(other)}"
    end
  end

  @doc """
  Returns a `Quote.t()` built from sensible defaults, with optional
  keyword overrides. Useful for tests that just need a quote in
  flight without going through the full Trader flow.
  """
  @spec build_quote(keyword()) :: Quote.t()
  def build_quote(overrides \\ []) do
    now = DateTime.utc_now()

    [
      market_id: "market-id",
      account_id: "account-hash",
      side: :yes,
      contracts: 5,
      amount_paid_piconeros: 50_000_000_000,
      spread_piconeros: 0,
      subaddress: "8aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899",
      subaddress_index: 1,
      refund_address: refund_address_stub(),
      expires_at: DateTime.add(now, 1800, :second)
    ]
    |> Keyword.merge(overrides)
    |> Quote.new()
  end

  @doc """
  A valid mainnet Monero primary address for use in tests that need to
  pass `PerpWalk.Monero.Address.valid?/1` — for example any test that
  goes through `Trader.create_quote/5` (refund_address is required
  per-quote) or `Federation.Rules.destination_sanity` (payout
  destination check). The address is a real-shape 95-char mainnet
  address from `test/integration/perp_walk/monero/address_test.exs`.
  """
  @spec refund_address_stub() :: String.t()
  def refund_address_stub,
    do: "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge"

  @doc """
  Test convenience: runs the real `Resolver.activate/1` on a market
  and unwraps the `{:ok, _}`. Use when a test just needs an
  `:active` market and doesn't care about the activation event.
  """
  @spec activate!(Market.t()) :: Market.t()
  def activate!(%Market{id: id}) do
    {:ok, market} = PerpWalk.Markets.Services.Resolver.activate(id)
    market
  end
end
