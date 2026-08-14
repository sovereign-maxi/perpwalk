defmodule PerpWalkAdminWeb.PageController do
  @moduledoc false

  use PerpWalkAdminWeb, :controller

  @doc "Top-level admin route — redirects to the dashboard page."
  def redirect_to_dashboard(conn, _params) do
    redirect(conn, to: "/admin/dashboard")
  end
end
