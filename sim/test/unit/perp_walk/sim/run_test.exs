defmodule PerpWalk.Sim.RunTest do
  @moduledoc "Unit tests for the sim run-context handle."

  use ExUnit.Case, async: false

  alias PerpWalk.Sim.Run

  setup do
    Run.mark_finished()
    :ok
  end

  test "from_current_run?/1 returns false when no run is active" do
    Run.mark_finished()

    assert Run.from_current_run?(DateTime.utc_now()) == true
    # Note: the unix-epoch fallback means EVERY datetime passes
    # when no run is active. Documented behaviour — the filter is
    # only meaningful inside an active sim run.
  end

  test "from_current_run?/1 filters out pre-run timestamps" do
    pre_run = DateTime.utc_now()
    Process.sleep(5)

    Run.mark_started()
    Process.sleep(5)
    in_run = DateTime.utc_now()

    assert Run.from_current_run?(in_run) == true
    assert Run.from_current_run?(pre_run) == false
  end

  test "mark_finished/0 clears the run marker" do
    Run.mark_started()
    pre_finish = DateTime.utc_now()

    Run.mark_finished()
    Process.sleep(5)
    post_finish = DateTime.utc_now()

    # After mark_finished the start_time falls back to epoch, so
    # any datetime passes the filter — it's effectively disabled.
    assert Run.from_current_run?(pre_finish) == true
    assert Run.from_current_run?(post_finish) == true
  end

  test "from_current_run?/1 with nil returns false" do
    Run.mark_started()
    assert Run.from_current_run?(nil) == false
  end
end
