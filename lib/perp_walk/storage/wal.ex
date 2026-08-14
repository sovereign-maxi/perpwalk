defmodule PerpWalk.Storage.WAL do
  @moduledoc """
  Boot-time configuration for the application's `Locker.WAL` instance.

  Owns the WAL type registry — the mapping between domain event atoms
  and their on-disk byte identifiers. Domains add their entry types
  here as they come online.

  ## Configuration

  Started by `PerpWalk.Storage.Supervisor`. The WAL itself is a single
  process named `PerpWalk.Storage.WAL` (the module atom doubles as the
  process name) — facade callers use `Storage.Facade.write_wal/2`
  rather than naming this module directly.
  """

  @doc """
  Type registry mapping atoms to byte identifiers. Add new types as
  domains come online; never reuse a byte once retired.

  Reserved range: 0x00 (unused), 0x01–0xFE (domain types), 0xFF (reserved).

  `:checkpoint` is reserved for `Locker.WAL.checkpoint/1` and must
  always be present.
  """
  @spec type_map() :: %{atom() => byte()}
  def type_map do
    # Reserved bytes (never reuse): 0x03 — was :position_put, retired
    # before any deployed write; positions are now always paired with
    # a market change via :trade_executed (0x05) or :market_resolved
    # (0x06).
    %{
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
  end

  @doc "Inverse of `type_map/0` — byte identifier to atom name."
  @spec byte_map() :: %{byte() => atom()}
  def byte_map do
    type_map()
    |> Enum.map(fn {name, byte} -> {byte, name} end)
    |> Map.new()
  end

  @doc "Registered process name for the WAL GenServer."
  @spec server_name() :: atom()
  def server_name, do: __MODULE__

  @doc "Returns the WAL child spec for the storage supervisor."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    wal_opts =
      Keyword.merge(
        [
          name: server_name(),
          wal_dir: PerpWalk.Storage.Paths.storage_wal(),
          types: type_map()
        ],
        opts
      )

    %{
      id: __MODULE__,
      start: {Locker.WAL, :start_link, [wal_opts]},
      type: :worker,
      restart: :permanent
    }
  end
end
