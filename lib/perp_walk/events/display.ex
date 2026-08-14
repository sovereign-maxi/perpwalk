defprotocol PerpWalk.Events.Display do
  @moduledoc """
  Self-describing rendering for domain events.

  Each event implements four functions: `domain/1`, `label/1`,
  `severity/1`, `detail/1`. Consumers (logs, dashboard ticker, Nostr
  publishers) render these without interpreting event types.

  Severity is one of `:info`, `:warning`, `:critical`, `:emergency`.
  """

  @doc ~S(Bounded-context name, e.g. "Markets", "Monero", "Storage".)
  @spec domain(t) :: String.t()
  def domain(event)

  @doc ~S(Human-readable event label, e.g. "Market Created".)
  @spec label(t) :: String.t()
  def label(event)

  @doc "Severity atom: `:info`, `:warning`, `:critical`, `:emergency`."
  @spec severity(t) :: :info | :warning | :critical | :emergency
  def severity(event)

  @doc "Short detail string carrying ids/amounts. Empty string if none."
  @spec detail(t) :: String.t()
  def detail(event)
end

# --- Markets Context ---

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Markets.MarketCreated do
  def domain(_), do: "Markets"
  def label(_), do: "Market Created"
  def severity(_), do: :info
  def detail(e), do: "market_id=#{e.market_id} category=#{e.category}"
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Markets.MarketActivated do
  def domain(_), do: "Markets"
  def label(_), do: "Market Activated"
  def severity(_), do: :info
  def detail(e), do: "market_id=#{e.market_id}"
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Markets.MarketRejected do
  def domain(_), do: "Markets"
  def label(_), do: "Market Rejected"
  def severity(_), do: :warning
  def detail(e), do: "market_id=#{e.market_id} reputation=#{e.reputation}"
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Markets.MarketExpired do
  def domain(_), do: "Markets"
  def label(_), do: "Market Expired"
  def severity(_), do: :info
  def detail(e), do: "market_id=#{e.market_id}"
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Markets.PositionOpened do
  def domain(_), do: "Markets"
  def label(_), do: "Position Opened"
  def severity(_), do: :info

  def detail(e) do
    "market_id=#{e.market_id} side=#{e.side} contracts=#{e.contracts} paid=#{e.amount_paid}"
  end
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Markets.QuoteCreated do
  def domain(_), do: "Markets"
  def label(_), do: "Quote Created"
  def severity(_), do: :info

  def detail(e) do
    "market_id=#{e.market_id} side=#{e.side} contracts=#{e.contracts} amount=#{e.amount_paid_piconeros}"
  end
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Markets.QuoteFilled do
  def domain(_), do: "Markets"
  def label(_), do: "Quote Filled"
  def severity(_), do: :info

  def detail(e) do
    "market_id=#{e.market_id} side=#{e.side} contracts=#{e.contracts} amount=#{e.amount_paid_piconeros}"
  end
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Markets.PositionPaidOut do
  def domain(_), do: "Markets"
  def label(_), do: "Position Paid Out"
  def severity(_), do: :info

  def detail(e) do
    "position_id=#{e.position_id} market_id=#{e.market_id} amount=#{e.amount_piconeros}"
  end
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Markets.PositionCancelled do
  def domain(_), do: "Markets"
  def label(_), do: "Position Cancelled"
  def severity(_), do: :info
  def detail(e), do: "position_id=#{e.position_id} refunded=#{e.amount_refunded}"
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Markets.ResolutionSubmitted do
  def domain(_), do: "Markets"
  def label(_), do: "Resolution Submitted"
  def severity(_), do: :info
  def detail(e), do: "market_id=#{e.market_id} outcome=#{e.outcome}"
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Markets.ResolutionReversed do
  def domain(_), do: "Markets"
  def label(_), do: "Resolution Reversed"
  def severity(_), do: :warning

  def detail(e) do
    "market_id=#{e.market_id} prev=#{e.previous_outcome} new=#{e.new_outcome}"
  end
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Markets.MarketSettled do
  def domain(_), do: "Markets"
  def label(_), do: "Market Settled"
  def severity(_), do: :info
  def detail(e), do: "market_id=#{e.market_id} outcome=#{e.outcome}"
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Markets.MarketVoided do
  def domain(_), do: "Markets"
  def label(_), do: "Market Voided"
  def severity(_), do: :warning
  def detail(e), do: "market_id=#{e.market_id} reason=#{e.reason}"
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Markets.DepositBurned do
  def domain(_), do: "Markets"
  def label(_), do: "Deposit Burned"
  def severity(_), do: :warning
  def detail(e), do: "market_id=#{e.market_id} amount=#{e.amount}"
end

# --- Reserves Context ---

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Reserves.ProofGenerated do
  def domain(_), do: "Reserves"
  def label(_), do: "Proof Generated"
  def severity(_), do: :info

  def detail(e) do
    ratio = format_ratio(e.ratio)
    "ratio=#{ratio}, status=#{e.status}"
  end

  defp format_ratio(:infinity), do: "100%"
  defp format_ratio(r) when is_number(r), do: "#{Float.round(r * 100, 1)}%"
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Reserves.ReserveDeficit do
  def domain(_), do: "Reserves"
  def label(_), do: "Reserve Deficit"
  def severity(_), do: :warning
  def detail(e), do: "deficit=#{e.deficit_piconeros} piconeros"
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Reserves.ReserveCriticalDeficit do
  def domain(_), do: "Reserves"
  def label(_), do: "Reserve Critical Deficit"
  def severity(_), do: :critical
  def detail(e), do: "deficit=#{e.deficit_piconeros} piconeros"
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Reserves.ReserveRecovered do
  def domain(_), do: "Reserves"
  def label(_), do: "Reserve Recovered"
  def severity(_), do: :info

  def detail(e) do
    ratio = format_ratio(e.ratio)
    "ratio=#{ratio}"
  end

  defp format_ratio(:infinity), do: "100%"
  defp format_ratio(r) when is_number(r), do: "#{Float.round(r * 100, 1)}%"
