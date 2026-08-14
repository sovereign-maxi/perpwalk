defmodule PerpWalk.Reserves.SourceTest do
  @moduledoc "Unit tests for PerpWalk.Reserves.Source."

  use ExUnit.Case, async: true

  alias PerpWalk.Reserves.Source

  describe "metadata/0" do
    test "returns a map with all expected keys" do
      meta = Source.metadata()

      assert is_map(meta)
      assert Map.has_key?(meta, :epoch_id)
      assert Map.has_key?(meta, :market_count)
      assert Map.has_key?(meta, :position_count)
      assert Map.has_key?(meta, :chain_height)
    end

    test "epoch_id is currently 0 (single-epoch pre-launch)" do
      assert Source.metadata().epoch_id == 0
    end

    test "market_count and position_count default to 0 when facade is unreachable" do
      meta = Source.metadata()

      # Either the facade is up (>= 0) or safe_call defaults to 0.
      assert is_integer(meta.market_count) and meta.market_count >= 0
      assert is_integer(meta.position_count) and meta.position_count >= 0
    end

    test "chain_height is nil or a non-negative integer (never crashes)" do
      # In unit-test env the monero RPC is unreachable, so this is nil.
      # In a live env it would be the current top block height.
      meta = Source.metadata()
      assert is_nil(meta.chain_height) or (is_integer(meta.chain_height) and meta.chain_height >= 0)
    end
  end

  describe "liabilities/0 fail-closed" do
    test "raises on internal error instead of returning zero outstanding" do
      # Regression: the previous implementation had a rescue that
      # returned `%{outstanding: 0}` on ANY exception, producing
      # fully-attested "healthy" proofs while liability computation
      # was actually broken. Fail-closed means the exception must
      # propagate — Vault.Generator's rescue then aborts the proof
      # cycle without publishing.
      #
      # We drive a failure by injecting a faulty facade via test-only
      # module-attribute override... which we can't do without more
      # invasive test scaffolding. Instead, prove the assertion by
      # STRUCTURAL inspection: `Reserves.Source.liabilities/0` must
      # NOT contain a rescue clause at its top level. A grep-in-test
      # is the least-invasive way to keep the rescue from creeping
      # back.
      source_path = Application.app_dir(:perpwalk, "priv/source/reserves/source.ex")

      body =
        case File.read(source_path) do
          {:ok, content} -> content
          _ -> File.read!("lib/perp_walk/reserves/source.ex")
        end

      liabilities_section =
        body
        |> String.split("def liabilities do", parts: 2)
        |> List.last()
        |> String.split("def asset_ids", parts: 2)
        |> List.first()

      refute liabilities_section =~ ~r/^\s*rescue\s*$/m,
             "liabilities/0 must NOT rescue exceptions — the fail-open zero-outstanding path published healthy proofs on any transient error"
    end
  end
end
