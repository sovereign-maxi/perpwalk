defmodule PerpWalk.Sim.Subaddresses do
  @moduledoc """
  Deterministic per-call subaddress allocator for sim and dev.

  The Monero `subaddress_provider` config can be either a 0-arity
  function or a `{module, function, args}` MFA tuple consumed by
  `PerpWalk.Markets.Services.{Maker, Trader, Disputer}` whenever
  they need a fresh deposit address. Production wires this at the
  default — `&PerpWalk.Monero.Facade.create_subaddress/0` — which
  delegates to the wallet RPC. Sim and dev wire this at
  `{__MODULE__, :next, []}` so the harness can run without a live
  wallet on the loopback.

  The returned address is base58-formatted, prefixed with `8` (the
  Monero subaddress prefix), and matches
  `PerpWalk.Federation.Rules.@xmr_address_re` so it survives the
  `destination_sanity` check on payout if the sim ever round-trips
  a deposit address back through claims. Each call returns a fresh
  monotonically-increasing index — sim runs reset between
  scenarios via `reset/0` so indices start at zero.

  Lives in `sim/lib` so it's compiled in `:dev` and `:test` only;
  a `:prod` release excludes the directory entirely. The
  application supervisor only starts this child when
  `Code.ensure_loaded?/1` returns true, so a release that never
  sees `sim/lib` skips the supervisor entry without compile-time
  reference.
  """

  use GenServer

  @table __MODULE__
  @alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  @body_length 94

  # --- Public API ---

  @doc "Starts the provider and creates its named ETS counter table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the next subaddress + index. Called via the MFA tuple
  configured under `:perpwalk, :subaddress_provider`.

  Returns `{:error, :provider_not_started}` if the table is
  missing — the application supervisor failed to add this child,
  or sim code shipped into a release.
  """
  @spec next() ::
          {:ok, %{address: String.t(), address_index: non_neg_integer()}}
          | {:error, :provider_not_started}
  def next do
    case :ets.whereis(@table) do
      :undefined ->
        {:error, :provider_not_started}

      _ref ->
        idx = :ets.update_counter(@table, :next_idx, {2, 1})
        {:ok, %{address: address_for(idx), address_index: idx}}
    end
  end

  @doc """
  Resets the index counter to zero. Sim runs call this at the
  start of each scenario so indices are reproducible from the
  configured seed.
  """
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "Current next-index without incrementing. Test/debug affordance."
  @spec peek() :: non_neg_integer()
  def peek do
    case :ets.lookup(@table, :next_idx) do
      [{:next_idx, n}] -> n + 1
      [] -> 1
    end
  rescue
    ArgumentError -> 1
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    create_table()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.insert(@table, {:next_idx, 0})
    {:reply, :ok, state}
  end

  # --- Internal ---

  defp create_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
        :ets.insert(@table, {:next_idx, 0})

      _ref ->
        :ok
    end
  end

  # Builds a 95-char address: prefix `8` + 94-char body, all
  # base58 alphabet, deterministic from `idx`. Three SHA-256
  # hashes give 96 bytes of pseudo-random material; we take 94
  # and fold each byte into the alphabet via modulo. Same idx
  # always yields the same address.
  defp address_for(idx) when is_integer(idx) and idx >= 0 do
    seed_a = "perpwalk-sim-subaddress-a:" <> Integer.to_string(idx)
    seed_b = "perpwalk-sim-subaddress-b:" <> Integer.to_string(idx)
    seed_c = "perpwalk-sim-subaddress-c:" <> Integer.to_string(idx)

    bytes =
      :crypto.hash(:sha256, seed_a) <>
        :crypto.hash(:sha256, seed_b) <> :crypto.hash(:sha256, seed_c)

    body =
      bytes
      |> binary_part(0, @body_length)
      |> :binary.bin_to_list()
      |> Enum.map_join("", fn b -> <<Enum.at(@alphabet, rem(b, 58))>> end)

    "8" <> body
  end
end
