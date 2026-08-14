defmodule PerpWalk.TestHelpers.CleanState do
  @moduledoc """
  Per-test isolation of the shared, app-lifetime state that accumulates
  across integration test files.

  Integration tests attach this to their setup block (typically via
  the `IntegrationCase` template, which calls it automatically):

      setup :clean_state

  The single call wipes:

    * `PerpWalk.Markets.Store` (all Markets ETS tables)
    * `PerpWalk.Storage.WAL.Sealer` (WAL sequence counter reset)
    * `PerpWalk.Storage.WAL` (all segments — resetting the counter
      without wiping the WAL would leave prior tests' higher seqs on
      disk, and a store restart mid-test would replay a
      cross-generation rewind that trips the halt-on-corrupt gate)
    * `Seer.RateLimiter` (per-circuit counters — otherwise stale
      429s bleed between files when run as a group)
    * `PerpWalk.Identity.Sessions` (auth cookie session table)

  Plus reinstalls the test subaddress-provider stub so any test that
  goes through the Maker gets a deterministic deposit address.

  Individual wipes are exposed for granular reset in tests that
  don't want the full reset.
  """

  alias PerpWalk.Identity.Sessions
  alias PerpWalk.Markets.Store
  alias PerpWalk.Storage.WAL.Sealer
  alias PerpWalk.Telemetry.Health.System, as: HealthSystem
  alias PerpWalk.TestHelpers.MarketsHelpers
  alias Seer.RateLimiter

  @doc "ExUnit `setup :clean_state` callback. Returns `:ok`."
  @spec clean_state(map()) :: :ok
  def clean_state(_context \\ %{}) do
    Store.clear()
    Sealer.reset!()
    Locker.WAL.clear(PerpWalk.Storage.WAL)
    MarketsHelpers.stub_subaddress_provider()
    reset_web_state()
    clear_halt_state()
    clear_processor_promotion()
    :ok
  catch
    :exit, _ -> :ok
  end

  # Federation.Store's persistent_term-backed processor promotion is
  # process-independent, so it survives every teardown short of a
  # BEAM restart. A test that promotes (`Console.promote_processor/1`
  # or a direct WAL apply) leaks the record into every subsequent
  # test in the shared BEAM — Signer tests then see a designated set
  # that excludes the local participant, `drive_writes?/1` returns
  # false, and payouts stay stuck at `:pending`. Wipe per test.
  defp clear_processor_promotion do
    :persistent_term.erase({PerpWalk.Federation.Store, :promotion})
    :ok
  rescue
    _ -> :ok
  end

  # Halt state persists across test files in the shared BEAM because
  # the auto-clear in product code (e.g. `Replicator.maybe_clear_replicator_halt`)
  # only fires on that source's next good batch, which never happens
  # between test files. Any test that trips a source-halt (replicator
  # signature failure tests, checkpointer WAL-write tests) or the
  # manual halt (operator-halt tests) then poisons every subsequent
  # test with `Guards.ensure_operational!` raising "system is halted".
  # Wipe both halt surfaces per test.
  defp clear_halt_state do
    HealthSystem.clear_source_halt(:replicator)
    HealthSystem.clear_source_halt(:replicator_signature)
    HealthSystem.clear_source_halt(:checkpointer)
    HealthSystem.clear_halt()
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Wipes cross-request web state — rate-limiter buckets and identity
  session rows. Both are ETS-backed and persist for the app's lifetime,
  which means one test's writes bleed into the next when files are run
  as a group.
  """
  @spec reset_web_state() :: :ok
  def reset_web_state do
    if :ets.whereis(RateLimiter) != :undefined do
      :ets.delete_all_objects(RateLimiter)
    end

    if :ets.whereis(Sessions.table_name()) != :undefined do
      :ets.delete_all_objects(Sessions.table_name())
    end

    :ok
  rescue
    ArgumentError -> :ok
  end
end
