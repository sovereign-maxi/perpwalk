defmodule PerpWalk.Storage.CheckpointerIntegrationTest do
  @moduledoc """
  Integration tests for `PerpWalk.Storage.Checkpointer`.

  Each test starts an isolated `Locker.WAL` plus a Checkpointer
  pointed at it, drives ticks via `run_now/0`, and inspects the
  resulting WAL contents.
  """

  use PerpWalk.IntegrationCase

  alias Locker.WAL.Entry
  alias PerpWalk.Storage.Checkpointer
  alias PerpWalk.TestHelpers.ProcessHelpers

  defp start_isolated do
    suffix = :erlang.unique_integer([:positive, :monotonic])
    wal_dir = Path.join(System.tmp_dir!(), "perpwalk_checkpointer_#{suffix}")
    File.mkdir_p!(wal_dir)

    wal_name = :"checkpointer_wal_#{suffix}"
    cp_name = :"checkpointer_#{suffix}"

    {:ok, wal_pid} =
      Locker.WAL.start_link(
        name: wal_name,
        wal_dir: wal_dir,
        types: PerpWalk.Storage.WAL.type_map()
      )

    {:ok, cp_pid} =
      Checkpointer.start_link(
        name: cp_name,
        wal_server: wal_name,
        # Effectively never auto-tick; tests drive via run_now/0
        interval_ms: 3_600_000
      )

    on_exit(fn ->
      ProcessHelpers.safe_stop(cp_pid)
      ProcessHelpers.safe_stop(wal_pid)
      File.rm_rf!(wal_dir)
    end)

    %{wal: wal_name, checkpointer: cp_name}
  end

  describe "run_now/1" do
    test "appends exactly one :checkpoint entry per call" do
      %{wal: wal, checkpointer: cp} = start_isolated()

      :ok = Checkpointer.run_now(cp)
      :ok = Checkpointer.run_now(cp)

      {:ok, entries} = Locker.WAL.read_all(wal)
      checkpoints = Enum.filter(entries, &(&1.type == :checkpoint))
      assert length(checkpoints) == 2
    end

    test "checkpoint entries carry segment metadata" do
      %{wal: wal, checkpointer: cp} = start_isolated()

      :ok = Checkpointer.run_now(cp)
      {:ok, [entry]} = Locker.WAL.read_all(wal)

      assert %Entry{type: :checkpoint, payload: payload} = entry
      assert is_map(payload)
      assert is_integer(payload.timestamp)
      assert is_integer(payload.entry_count)
      assert is_integer(payload.segment_index)
    end

    test "emits :ok telemetry on success" do
      %{wal: wal, checkpointer: cp} = start_isolated()
      handler_id = {__MODULE__, :ok_test, System.unique_integer([:positive])}
      pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:perp_walk, :storage, :checkpointer, :ok],
          fn _event, measurements, metadata, _config ->
            send(pid, {:cp_ok, measurements, metadata})
          end,
          nil
        )

      try do
        :ok = Checkpointer.run_now(cp)
        assert_receive {:cp_ok, %{}, %{wal_server: ^wal}}, 100
      after
        :telemetry.detach(handler_id)
      end
    end

    test "emits :failed telemetry when WAL is unavailable" do
      %{wal: wal, checkpointer: cp} = start_isolated()
      handler_id = {__MODULE__, :fail_test, System.unique_integer([:positive])}
      pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:perp_walk, :storage, :checkpointer, :failed],
          fn _event, measurements, metadata, _config ->
            send(pid, {:cp_failed, measurements, metadata})
          end,
          nil
        )

      try do
        # Stop the WAL out from under the checkpointer.
        ProcessHelpers.safe_stop(wal)

        :ok = Checkpointer.run_now(cp)

        assert_receive {:cp_failed, %{}, %{wal_server: ^wal, reason: _}}, 200
      after
        :telemetry.detach(handler_id)
      end
    end
  end
end
