defmodule PerpWalk.RoleIntegrationTest do
  @moduledoc """
  Integration tests for the symmetric three-node `Role` model.

  Each hot node carries its own `:participant_id` (`:p1` / `:p2`
  / `:p3`) and writes freely against its local WAL. The replicator
  pulls peers' entries with `:origin == peer_id` past a per-peer
  cursor and applies them locally so the WALs converge. `Role`'s
  job is the participant-id read + the designated-processor gate
  for cluster-state writes that must not double-fire.
  """

  use PerpWalk.IntegrationCase

  alias PerpWalk.Role

  setup do
    on_exit(fn ->
      Application.put_env(:perpwalk, :participant_id, :p1)
    end)

    :ok
  end

  describe "participant_id/0" do
    test "defaults to :p1 when config is unset" do
      Application.delete_env(:perpwalk, :participant_id)
      assert Role.participant_id() == :p1
    end

    test ":p1 / :p2 / :p3 configs read back" do
      for id <- [:p1, :p2, :p3] do
        Application.put_env(:perpwalk, :participant_id, id)
        assert Role.participant_id() == id
      end
    end

    test "raises on invalid config" do
      Application.put_env(:perpwalk, :participant_id, :potato)

      assert_raise ArgumentError, ~r/invalid :participant_id config/, fn ->
        Role.participant_id()
      end
    end
  end

  describe "writes_allowed?/0" do
    test "is true on every participant — every hot node accepts writes" do
      for id <- [:p1, :p2, :p3] do
        Application.put_env(:perpwalk, :participant_id, id)
        assert Role.writes_allowed?(), "expected writes_allowed?/0 to be true for #{inspect(id)}"
      end
    end
  end

  describe "designated_processor?/0" do
    test "true only on :p1 (the transitional pinned processor)" do
      Application.put_env(:perpwalk, :participant_id, :p1)
      assert Role.designated_processor?()

      for id <- [:p2, :p3] do
        Application.put_env(:perpwalk, :participant_id, id)
        refute Role.designated_processor?(), "expected #{inspect(id)} NOT to be designated"
      end
    end
  end

  describe "designated_processors/0 runtime override (inventory fallback)" do
    setup do
      previous = Application.get_env(:perpwalk, :designated_processors)
      :persistent_term.erase({PerpWalk.Federation.Store, :promotion})

      on_exit(fn ->
        :persistent_term.erase({PerpWalk.Federation.Store, :promotion})

        if previous == nil do
          Application.delete_env(:perpwalk, :designated_processors)
        else
          Application.put_env(:perpwalk, :designated_processors, previous)
        end
      end)

      :ok
    end

    test "defaults to [:p1, :s1] when unset" do
      Application.delete_env(:perpwalk, :designated_processors)
      assert Role.designated_processors() == [:p1, :s1]
    end

    test "app env override flips which participant is designated" do
      # Local node is :p2. Under default, not designated.
      Application.put_env(:perpwalk, :participant_id, :p2)
      Application.delete_env(:perpwalk, :designated_processors)
      refute Role.designated_processor?()

      # Promote :p2 via the app-env override — it becomes designated
      # without touching participant_id (which stays baked into WAL
      # origins). This is the inventory-default seeding path; runtime
      # operator promotion goes through the WAL-backed path below.
      Application.put_env(:perpwalk, :designated_processors, [:p2])
      assert Role.designated_processor?()

      # Meanwhile the old default's participant would no longer be
      # designated.
      Application.put_env(:perpwalk, :participant_id, :p1)
      refute Role.designated_processor?()
    end
  end

  describe "designated_processors/0 WAL-backed promotion" do
    setup do
      previous = Application.get_env(:perpwalk, :designated_processors)
      :persistent_term.erase({PerpWalk.Federation.Store, :promotion})

      on_exit(fn ->
        :persistent_term.erase({PerpWalk.Federation.Store, :promotion})

        if previous == nil do
          Application.delete_env(:perpwalk, :designated_processors)
        else
          Application.put_env(:perpwalk, :designated_processors, previous)
        end
      end)

      :ok
    end

    test "WAL-backed promotion takes precedence over app env" do
      # App env says [:p1], WAL-backed promotion says [:p2]. WAL wins.
      Application.put_env(:perpwalk, :designated_processors, [:p1])
      :persistent_term.put({PerpWalk.Federation.Store, :promotion}, {[:p2], 1})

      assert Role.designated_processors() == [:p2]
    end

    test "empty WAL-backed set falls through to app env (defensive)" do
      # A malformed replay (empty set) should not silently promote
      # nobody — fall through to the inventory default. Otherwise a
      # bug in the WAL producer could disable the whole federation.
      Application.put_env(:perpwalk, :designated_processors, [:p1])
      :persistent_term.put({PerpWalk.Federation.Store, :promotion}, {[], 5})

      assert Role.designated_processors() == [:p1]
    end
  end
end
