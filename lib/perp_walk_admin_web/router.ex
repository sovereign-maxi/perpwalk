defmodule PerpWalkAdminWeb.Router do
  @moduledoc """
  Admin router — serves the read-only operator dashboard.

  The admin endpoint binds to its own Tor hidden service (.onion).
  The .onion address itself is the capability — no auth lives here.
  All destructive operations (resolve, void, reverse) happen via
  `iex --remsh`, not HTTP, so no write endpoints are exposed.

  Three LiveView pages share one chrome:

    * `/admin/dashboard` — venue stats (markets, activity, wallet, income)
    * `/admin/system` — host metrics (CPU/memory sparklines + BEAM/disks)
    * `/admin/events` — active alerts + event stream, two-column

  `/admin` redirects to `/admin/dashboard`.
  """

  use PerpWalkAdminWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PerpWalkAdminWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/admin", PerpWalkAdminWeb do
    pipe_through :browser

    get "/", PageController, :redirect_to_dashboard

    live_session :admin do
      live "/dashboard", Live.Dashboard, :index
      live "/system", Live.System, :index
      live "/events", Live.Events, :index
    end
  end
end
