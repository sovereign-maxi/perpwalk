defmodule PerpWalk.Markets.Store.Serialize do
  @moduledoc """
  Pure data-shape conversion between Markets entities and their WAL
  payload form.

  Entities are persisted as plain maps with primitives only — no
  struct types, no DateTime structs. Across a BEAM restart the WAL
  is read back with `:erlang.binary_to_term(bin, [:safe])`, which
  refuses any atom not yet in the atom table. DateTime structs carry
  `:"Elixir.Calendar.ISO"`, an atom that may not be loaded by the
  time `Markets.Store.init/1` runs, so timestamps are stored as
  ISO8601 strings and parsed back on read.

  Pure module — no ETS, no GenServer state, no IO.
  """

  alias PerpWalk.Markets.{AMM, Dispute, Market, Position, Quote, Vote}

  # --- Market ---

  @spec market(Market.t()) :: map()
  def market(%Market{} = m) do
    %{
      id: m.id,
      description: m.description,
      resolution_criterion: m.resolution_criterion,
      category: m.category,
      unit_size: m.unit_size,
      expiry: encode_dt(m.expiry),
      resolution_deadline: encode_dt(m.resolution_deadline),
      status: m.status,
      pool: %{yes: m.pool.yes, no: m.pool.no},
      creator_account_id: m.creator_account_id,
      deposit_amount: m.deposit_amount,
      deposit_subaddress: m.deposit_subaddress,
      deposit_subaddress_index: m.deposit_subaddress_index,
      deposit_confirmed_at: encode_dt(m.deposit_confirmed_at),
      reputation: m.reputation,
      disputes_acknowledged_count: m.disputes_acknowledged_count,
      created_at: encode_dt(m.created_at),
      activated_at: encode_dt(m.activated_at),
      resolution_submitted_at: encode_dt(m.resolution_submitted_at),
      resolved_at: encode_dt(m.resolved_at),
      outcome: m.outcome,
      creator_lp_paid_out_at: encode_dt(m.creator_lp_paid_out_at)
    }
  end

  @spec to_market(map()) :: Market.t()
  def to_market(map) do
    %Market{
      id: map.id,
      description: map.description,
      resolution_criterion: map.resolution_criterion,
      category: map.category,
      unit_size: map.unit_size,
      expiry: decode_dt(map.expiry),
      resolution_deadline: decode_dt(map.resolution_deadline),
      status: map.status,
      pool: %AMM{yes: map.pool.yes, no: map.pool.no},
      creator_account_id: map.creator_account_id,
      deposit_amount: map.deposit_amount,
      deposit_subaddress: map.deposit_subaddress,
      deposit_subaddress_index: map.deposit_subaddress_index,
      deposit_confirmed_at: decode_dt(map.deposit_confirmed_at),
      reputation: map.reputation,
      disputes_acknowledged_count: map.disputes_acknowledged_count,
      created_at: decode_dt(map.created_at),
      # Pre-activated_at WAL entries don't carry this key — default to
      # nil so old markets read back as "activation time unknown" and
      # the chart caller falls back to `created_at` for those.
      activated_at: decode_dt(Map.get(map, :activated_at)),
      # Pre-auto-settle WAL entries don't carry this key — default to
      # nil so old markets read back as "submission time unknown".
      # The resolving tick skips nil-anchored markets; an operator
      # settles those manually.
      resolution_submitted_at: decode_dt(Map.get(map, :resolution_submitted_at)),
      resolved_at: decode_dt(map.resolved_at),
      outcome: map.outcome,
      # Pre-LP-model WAL entries don't carry this key — default to nil
      # so old markets read back as "not yet returned" (which is true
      # under the old model too; they just never get an LP return).
      creator_lp_paid_out_at: decode_dt(Map.get(map, :creator_lp_paid_out_at))
    }
  end

  # --- Position ---

  @spec position(Position.t()) :: map()
  def position(%Position{} = p) do
    %{
      id: p.id,
      market_id: p.market_id,
      account_id: p.account_id,
      side: p.side,
      contracts: p.contracts,
      amount_paid: p.amount_paid,
      spread_piconeros: p.spread_piconeros,
      status: p.status,
      created_at: encode_dt(p.created_at),
      settled_at: encode_dt(p.settled_at),
      paid_out_at: encode_dt(p.paid_out_at),
      payout_txid: p.payout_txid
    }
  end

  @spec to_position(map()) :: Position.t()
  def to_position(map) do
    %Position{
      id: map.id,
      market_id: map.market_id,
      account_id: map.account_id,
      side: map.side,
      contracts: map.contracts,
      amount_paid: map.amount_paid,
      # Default spread to 0 for legacy WAL entries written before
      # the field existed — impossible in production (this was a
      # launch-blocking change shipping to a fresh WAL). Keeps
      # replay tolerant of mixed-version historical entries.
      spread_piconeros: Map.get(map, :spread_piconeros, 0),
      status: map.status,
      created_at: decode_dt(map.created_at),
      settled_at: decode_dt(map.settled_at),
      paid_out_at: decode_dt(map.paid_out_at),
      payout_txid: map.payout_txid
    }
  end

  # --- Vote ---

  @spec vote(Vote.t()) :: map()
  def vote(%Vote{} = v) do
    %{
      account_id: v.account_id,
      market_id: v.market_id,
      direction: v.direction,
      created_at: encode_dt(v.created_at)
    }
  end

  @spec to_vote(map()) :: Vote.t()
  def to_vote(map) do
    %Vote{
      account_id: map.account_id,
      market_id: map.market_id,
      direction: map.direction,
      created_at: decode_dt(map.created_at)
    }
  end

  # --- Dispute ---

  @spec dispute(Dispute.t()) :: map()
  def dispute(%Dispute{} = d) do
    %{
      account_id: d.account_id,
      market_id: d.market_id,
      status: d.status,
      stake_amount_piconeros: d.stake_amount_piconeros,
      deposit_subaddress: d.deposit_subaddress,
      deposit_subaddress_index: d.deposit_subaddress_index,
      deposit_confirmed_at: encode_dt(d.deposit_confirmed_at),
      slashed_amount_piconeros: d.slashed_amount_piconeros,
      resolved_at: encode_dt(d.resolved_at),
      created_at: encode_dt(d.created_at)
    }
  end

  @spec to_dispute(map()) :: Dispute.t()
  def to_dispute(map) do
    %Dispute{
      account_id: map.account_id,
      market_id: map.market_id,
      status: map.status,
      stake_amount_piconeros: map.stake_amount_piconeros,
      deposit_subaddress: map.deposit_subaddress,
      deposit_subaddress_index: map.deposit_subaddress_index,
      deposit_confirmed_at: decode_dt(map.deposit_confirmed_at),
      slashed_amount_piconeros: map.slashed_amount_piconeros,
      resolved_at: decode_dt(map.resolved_at),
      created_at: decode_dt(map.created_at)
    }
  end

  # --- Quote ---

  @spec quote(Quote.t()) :: map()
  def quote(%Quote{} = q) do
    %{
      id: q.id,
      market_id: q.market_id,
      account_id: q.account_id,
      side: q.side,
      contracts: q.contracts,
      amount_paid_piconeros: q.amount_paid_piconeros,
      spread_piconeros: q.spread_piconeros,
      subaddress: q.subaddress,
      subaddress_index: q.subaddress_index,
      refund_address: q.refund_address,
      expires_at: encode_dt(q.expires_at),
      created_at: encode_dt(q.created_at)
    }
  end

  @spec to_quote(map()) :: Quote.t()
  def to_quote(map) do
    %Quote{
      id: map.id,
      market_id: map.market_id,
      account_id: map.account_id,
      side: map.side,
      contracts: map.contracts,
      amount_paid_piconeros: map.amount_paid_piconeros,
      spread_piconeros: Map.get(map, :spread_piconeros, 0),
      subaddress: map.subaddress,
      subaddress_index: map.subaddress_index,
      refund_address: Map.get(map, :refund_address, ""),
      expires_at: decode_dt(map.expires_at),
      created_at: decode_dt(map.created_at)
    }
  end

  # --- DateTime Helpers ---

  defp encode_dt(nil), do: nil
  defp encode_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp decode_dt(nil), do: nil

  defp decode_dt(iso) when is_binary(iso) do
    {:ok, dt, _offset} = DateTime.from_iso8601(iso)
    dt
  end

  # A WAL entry whose timestamp field decoded to anything other than
  # nil or an ISO8601 string would otherwise raise FunctionClauseError
  # and abort the whole cold-boot replay. Fall back to nil so the rest
  # of the WAL continues to apply; halt-on-corrupt at the entry level
  # still catches structurally-corrupted payloads via the dedicated
  # `{:__corrupted__, _}` path.
  defp decode_dt(_), do: nil
end
