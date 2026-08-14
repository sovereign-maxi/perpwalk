defmodule PerpWalk.IntegrationCase do
  @moduledoc """
  Shared test setup for non-web integration tests.

  Same isolation contract as `PerpWalkWeb.IntegrationCase`:
  runs `PerpWalk.TestHelpers.CleanState.clean_state/1` before every
  test so per-test state doesn't leak across files under the shared
  BEAM. Use this for anything under `test/integration/` that isn't
  driving `PerpWalkWeb` or `PerpWalkAdminWeb` LiveViews / controllers.

      use PerpWalk.IntegrationCase

      test "..." do
        # Markets store empty, WAL sealer reset, rate-limiter cleared,
        # sessions ETS cleared, halt state cleared, processor
        # promotion cleared. Add your own `setup` block for
        # per-test fixtures.
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false
      import PerpWalk.TestHelpers.CleanState, only: [clean_state: 1]

      @moduletag :integration

      setup :clean_state
    end
  end
end

defmodule PerpWalkWeb.IntegrationCase do
  @moduledoc """
  Shared test setup for PerpWalkWeb LiveView integration tests.

  Wires the public endpoint, imports Phoenix.ConnTest + LiveViewTest,
  runs `clean_state` before every test, and provides a fresh
  `Plug.Conn` in the context. Test files just:

      use PerpWalkWeb.IntegrationCase

  Individual tests can still add their own `setup` blocks for
  per-test fixtures — the CaseTemplate only handles the shared
  ceremony (moduletag / endpoint / imports / clean_state / conn).

  `PerpWalk.TestHelpers.MarketsHelpers` is imported wholesale so
  fixture builders (`pending_market!`, `activate!`, etc.) are
  available without per-test import ceremony.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PerpWalk.TestHelpers.CleanState, only: [clean_state: 1]
      import PerpWalk.TestHelpers.MarketsHelpers
      import PerpWalkWeb.TestHelpers.AuthHelpers

      @endpoint PerpWalkWeb.Endpoint

      @moduletag :integration

      setup :clean_state

      setup do
        {:ok, conn: Phoenix.ConnTest.build_conn()}
      end
    end
  end
end

defmodule PerpWalkAdminWeb.IntegrationCase do
  @moduledoc """
  Shared test setup for PerpWalkAdminWeb LiveView integration tests.

  Same shape as `PerpWalkWeb.IntegrationCase` but wires the admin
  endpoint. Test files:

      use PerpWalkAdminWeb.IntegrationCase
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PerpWalk.TestHelpers.CleanState, only: [clean_state: 1]
      import PerpWalk.TestHelpers.MarketsHelpers
      import PerpWalkWeb.TestHelpers.AuthHelpers

      @endpoint PerpWalkAdminWeb.Endpoint

      @moduletag :integration

      setup :clean_state

      setup do
        {:ok, conn: Phoenix.ConnTest.build_conn()}
      end
    end
  end
end
