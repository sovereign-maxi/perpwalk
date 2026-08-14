defmodule PerpWalk.Monero.AddressIntegrationTest do
  @moduledoc "Integration tests for `PerpWalk.Monero.Address` — network-config-driven address validation."

  use PerpWalk.IntegrationCase

  alias PerpWalk.Monero.Address

  # Real example addresses from each network. These are the canonical
  # public examples — useful as fixtures because they're real,
  # syntactically valid, base58, correct length, correct prefix.
  @mainnet_standard "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge"
  @mainnet_subaddress "85F3oc7uLBe7BSdQ4ZNzj7CYyKqkAFEPaq8VLBwxqfgsKoVrhxFb6tJtcZJoY7VHwGfNNS2Bm6Pz3JD2Vp5h3SpcA1zFqsd"
  @stagenet_standard "57XfgYDPUu6sBT3xeAjpw9XJcmEAY3p7yGmKtNcEKkM2DSWk39pmKSKMaJDXxnSRWk5kRn1JNXVT5J5wp3xSStcRGn1jpu1"
  @stagenet_subaddress "77ZQ8N3z5d54PT4jM1pHfvfbFTMVnxbQHmRrxNwq8WS2RJsURj8gv7BPxjT2YJWMP3kVrcU9MMxqMA5DEKDGFRRpGcUcGRn"

  describe "valid?/1 — default mainnet" do
    setup do
      Application.put_env(:perpwalk, :network, :mainnet)
      on_exit(fn -> Application.delete_env(:perpwalk, :network) end)
    end

    test "accepts mainnet standard address" do
      assert Address.valid?(@mainnet_standard)
    end

    test "accepts mainnet subaddress" do
      assert Address.valid?(@mainnet_subaddress)
    end

    test "rejects stagenet standard address" do
      refute Address.valid?(@stagenet_standard)
    end

    test "rejects stagenet subaddress" do
      refute Address.valid?(@stagenet_subaddress)
    end

    test "rejects non-binary input" do
      refute Address.valid?(nil)
      refute Address.valid?(:atom)
      refute Address.valid?(42)
      refute Address.valid?(%{address: @mainnet_standard})
    end

    test "rejects empty string" do
      refute Address.valid?("")
    end

    test "rejects input that exceeds max length" do
      refute Address.valid?(String.duplicate("4", 151))
    end

    test "rejects malformed prefix" do
      mutated = "9" <> String.slice(@mainnet_standard, 1..-1//1)
      refute Address.valid?(mutated)
    end

    test "rejects characters outside base58" do
      mutated = "4Adu" <> String.duplicate("0", 91)
      refute Address.valid?(mutated)
    end
  end

  describe "valid?/1 — stagenet" do
    setup do
      Application.put_env(:perpwalk, :network, :stagenet)
      on_exit(fn -> Application.delete_env(:perpwalk, :network) end)
    end

    test "accepts stagenet standard address" do
      assert Address.valid?(@stagenet_standard)
    end

    test "accepts stagenet subaddress" do
      assert Address.valid?(@stagenet_subaddress)
    end

    test "rejects mainnet standard address" do
      refute Address.valid?(@mainnet_standard)
    end

    test "rejects mainnet subaddress" do
      refute Address.valid?(@mainnet_subaddress)
    end
  end

  describe "prefix_description/0" do
    test "mainnet" do
      Application.put_env(:perpwalk, :network, :mainnet)
      assert Address.prefix_description() =~ "4"
      assert Address.prefix_description() =~ "8"
      Application.delete_env(:perpwalk, :network)
    end

    test "stagenet" do
      Application.put_env(:perpwalk, :network, :stagenet)
      assert Address.prefix_description() =~ "5"
      assert Address.prefix_description() =~ "7"
      Application.delete_env(:perpwalk, :network)
    end

    test "defaults to mainnet description when unset" do
      Application.delete_env(:perpwalk, :network)
      assert Address.prefix_description() =~ "4"
    end
  end

  describe "max_input_length/0" do
    test "returns a positive integer" do
      assert is_integer(Address.max_input_length())
      assert Address.max_input_length() > 100
    end
  end
end
