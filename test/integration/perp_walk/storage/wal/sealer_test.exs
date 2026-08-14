defmodule PerpWalk.Storage.WAL.SealerIntegrationTest do
  @moduledoc """
  Integration tests for `PerpWalk.Storage.WAL.Sealer`.

  The Sealer is started by the application supervisor, so these
  tests exercise its live GenServer state — `reset!/0` mutates the
  shared atomics counter, and `seal_and_append/3` round-trips through
  the production `Locker.WAL` instance. `async: false` because the
  shared counter is global.
  """

  use PerpWalk.IntegrationCase

  alias Locker.WAL.Entry
  alias PerpWalk.Storage.WAL.Sealer

  describe "seal_and_append/3" do
    test "writes an entry to the WAL with a seq stamped onto the payload" do
      assert :ok = Sealer.seal_and_append(:market_put, %{id: "m-1", description: "test"})

      assert Sealer.current_seq() == 1
    end

    test "allocates strictly-increasing seqs across successive calls" do
      :ok = Sealer.seal_and_append(:market_put, %{id: "m-1"})
      assert Sealer.current_seq() == 1
      :ok = Sealer.seal_and_append(:market_put, %{id: "m-2"})
      assert Sealer.current_seq() == 2
      :ok = Sealer.seal_and_append(:vote_put, %{id: "v-1"})
      assert Sealer.current_seq() == 3
    end

    test "overwrites caller-supplied :seq so producers cannot forge a seq" do
      assert :ok = Sealer.seal_and_append(:market_put, %{id: "m-1", seq: 99_999})

      # First allocation after reset is 1, not 99_999. The caller's
      # :seq is silently overwritten.
      assert Sealer.current_seq() == 1
    end
  end

  describe "seal/2" do
    test "returns the payload with the next seq stamped on it" do
      {:ok, sealed} = Sealer.seal(:market_put, %{id: "m-1"})
      assert sealed.id == "m-1"
      assert sealed.seq == 1
      assert Sealer.current_seq() == 1
    end

    test "two seals get distinct seqs" do
      {:ok, a} = Sealer.seal(:market_put, %{id: "a"})
      {:ok, b} = Sealer.seal(:market_put, %{id: "b"})

      assert a.seq == 1
      assert b.seq == 2
    end
  end

  describe "current_seq/0" do
    test "returns 0 immediately after reset" do
      assert Sealer.current_seq() == 0
    end

    test "tracks each allocation" do
      {:ok, _} = Sealer.seal(:market_put, %{id: "x"})
      assert Sealer.current_seq() == 1
      {:ok, _} = Sealer.seal(:market_put, %{id: "y"})
      assert Sealer.current_seq() == 2
    end
  end

  describe "bump_to/1" do
    test "advances the counter to the target" do
      :ok = Sealer.bump_to(42)
      assert Sealer.current_seq() == 42
    end

    test "is idempotent on target <= current" do
      :ok = Sealer.bump_to(10)
      :ok = Sealer.bump_to(5)
      assert Sealer.current_seq() == 10
    end

    test "next seq after bump is target + 1" do
      :ok = Sealer.bump_to(100)
      {:ok, sealed} = Sealer.seal(:market_put, %{id: "x"})
      assert sealed.seq == 101
    end

    test "rejects negative targets via guard (raises)" do
      assert_raise FunctionClauseError, fn -> Sealer.bump_to(-1) end
    end
  end

  describe "concurrency" do
    test "100 concurrent seal calls produce 100 unique strictly-increasing seqs" do
      # Each Task allocates one seq; we collect them and assert they
      # form a contiguous range 1..100 (in some order) with no
      # duplicates. Atomics CAS guarantees uniqueness.
      seqs =
        1..100
        |> Enum.map(fn _ ->
          Task.async(fn ->
            {:ok, sealed} = Sealer.seal(:market_put, %{})
            Map.fetch!(sealed, :seq)
          end)
        end)
        |> Task.await_many(5_000)
        |> Enum.sort()

      assert seqs == Enum.to_list(1..100)
      assert length(Enum.uniq(seqs)) == 100
    end
  end

  describe "WAL contents after seal_and_append" do
    test "the appended entry carries :seq in its payload as it lands on disk" do
      :ok = Sealer.seal_and_append(:market_put, %{id: "m-deep-check"})

      {:ok, entries} = Locker.WAL.read_all(PerpWalk.Storage.WAL)

      our_entry =
        Enum.find(entries, fn
          %Entry{type: :market_put, payload: %{id: "m-deep-check"}} -> true
          _ -> false
        end)

      assert %Entry{payload: %{seq: seq}} = our_entry
      assert is_integer(seq) and seq > 0
    end
  end
end