end

# --- Telemetry Context ---

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Telemetry.SystemStatusChanged do
  def domain(_), do: "Telemetry"
  def label(_), do: "System Status Changed"
  def severity(%{status: :healthy}), do: :info
  def severity(%{status: :degraded}), do: :warning
  def severity(%{status: status}) when status in [:critical, :halted], do: :critical
  def severity(_), do: :info
  def detail(e), do: "status=#{e.status}"
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Telemetry.AlertFired do
  def domain(e), do: e.domain
  def label(e), do: humanise(e.name)
  def severity(%{severity: :emergency}), do: :critical
  def severity(%{severity: s}) when s in [:critical, :warning, :info], do: s
  def severity(_), do: :warning
  def detail(e), do: to_string(e.reason || "")

  defp humanise(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp humanise(name), do: to_string(name)
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Telemetry.AlertResolved do
  def domain(e), do: e.domain
  def label(e), do: humanise(e.name)
  def severity(_), do: :info
  def detail(_), do: "status=resolved"

  defp humanise(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp humanise(name), do: to_string(name)
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Telemetry.TorDown do
  def domain(_), do: "Tor"
  def label(_), do: "Tor Down"
  def severity(_), do: :critical
  def detail(e), do: e.reason || ""
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Telemetry.TorDegraded do
  def domain(_), do: "Tor"
  def label(_), do: "Tor Degraded"
  def severity(_), do: :warning
  def detail(e), do: e.reason || ""
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Telemetry.TorRecovered do
  def domain(_), do: "Tor"
  def label(_), do: "Tor Recovered"
  def severity(_), do: :info
  def detail(_), do: ""
end

# --- Federation Context ---

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Federation.PayoutRequested do
  def domain(_), do: "Federation"
  def label(_), do: "Payout Requested"
  def severity(_), do: :info

  def detail(e) do
    "request=#{short(e.request_id)} kind=#{e.kind} amount=#{e.amount_piconeros}"
  end

  defp short(id) when is_binary(id) and byte_size(id) >= 8, do: String.slice(id, 0, 8)
  defp short(id), do: to_string(id)
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Federation.RuleCheckPassed do
  def domain(_), do: "Federation"
  def label(_), do: "Rule Check Passed"
  def severity(_), do: :info
  def detail(e), do: "request=#{short(e.request_id)}"

  defp short(id) when is_binary(id) and byte_size(id) >= 8, do: String.slice(id, 0, 8)
  defp short(id), do: to_string(id)
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Federation.RuleCheckFailed do
  def domain(_), do: "Federation"
  def label(_), do: "Rule Check Failed"
  def severity(_), do: :warning
  def detail(e), do: "request=#{short(e.request_id)} reason=#{e.reason}"

  defp short(id) when is_binary(id) and byte_size(id) >= 8, do: String.slice(id, 0, 8)
  defp short(id), do: to_string(id)
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Federation.PayoutSubmitted do
  def domain(_), do: "Federation"
  def label(_), do: "Payout Submitted"
  def severity(_), do: :info

  def detail(e) do
    "request=#{short(e.request_id)} txid=#{e.payout_txid} amount=#{e.amount_piconeros}"
  end

  defp short(id) when is_binary(id) and byte_size(id) >= 8, do: String.slice(id, 0, 8)
  defp short(id), do: to_string(id)
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Federation.PayoutFailed do
  def domain(_), do: "Federation"
  def label(_), do: "Payout Failed"
  def severity(_), do: :critical
  def detail(e), do: "request=#{short(e.request_id)} reason=#{e.reason}"

  defp short(id) when is_binary(id) and byte_size(id) >= 8, do: String.slice(id, 0, 8)
  defp short(id), do: to_string(id)
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Federation.PeerLost do
  def domain(_), do: "Federation"
  def label(_), do: "Peer Lost"
  def severity(_), do: :warning
  def detail(e), do: "peer_id=#{inspect(e.peer_id)}"
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Federation.PeerJoined do
  def domain(_), do: "Federation"
  def label(_), do: "Peer Joined"
  def severity(_), do: :info
  def detail(e), do: "peer_id=#{inspect(e.peer_id)}"
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Federation.QuorumLost do
  def domain(_), do: "Federation"
  def label(_), do: "Quorum Lost"
  def severity(_), do: :critical
  def detail(e), do: "online=#{e.online} threshold=#{e.threshold}"
end

defimpl PerpWalk.Events.Display, for: PerpWalk.Events.Federation.QuorumRestored do
  def domain(_), do: "Federation"
  def label(_), do: "Quorum Restored"
  def severity(_), do: :info
  def detail(e), do: "online=#{e.online} threshold=#{e.threshold}"
end
