defmodule PerpWalk.Identity.FacadeTest do
  @moduledoc """
  Unit tests for `PerpWalk.Identity.Facade`.
  """

  use ExUnit.Case, async: true

  alias PerpWalk.Identity.Facade

  describe "register/0" do
    test "returns a fresh display key, account_id, and handle" do
      assert {:ok, %{display_key: key, account_id: id, handle: handle}} = Facade.register()

      assert is_binary(key) and byte_size(key) > 0
      assert byte_size(id) == 64
      assert handle =~ ~r/^[a-z]+-[a-z]+-\d{4}$/
    end

    test "display key is a 6-word hyphen-separated keyphrase" do
      assert {:ok, %{display_key: key}} = Facade.register()

      words = String.split(key, "-")
      assert length(words) == 6
      assert Enum.all?(words, &(&1 == String.upcase(&1)))
    end

    test "two registrations produce different keyphrases (overwhelming probability)" do
      {:ok, %{display_key: a}} = Facade.register()
      {:ok, %{display_key: b}} = Facade.register()

      refute a == b
    end

    test "register output authenticates back to the same account" do
      {:ok, %{display_key: key, account_id: id, handle: handle}} = Facade.register()

      assert {:ok, %{account_id: ^id, handle: ^handle}} = Facade.authenticate(key)
    end
  end

  describe "authenticate/1" do
    test "accepts the canonical form" do
      assert {:ok, %{account_id: id, handle: handle}} =
               Facade.authenticate("AMBER-FROST-DELTA-NINE-WOLF-APEX")

      assert byte_size(id) == 64
      assert handle =~ ~r/^[a-z]+-[a-z]+-\d{4}$/
    end

    test "accepts lowercase and stray whitespace" do
      assert {:ok, %{account_id: a}} = Facade.authenticate("amber-frost-delta-nine-wolf-apex")

      assert {:ok, %{account_id: b}} =
               Facade.authenticate("  AMBER-FROST-DELTA-NINE-WOLF-APEX  ")

      assert a == b
    end

    test "rejects empty input" do
      assert {:error, :empty_keyphrase} = Facade.authenticate("")
      assert {:error, :empty_keyphrase} = Facade.authenticate("   ")
    end

    test "rejects non-binary input" do
      assert {:error, :invalid} = Facade.authenticate(nil)
      assert {:error, :invalid} = Facade.authenticate(123)
    end
  end

  describe "handle_for/1" do
    test "returns the same handle as derive_from_keyphrase" do
      {:ok, %{account_id: id, handle: handle}} = Facade.authenticate("BIRD-HACK-CALM-DUEL-EAST-FACE")

      assert Facade.handle_for(id) == handle
    end
  end
end
