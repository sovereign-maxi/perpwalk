defmodule PerpWalk.Federation.RulesTest do
  @moduledoc "Unit tests for the deterministic Federation.Rules engine."

  use ExUnit.Case, async: true

  alias PerpWalk.Federation.{Payout, Rules}
  alias PerpWalk.Markets.{AMM, Market, Position}

  @piconero 1_000_000_000_000

  defp market(opts \\ []) do
    pool = Keyword.get(opts, :pool, AMM.new(AMM.to_subunits(100), AMM.to_subunits(100)))

    %Market{
      id: Keyword.get(opts, :id, "market-1"),
      description: "Test",
      resolution_criterion: "Test resolution criterion",
      category: :crypto,
      unit_size: Keyword.get(opts, :unit_size, @piconero),
      expiry: DateTime.utc_now(),
      resolution_deadline: DateTime.utc_now(),
      status: Keyword.get(opts, :status, :settled),
      pool: pool,
      creator_account_id: "creator",
      deposit_amount: @piconero,
      reputation: 0,
      created_at: DateTime.utc_now(),
      outcome: Keyword.get(opts, :outcome, :yes)
    }
  end

  defp position(opts \\ []) do
    %Position{
      id: Keyword.get(opts, :id, "pos-1"),
      market_id: Keyword.get(opts, :market_id, "market-1"),
      account_id: "acct-1",
      side: Keyword.get(opts, :side, :yes),
      contracts: Keyword.get(opts, :contracts, 5),
      amount_paid: Keyword.get(opts, :amount_paid, 5 * @piconero),
      spread_piconeros: Keyword.get(opts, :spread_piconeros, 0),
      status: Keyword.get(opts, :status, :settled_winner),
      created_at: DateTime.utc_now(),
      settled_at: DateTime.utc_now()
    }
  end

  defp request(position, opts \\ []) do
    amount = Keyword.get(opts, :amount, position.contracts * @piconero)
    destination = Keyword.get(opts, :destination, "4" <> String.duplicate("A", 94))
    Payout.new(position, amount, destination)
  end

  defp ctx(opts \\ []) do
    position_opts =
      Keyword.take(opts, [:position_status, :side, :contracts])
      |> Keyword.new(fn
        {:position_status, v} -> {:status, v}
        kv -> kv
      end)

    market_opts =
      Keyword.take(opts, [:market_status, :outcome, :unit_size, :pool, :market_id])
      |> Keyword.new(fn
        {:market_status, v} -> {:status, v}
        {:market_id, v} -> {:id, v}
        kv -> kv
      end)

    pos = position(position_opts)
    mkt = market(market_opts)
    req = request(pos, Keyword.take(opts, [:amount, :destination]))

    %{
      request: req,
      position: pos,
      market: mkt,
      now: Keyword.get(opts, :now, DateTime.utc_now()),
      recent_requests: Keyword.get(opts, :recent_requests, []),
      config: Keyword.get(opts, :config, [])
    }
  end

  describe "evaluate/1 — happy path" do
    test "settled-winner payout passes all rules" do
      assert :ok = Rules.evaluate(ctx())
    end

    test "refund payout passes all rules" do
      pos = position(status: :refunded)
      mkt = market(status: :voided)
      req = request(pos, amount: pos.amount_paid)

      assert :ok =
               Rules.evaluate(%{
                 request: req,
                 position: pos,
                 market: mkt,
                 now: DateTime.utc_now()
               })
    end
  end

  describe "amount_match" do
    test "passes when amount matches Position.payout exactly" do
      assert :ok = Rules.amount_match(ctx())
    end

    test "rejects when amount is wrong" do
      assert {:reject, reason} = Rules.amount_match(ctx(amount: 1))
      assert reason =~ "amount_match"
    end
  end

  describe "position_status" do
    test "winner_payout requires :settled_winner" do
      assert :ok = Rules.position_status(ctx())

      # Build directly since Position with non-payable status can't go through Payout.new.
      pos_open = position(status: :open)
      good_req = request(position(status: :settled_winner))

      bad_ctx_for = fn pos ->
        %{
          request: %{good_req | position_id: pos.id},
          position: pos,
          market: market(),
          now: DateTime.utc_now()
        }
      end

      assert {:reject, _} = Rules.position_status(bad_ctx_for.(pos_open))
      assert {:reject, _} = Rules.position_status(bad_ctx_for.(position(status: :paid_out)))
      assert {:reject, _} = Rules.position_status(bad_ctx_for.(position(status: :settled_loser)))
    end

    test "refund requires :refunded" do
      pos = position(status: :refunded)
      mkt = market(status: :voided)

      ok_ctx = %{request: request(pos), position: pos, market: mkt, now: DateTime.utc_now()}
      assert :ok = Rules.position_status(ok_ctx)

      bad_pos = position(status: :settled_winner)

      bad_ctx = %{
        request: %{request(bad_pos) | kind: :refund},
        position: bad_pos,
        market: mkt,
        now: DateTime.utc_now()
      }

      assert {:reject, _} = Rules.position_status(bad_ctx)
    end
  end

  describe "market_status" do
    test "winner_payout requires :settled market" do
      assert :ok = Rules.market_status(ctx(market_status: :settled))

      assert {:reject, _} = Rules.market_status(ctx(market_status: :active))
      assert {:reject, _} = Rules.market_status(ctx(market_status: :voided))
    end
  end

  describe "destination_sanity" do
    test "passes for a well-formed Monero address" do
      assert :ok = Rules.destination_sanity(ctx(destination: "4" <> String.duplicate("A", 94)))
      assert :ok = Rules.destination_sanity(ctx(destination: "8" <> String.duplicate("A", 94)))
    end

    test "rejects empty / too-short destination" do
      assert {:reject, _} = Rules.destination_sanity(ctx(destination: "abc"))
    end

    test "rejects 95-char string with wrong prefix" do
      # right length, wrong starting character — caught by regex.
      assert {:reject, reason} =
               Rules.destination_sanity(ctx(destination: String.duplicate("a", 95)))

      assert reason =~ "well-formed"
    end

    test "rejects address containing non-base58 characters" do
      # Length OK, prefix OK, but `0` is not in the base58 alphabet.
      bad = "4" <> String.duplicate("0", 94)
      assert {:reject, _} = Rules.destination_sanity(ctx(destination: bad))
    end

    test "rejects pathologically long input before regex match" do
      assert {:reject, reason} =
               Rules.destination_sanity(ctx(destination: String.duplicate("4", 5_000)))

      assert reason =~ "too long"
    end
  end

  describe "cooldown_threshold" do
    test "small payouts pass without waiting" do
      small = 1 * @piconero

      assert :ok =
               Rules.cooldown_threshold(ctx(amount: small, config: [cooldown_threshold_piconeros: 10 * @piconero]))
    end

    test "large payouts must age at least cooldown_seconds" do
      large = 100 * @piconero
      pos = position()
      req = request(pos, amount: large)

      # Just-created request — 0 age, fails cooldown
      ctx_now = %{
        request: req,
        position: pos,
        market: market(),
        now: DateTime.utc_now(),
        config: [cooldown_threshold_piconeros: large, cooldown_seconds: 600],
        recent_requests: []
      }

      assert {:reject, reason} = Rules.cooldown_threshold(ctx_now)
      assert reason =~ "cooldown_threshold"

      # Same request 600s later — passes
      future = DateTime.add(req.created_at, 600, :second)

      assert :ok =
               Rules.cooldown_threshold(%{
                 request: req,
                 position: pos,
                 market: market(),
                 now: future,
                 config: [cooldown_threshold_piconeros: large, cooldown_seconds: 600]
               })
    end
  end

  describe "rate_cap_global" do
    test "passes under cap" do
      assert :ok = Rules.rate_cap_global(ctx())
    end

    test "rejects when projected total exceeds cap" do
      cap = 10 * @piconero
      cur_amount = 6 * @piconero
      prev_amount = 5 * @piconero

      pos = position(contracts: 6)
      req = request(pos, amount: cur_amount)
      prev = request(position(id: "pos-prev", contracts: 5), amount: prev_amount)

      ctx = %{
        request: req,
        position: pos,
        market: market(),
        now: DateTime.utc_now(),
        recent_requests: [prev],
        config: [rate_cap_global_piconeros: cap]
      }

      assert {:reject, reason} = Rules.rate_cap_global(ctx)
      assert reason =~ "rate_cap_global"
    end

    test "ignores requests outside the rate window" do
      cap = 10 * @piconero
      pos = position(contracts: 6)
      req = request(pos, amount: 6 * @piconero)
      old_prev = request(position(id: "pos-prev", contracts: 5), amount: 5 * @piconero)

      # Backdate the older request beyond the 1h window
      old_prev = %{old_prev | updated_at: DateTime.add(req.created_at, -7_200, :second)}

      ctx = %{
        request: req,
        position: pos,
        market: market(),
        now: DateTime.utc_now(),
        recent_requests: [old_prev],
        config: [rate_cap_global_piconeros: cap]
      }

      assert :ok = Rules.rate_cap_global(ctx)
    end

    test "doesn't count :failed requests against the cap" do
      cap = 10 * @piconero
      pos = position(contracts: 6)
      req = request(pos, amount: 6 * @piconero)

      failed_prev = request(position(id: "pos-prev", contracts: 5), amount: 5 * @piconero)
      {:ok, failed_prev} = Payout.mark_failed(failed_prev, "test")

      ctx = %{
        request: req,
        position: pos,
        market: market(),
        now: DateTime.utc_now(),
        recent_requests: [failed_prev],
        config: [rate_cap_global_piconeros: cap]
      }

      assert :ok = Rules.rate_cap_global(ctx)
    end
  end

  describe "evaluate/1 — fail-fast ordering" do
    test "returns first failure" do
      # Set up a request that violates BOTH amount_match (first) and
      # destination_sanity (later). amount_match should win.
      pos = position()
      req = request(pos, amount: 1, destination: "x")

      result =
        Rules.evaluate(%{
          request: req,
          position: pos,
          market: market(),
          now: DateTime.utc_now()
        })

      assert {:reject, reason} = result
      assert reason =~ "amount_match"
    end
  end

  describe "amount_match/1 — federation income" do
    # The Ledger reads from real Stores, so we only test the pure
    # rejection-shape invariants here. The integration test
    # exercises the live ledger path.

    test "rejects zero or negative amount" do
      req =
        Payout.new_federation_income(
          1,
          "4" <> String.duplicate("A", 94),
          "operator-1"
        )

      # Force a 0 amount via struct manipulation since the constructor
      # rejects it — we want to assert the rule itself catches the
      # invariant if a corrupted Payout somehow arrives.
      bad = %{req | amount_piconeros: 0}

      assert {:reject, reason} = Rules.amount_match(%{request: bad})
      assert reason =~ "federation_income"
    end
  end
end
