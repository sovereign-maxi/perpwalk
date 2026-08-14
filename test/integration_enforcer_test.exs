defmodule PerpWalk.IntegrationEnforcerTest do
  @moduledoc """
  Regression guard: every file under `test/integration/` MUST use
  one of the IntegrationCase templates. Bypassing them (via bare
  `use ExUnit.Case`) skips `PerpWalk.TestHelpers.CleanState.clean_state/1`,
  which resets rate-limiter / sessions ETS / WAL sealer / halt state /
  markets store / processor promotion between tests. Without that
  reset, tests leak state into each other and flake under specific
  test seeds.

  See `test/support/clean_state.ex` for the full reset surface.
  """

  use ExUnit.Case, async: true

  @integration_root "test/integration"
  @allowed_templates [
    "use PerpWalk.IntegrationCase",
    "use PerpWalkWeb.IntegrationCase",
    "use PerpWalkAdminWeb.IntegrationCase"
  ]

  test "every integration test file uses an IntegrationCase template" do
    violations =
      Path.wildcard(Path.join([@integration_root, "**", "*_test.exs"]))
      |> Enum.filter(fn path ->
        content = File.read!(path)
        not Enum.any?(@allowed_templates, &String.contains?(content, &1))
      end)
      |> Enum.sort()

    assert violations == [], """
    Integration test files must `use` one of these case templates:

    #{Enum.join(@allowed_templates, "\n")}

    Bypassing them means `clean_state/1` doesn't run and cross-test
    state leaks (rate-limiter buckets, sessions ETS, WAL sealer
    counter, halt state, markets store, processor promotion).

    Violating files:
    #{Enum.map_join(violations, "\n", &"  #{&1}")}
    """
  end
end
