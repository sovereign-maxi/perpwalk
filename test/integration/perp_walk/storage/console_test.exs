defmodule PerpWalk.Storage.ConsoleIntegrationTest do
  @moduledoc """
  Integration tests for `PerpWalk.Storage.Console` against the
  application-supervised WAL + Checkpointer.
  """

  use PerpWalk.IntegrationCase

  import ExUnit.CaptureIO

  alias Locker.WAL.Entry
  alias PerpWalk.Storage.{Console, Paths, WAL}

  describe "wal_info/0" do
    test "returns segment, count, bytes" do
      info = Console.wal_info()
      assert is_map(info)
      assert is_integer(info.segment_index)
      assert is_integer(info.entry_count)
      assert is_integer(info.bytes_written)
      assert is_binary(info.segment_path)
    end
  end

  describe "wal_checkpoint/0" do
    test "writes a :checkpoint entry into the WAL" do
      :ok = Console.wal_checkpoint()

      {:ok, entries} = Locker.WAL.read_all(WAL.server_name())
      assert Enum.any?(entries, &match?(%Entry{type: :checkpoint}, &1))
    end
  end

  describe "wal_rotate/0" do
    test "increments the segment index" do
      before = Console.wal_info()
      assert :ok = Console.wal_rotate()
      after_rotate = Console.wal_info()
      assert after_rotate.segment_index == before.segment_index + 1
    end
  end

  describe "wal_prune/1" do
    test "is a no-op when there are fewer segments than `keep`" do
      assert {:ok, 0} = with_confirm(fn -> Console.wal_prune(100) end)
    end

    test "prunes oldest segments down to `keep` (destructive)" do
      # Force 3 rotations so we have multiple segments.
      :ok = Console.wal_rotate()
      :ok = Console.wal_rotate()
      :ok = Console.wal_rotate()

      segments_before = list_segments()
      assert length(segments_before) >= 3

      assert {:ok, n} = with_confirm(fn -> Console.wal_prune(2) end)
      assert n >= 1

      segments_after = list_segments()
      assert length(segments_after) == 2
    end

    test "rejects keep < 1 at the function head" do
      assert_raise FunctionClauseError, fn -> Console.wal_prune(0) end
    end

    test "refuses without confirmation" do
      # Console prompt without an answer (StringIO empty input) =
      # treated as no; no segments touched, no Audit row.
      parent = self()
      capture_io("\n", fn -> send(parent, Console.wal_prune(100)) end)

      assert_receive {:error, :cancelled}, 1_000
    end
  end

  # Drives stdin with "yes\n" so the destructive confirmation prompt
  # accepts and we can assert on the result. Returns the function's
  # return value; the stdout output is captured + discarded.
  defp with_confirm(fun) do
    parent = self()
    capture_io("yes\n", fn -> send(parent, fun.()) end)

    receive do
      result -> result
    after
      1_000 -> raise "with_confirm: function did not return"
    end
  end

  defp list_segments do
    case File.ls(Paths.storage_wal()) do
      {:ok, files} -> Enum.filter(files, &Regex.match?(~r/^wal\.\d+$/, &1))
      {:error, _} -> []
    end
  end
end
