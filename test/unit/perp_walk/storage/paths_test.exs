defmodule PerpWalk.Storage.PathsTest do
  @moduledoc "Unit tests for PerpWalk.Storage.Paths."

  use ExUnit.Case, async: true

  alias PerpWalk.Storage.Paths

  describe "base_dir/0" do
    test "returns configured data_dir" do
      assert is_binary(Paths.base_dir())
    end
  end

  describe "context directories" do
    test "all context dirs are under base_dir" do
      base = Paths.base_dir()

      for dir <- [
            Paths.backups(),
            Paths.keys(),
            Paths.identity(),
            Paths.markets(),
            Paths.monero(),
            Paths.storage(),
            Paths.telemetry()
          ] do
        assert String.starts_with?(dir, base), "#{dir} not under #{base}"
      end
    end

    test "context dirs are distinct" do
      dirs = [
        Paths.backups(),
        Paths.keys(),
        Paths.identity(),
        Paths.markets(),
        Paths.monero(),
        Paths.storage(),
        Paths.telemetry()
      ]

      assert length(Enum.uniq(dirs)) == length(dirs)
    end
  end

  describe "file and subtree paths" do
    test "WAL directory is under storage" do
      assert String.starts_with?(Paths.storage_wal(), Paths.storage())
    end

    test "key file paths are under keys directory" do
      path = Paths.key_file("test-label")
      assert String.starts_with?(path, Paths.keys())
      assert String.ends_with?(path, ".enc")
    end

    test "key file label is preserved in the path" do
      assert String.contains?(Paths.key_file("nostr-signing"), "nostr-signing")
    end

    test "no paths contain Elixir module names" do
      for path <- [
            Paths.backups(),
            Paths.keys(),
            Paths.identity(),
            Paths.markets(),
            Paths.monero(),
            Paths.storage(),
            Paths.storage_wal(),
            Paths.telemetry(),
            Paths.key_file("anything")
          ] do
        refute String.contains?(path, "Elixir."), "#{path} contains Elixir module name"
      end
    end
  end

  describe "ensure_dirs!/0" do
    test "directory tree exists after application start" do
      # PerpWalk.Storage.Supervisor.init/1 calls Paths.ensure_dirs!/0
      # before any child starts, so directories exist by the time
      # tests run.
      assert File.dir?(Paths.backups())
      assert File.dir?(Paths.keys())
      assert File.dir?(Paths.identity())
      assert File.dir?(Paths.markets())
      assert File.dir?(Paths.monero())
      assert File.dir?(Paths.storage())
      assert File.dir?(Paths.storage_wal())
      assert File.dir?(Paths.telemetry())
    end
  end
end
