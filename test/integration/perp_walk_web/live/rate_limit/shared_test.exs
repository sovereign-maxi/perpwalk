defmodule PerpWalkWeb.Live.RateLimit.SharedIntegrationTest do
  @moduledoc """
  Integration tests for the account-scoped shared rate limiter.
  Uses `:integration` because it owns a real ETS table started by
  the GenServer; tests don't simulate boot state.
  """

  use PerpWalkWeb.IntegrationCase

  alias PerpWalkWeb.Live.RateLimit.Shared

  setup do
    # The GenServer is started by the application supervisor; clear
    # any rows left from prior tests so each case starts with a clean
    # bucket per account_id. `clean_state` handles the Seer.RateLimiter
    # ETS but this module owns its own separate bucket table.
    if :ets.whereis(Shared) != :undefined do
      :ets.delete_all_objects(Shared)
    end

    :ok
  end

  describe "check/2" do
    test "returns :ok the first N times under the cap" do
      for _ <- 1..10 do
        assert :ok = Shared.check("acct-#{System.unique_integer([:positive])}", :dispute_open)
      end
    end

    test "returns {:error, :rate_limited} once an account exceeds the dispute_open cap" do
      acct = "acct-burst"

      # Cap is 10 per minute. Hit it.
      for _ <- 1..10 do
        assert :ok = Shared.check(acct, :dispute_open)
      end

      assert {:error, :rate_limited} = Shared.check(acct, :dispute_open)
    end

    test "rate limits are per-account — one account hitting the cap doesn't block another" do
      a = "acct-A"
      b = "acct-B"

      for _ <- 1..10, do: assert(:ok = Shared.check(a, :dispute_open))
      assert {:error, :rate_limited} = Shared.check(a, :dispute_open)
      assert :ok = Shared.check(b, :dispute_open)
    end

    test "rate limits are per-kind — one kind at cap doesn't block another for the same account" do
      acct = "acct-multi-kind"

      # claim_submit cap = 20/min, dispute_open cap = 10/min.
      for _ <- 1..10, do: assert(:ok = Shared.check(acct, :dispute_open))
      assert {:error, :rate_limited} = Shared.check(acct, :dispute_open)

      # claim_submit bucket is untouched.
      assert :ok = Shared.check(acct, :claim_submit)
    end

    test "anonymous (nil account_id) is always :ok" do
      for _ <- 1..50 do
        assert :ok = Shared.check(nil, :claim_submit)
      end
    end

    test "unknown kinds get the default fallback cap" do
      acct = "acct-unknown"

      # Default fallback is 30/60s — well above one call.
      assert :ok = Shared.check(acct, :totally_unknown_kind)
    end
  end

  describe "claim_submit cap (separate kind)" do
    test "claim_submit cap is independently exhausted" do
      acct = "acct-claims"

      # Cap is 20 per minute.
      for _ <- 1..20 do
        assert :ok = Shared.check(acct, :claim_submit)
      end

      assert {:error, :rate_limited} = Shared.check(acct, :claim_submit)
    end
  end
end
