defmodule PerpWalk.Nostr.FrameTest do
  @moduledoc "Unit tests for PerpWalk.Nostr.Frame NIP-01 wire-format parsing."

  use ExUnit.Case, async: true

  alias PerpWalk.Nostr.Frame

  describe "parse/1 — relay→client variants" do
    test "parses an EVENT frame" do
      event = %{"id" => "abc", "content" => "hi"}
      text = Jason.encode!(["EVENT", "sub-1", event])

      assert {:event, "sub-1", parsed} = Frame.parse(text)
      assert parsed["id"] == "abc"
    end

    test "parses an EOSE frame" do
      assert {:eose, "sub-1"} = Frame.parse(Jason.encode!(["EOSE", "sub-1"]))
    end

    test "parses a NOTICE frame" do
      assert {:notice, "server msg"} = Frame.parse(Jason.encode!(["NOTICE", "server msg"]))
    end

    test "parses a CLOSED frame" do
      text = Jason.encode!(["CLOSED", "sub-1", "rate-limited"])
      assert {:closed, "sub-1", "rate-limited"} = Frame.parse(text)
    end

    test "parses an OK frame for a publisher ack" do
      text = Jason.encode!(["OK", "evt-id", true, ""])
      assert {:ok, "evt-id", true, ""} = Frame.parse(text)
    end

    test "returns :unknown for valid JSON that isn't a recognised NIP-01 message" do
      text = Jason.encode!(["WHATEVER", "x"])
      assert {:unknown, ["WHATEVER", "x"]} = Frame.parse(text)
    end

    test "returns :bad_frame on JSON decode failure" do
      assert {:error, :bad_frame} = Frame.parse("not json")
      assert {:error, :bad_frame} = Frame.parse(~s({"closed"}))
    end

    test "returns :bad_frame for non-binary input" do
      assert {:error, :bad_frame} = Frame.parse(nil)
      assert {:error, :bad_frame} = Frame.parse(123)
    end

    test "EVENT with missing fields drops through to :unknown" do
      # `["EVENT", sub_id]` is structurally close but missing the
      # event payload — not a valid NIP-01 EVENT.
      text = Jason.encode!(["EVENT", "sub-1"])
      assert {:unknown, ["EVENT", "sub-1"]} = Frame.parse(text)
    end
  end

  describe "build_req/2" do
    test "produces a JSON REQ frame with the supplied filter" do
      filter = %{"kinds" => [1], "#t" => ["perpwalk-market-comment"]}
      text = Frame.build_req("sub-7", filter)

      assert ["REQ", "sub-7", decoded_filter] = Jason.decode!(text)
      assert decoded_filter["kinds"] == [1]
      assert decoded_filter["#t"] == ["perpwalk-market-comment"]
    end
  end

  describe "build_close/1" do
    test "produces a JSON CLOSE frame" do
      text = Frame.build_close("sub-7")
      assert ["CLOSE", "sub-7"] = Jason.decode!(text)
    end
  end
end
