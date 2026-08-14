defmodule PerpWalk.Federation.Audit do
  @moduledoc """
  Append-only operator-action audit log.

  EventBus broadcasts of `OperatorOverride`, halt/resume, and
  similar moments are local-PubSub only — useful for a live
  dashboard but lost the moment no subscriber is up. This log
  persists those events as one JSON object per line in
  `{federation_dir}/operator_audit.jsonl` so the forensic record
  survives reboots, dashboard outages, and operator inattention.

  Single-writer per node. Lines are flushed on write so a crash
  mid-second does not lose the last event.
  """

  require Logger

  alias PerpWalk.Storage.Facade, as: StorageFacade

  @file_name "operator_audit.jsonl"

  @doc """
  Appends an operator-action event. `kind` is a snake_case atom
  (e.g. `:operator_override`, `:signing_halted`); `details` is a
  map of JSON-serialisable values.
  """
  @spec record(atom(), map()) :: :ok
  def record(kind, details) when is_atom(kind) and is_map(details) do
    line =
      Jason.encode!(%{
        timestamp: DateTime.to_iso8601(DateTime.utc_now()),
        node: Atom.to_string(node()),
        kind: kind,
        details: stringify(details)
      }) <> "\n"

    path = log_path()
    File.mkdir_p!(Path.dirname(path))

    case File.open(path, [:append, :sync]) do
      {:ok, fd} ->
        try do
          :ok = IO.binwrite(fd, line)
        after
          File.close(fd)
        end

        File.chmod(path, 0o600)
        :ok

      {:error, reason} ->
        Logger.error("Audit: append failed, reason=#{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.error("Audit: record failed, reason=#{inspect(error)}")
      :ok
  end

  @doc "Returns the absolute path of the audit log."
  @spec log_path() :: String.t()
  def log_path do
    Path.join(StorageFacade.federation_dir(), @file_name)
  end

  defp stringify(map) do
    Map.new(map, fn {k, v} -> {to_string(k), serialize(v)} end)
  end

  defp serialize(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize(value) when is_atom(value) and value not in [nil, true, false], do: Atom.to_string(value)
  defp serialize(value) when is_binary(value) or is_number(value) or value in [nil, true, false], do: value
  defp serialize(value) when is_list(value), do: Enum.map(value, &serialize/1)
  defp serialize(value) when is_map(value), do: stringify(value)
  defp serialize(value), do: inspect(value)
end
