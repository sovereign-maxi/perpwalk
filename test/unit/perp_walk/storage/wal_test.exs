defmodule PerpWalk.Storage.WALTest do
  @moduledoc "Unit tests for PerpWalk.Storage.WAL."

  use ExUnit.Case, async: true

  alias PerpWalk.Storage.WAL

  @expected_types %{
    checkpoint: 0x01,
    market_put: 0x02,
    vote_put: 0x04,
    trade_executed: 0x05,
    market_resolved: 0x06,
    quote_put: 0x07,
    quote_filled: 0x08,
    position_paid_out: 0x09,
    payout_requested: 0x0A,
    dispute_put: 0x0B,
    quote_expired: 0x0C,
    session_created: 0x0D,
    session_revoked: 0x0E,
    session_seckey_bound: 0x0F,
    broadcast_marker_set: 0x10,
    broadcast_marker_cleared: 0x11,
    comment_ingested: 0x12,
    halt_alert: 0x13,
    processor_promotion: 0x14
  }

  describe "type_map/0" do
    test "returns the registry of all event types to byte codes" do
      type_map = WAL.type_map()
      assert is_map(type_map)
      assert type_map == @expected_types
    end

    test "all keys are atoms" do
      for {key, _val} <- WAL.type_map() do
        assert is_atom(key)
      end
    end

    test "all values are positive integers" do
      for {_key, val} <- WAL.type_map() do
        assert is_integer(val) and val > 0
      end
    end

    test "all byte codes are unique" do
      values = Map.values(WAL.type_map())
      assert length(values) == length(Enum.uniq(values))
    end

    test "checkpoint type is present (required by Locker.WAL)" do
      assert Map.has_key?(WAL.type_map(), :checkpoint)
    end
  end

  describe "byte_map/0" do
    test "returns the inverse of type_map" do
      byte_map = WAL.byte_map()
      type_map = WAL.type_map()

      assert map_size(byte_map) == map_size(type_map)

      for {name, byte} <- type_map do
        assert byte_map[byte] == name
      end
    end

    test "all keys are integers" do
      for {key, _val} <- WAL.byte_map() do
        assert is_integer(key)
      end
    end

    test "all values are atoms" do
      for {_key, val} <- WAL.byte_map() do
        assert is_atom(val)
      end
    end

    test "round-trips with type_map" do
      for {name, byte} <- WAL.type_map() do
        assert WAL.byte_map()[byte] == name
        assert WAL.type_map()[name] == byte
      end
    end
  end

  describe "server_name/0" do
    test "returns the WAL server name atom" do
      assert WAL.server_name() == PerpWalk.Storage.WAL
    end

    test "returns an atom" do
      assert is_atom(WAL.server_name())
    end
  end
end
