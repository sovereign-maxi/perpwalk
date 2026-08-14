defmodule PerpWalkWeb.HealthController do
  @moduledoc """
  Health check endpoints for liveness and readiness probes.

  - `/health/live` returns 200 once the BEAM is up.
  - `/health/ready` returns 200 once the application has started and is
    ready to handle traffic, 503 otherwise.
  """

  use PerpWalkWeb, :controller

  def live(conn, _params) do
    conn
    |> put_status(:ok)
    |> json(%{status: "ok"})
  end

  def ready(conn, _params) do
    if Process.whereis(PerpWalk.Supervisor) do
      conn
      |> put_status(:ok)
      |> json(%{status: "ok"})
    else
      conn
      |> put_status(:service_unavailable)
      |> json(%{status: "starting"})
    end
  end
end
