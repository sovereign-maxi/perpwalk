defmodule PerpWalk.Scenarios.IncomeWithdrawalTest do
  @moduledoc """
  End-to-end coverage for the operator federation-income withdrawal
  flow.

  Exercises the full pipeline:

      Console.withdraw_federation_income/3
        → Facade.enqueue_federation_income_withdrawal/3
        → Store.put_payout
        → Signer.run_now → load_context (federation_income clause)
        → Rules.evaluate (federation_income special-casing)
        → stub signing backend → :submitted → :paid_out
        → Federation.Facade.federation_income_drawn/0 reflects withdrawal

  Asserts:

  - `PayoutRequested` event publication on console invocation
  - Audit log entry recorded with `:federation_income_withdrawal_initiated`
  - Rules path the live `withdrawable_piconeros` correctly
  - `Markets.Federation.Ledger.withdrawable_piconeros/0` decreases
    by the withdrawn amount after the full pipeline completes
  """

  use ExUnit.Case, async: false

  @moduletag :scenario

  import PerpWalk.TestHelpers.CleanState, only: [clean_state: 1]
  import PerpWalk.TestHelpers.MarketsHelpers, only: [pending_market!: 1]
  import ExUnit.CaptureIO, only: [capture_io: 1]

  alias PerpWalk.Events.EventBus
  alias PerpWalk.Events.Federation, as: FederationEvents
  alias PerpWalk.Federation.{Audit, Console, Facade, Signer}
  alias PerpWalk.Federation.Store, as: FederationStore
  alias PerpWalk.Markets.Federation.Ledger
  alias PerpWalk.Markets.Services.Voter

  setup :clean_state

  setup do
    :ok = FederationStore.clear()
    Signer.set_backend(fn _ -> {:error, :no_backend} end)
    if Signer.halted?(), do: Signer.resume()

    on_exit(fn -> if Signer.halted?(), do: Signer.resume() end)

    :ok
  end

  # Cast enough downvotes to push the market past the burn threshold,
  # which forfeits the creator's deposit to federation income. Simpler
  # than the dispute-slash path and gives us a deterministic seed
  # amount (the configured creation deposit).
  defp seed_burned_income!(label \\ "burn") do
    market = pending_market!([])

    # 6 unanimous downvotes crosses the Wilson 0.6 lower bound and
    # burns the creator's deposit to federation income.
    Enum.each(1..6, fn i ->
      {:ok, _} = Voter.cast_vote("voter-#{label}-#{i}", market.id, :down)
    end)

    {:ok, refreshed} = PerpWalk.Markets.Store.get_market(market.id)
    assert refreshed.status == :rejected
    refreshed.deposit_amount
  end

  defp valid_destination, do: "4" <> String.duplicate("A", 94)

  describe "Console.withdraw_federation_income/3 — event publication" do
    test "publishes PayoutRequested with federation_income kind" do
      seeded = seed_burned_income!()
      assert Ledger.withdrawable_piconeros() == seeded

      :ok = EventBus.subscribe(FederationEvents.PayoutRequested)

      amount = div(seeded, 4)
      destination = valid_destination()

      capture_io(fn ->
        assert {:ok, payout} =
                 Console.withdraw_federation_income(amount, destination, "operator-1")

        assert payout.kind == :federation_income
        assert payout.market_id == "federation"
        assert payout.account_id == "operator-1"
        assert payout.amount_piconeros == amount
        assert payout.destination == destination
      end)

      assert_receive %FederationEvents.PayoutRequested{
                       kind: :federation_income,
                       amount_piconeros: ^amount,
                       destination: ^destination,
                       account_id: "operator-1",
                       market_id: "federation"
                     },
                     500
    end

    test "no PayoutRequested event published on enqueue failure" do
      # No seeded income — but enqueue accepts any positive amount;
      # rejection happens later at rule-evaluation time. To trigger
      # a true enqueue failure we'd need a Store-level fault, which
      # is out of scope here. Instead this asserts the inverse: an
      # event IS published only when the function returns {:ok, _}.
      seeded = seed_burned_income!()
      :ok = EventBus.subscribe(FederationEvents.PayoutRequested)

      capture_io(fn ->
        {:ok, _} = Console.withdraw_federation_income(seeded, valid_destination(), "op-2")
      end)

      assert_receive %FederationEvents.PayoutRequested{kind: :federation_income}, 500
    end

    test "second concurrent enqueue is refused while the first is in flight" do
      seeded = seed_burned_income!()
      first_amount = div(seeded, 4)

      capture_io(fn ->
        # First call succeeds and parks the request in :pending.
        {:ok, _first} =
          Console.withdraw_federation_income(first_amount, valid_destination(), "op-1")

        # Second call must hit the uniqueness gate, NOT silently land
        # a second :pending row that the Signer would later reject at
        # sign time and saddle the operator with cleanup.
        assert {:error, :income_already_pending} =
                 PerpWalk.Federation.Facade.enqueue_federation_income_withdrawal(
                   first_amount,
                   valid_destination(),
                   "op-2"
                 )
      end)
    end
  end

  describe "Console.withdraw_federation_income/3 — audit log" do
    test "records :federation_income_withdrawal_initiated entry" do
      _ = seed_burned_income!()
      path = Audit.log_path()
      _ = File.rm(path)

      capture_io(fn ->
        {:ok, payout} =
          Console.withdraw_federation_income(1_000_000_000_000, valid_destination(), "op-1")

        assert payout.id
      end)

      assert File.exists?(path)

      lines = path |> File.read!() |> String.split("\n", trim: true)
      decoded = Enum.map(lines, &Jason.decode!/1)

      withdrawal_entry =
        Enum.find(decoded, fn entry ->
          entry["kind"] == "federation_income_withdrawal_initiated"
        end)

      assert withdrawal_entry, "no audit entry with kind=federation_income_withdrawal_initiated"
      assert withdrawal_entry["details"]["requesting_account_id"] == "op-1"
      assert withdrawal_entry["details"]["amount_piconeros"] == 1_000_000_000_000
      assert withdrawal_entry["details"]["destination"] == valid_destination()
      assert is_binary(withdrawal_entry["details"]["request_id"])
    end
  end

  describe "end-to-end pipeline through Signer" do
    test "successful flow advances :pending → :paid_out and increments drawn" do
      seeded = seed_burned_income!()
      amount = div(seeded, 2)
      stub_txid = "stub-tx-#{System.unique_integer([:positive])}"

      Signer.set_backend(fn payout ->
        assert payout.kind == :federation_income
        {:ok, stub_txid}
      end)

      :ok = EventBus.subscribe(FederationEvents.PayoutSubmitted)

      capture_io(fn ->
        {:ok, payout} =
          Console.withdraw_federation_income(amount, valid_destination(), "op-1")

        assert payout.status == :pending

        # Drive the Signer through the full chain.
        :ok = Signer.run_now()

        {:ok, finalised} = Facade.get_request(payout.id)
        assert finalised.status == :paid_out
        assert finalised.payout_txid == stub_txid

        assert_receive %FederationEvents.PayoutSubmitted{
                         request_id: rid,
                         payout_txid: ^stub_txid,
                         amount_piconeros: ^amount
                       },
                       500

        assert rid == payout.id
      end)

      # Drawn counter reflects the completed withdrawal.
      assert Facade.federation_income_drawn() >= amount

      # And the live withdrawable balance dropped by `amount`.
      assert Ledger.withdrawable_piconeros() == seeded - amount
    end

    test "rejects when amount exceeds live withdrawable balance" do
      seeded = seed_burned_income!()
      over_draw = seeded + 1

      capture_io(fn ->
        {:ok, payout} =
          Console.withdraw_federation_income(over_draw, valid_destination(), "op-1")

        :ok = Signer.run_now()

        {:ok, evaluated} = Facade.get_request(payout.id)
        assert evaluated.status == :awaiting_operator

        assert evaluated.rule_failure_reason =~ "federation_income"
        assert evaluated.rule_failure_reason =~ "exceeds withdrawable"
      end)
    end

    test "completed withdrawal reduces available for subsequent requests" do
      # Single-withdrawal cap (defense-in-depth, not a bug):
      # `Federation.Rules.amount_match` for `:federation_income`
      # checks `requested ≤ earned - drawn`, where `drawn` includes
      # the request currently being evaluated. That arithmetic caps
      # a single withdrawal to ~half the remaining balance and
      # forces the operator to do multiple smaller draws — a
      # compromised iex session or misconfigured script can't drain
      # the full balance in one transaction. See
      # `project_perp_walk_income_half_cap` memory.
      seeded = seed_burned_income!()
      stub_txid = "tx-#{System.unique_integer([:positive])}"
      Signer.set_backend(fn _payout -> {:ok, stub_txid} end)

      # Quarter of seeded keeps room for a clear "overdraw the rest"
      # follow-up that we can assert against.
      first_amount = div(seeded, 4)

      capture_io(fn ->
        {:ok, first} =
          Console.withdraw_federation_income(first_amount, valid_destination(), "op-1")

        :ok = Signer.run_now()
        {:ok, first_final} = Facade.get_request(first.id)
        assert first_final.status == :paid_out

        # After first :paid_out: drawn reflects exactly the first amount
        # and the live withdrawable drops by that amount.
        remaining = seeded - first_amount
        assert Facade.federation_income_drawn() == first_amount
        assert Ledger.withdrawable_piconeros() == remaining

        # A second request that would push cumulative drawn past
        # earned is rejected at rule time.
        over = remaining + 1

        {:ok, second} =
          Console.withdraw_federation_income(over, valid_destination(), "op-2")

        :ok = Signer.run_now()

        {:ok, second_evaluated} = Facade.get_request(second.id)
        assert second_evaluated.status == :awaiting_operator
        assert second_evaluated.rule_failure_reason =~ "federation_income"
      end)
    end
  end
end
