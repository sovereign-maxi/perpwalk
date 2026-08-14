defmodule PerpWalkWeb.Router do
  @moduledoc false

  use PerpWalkWeb, :router

  import PerpWalkWeb.Auth, only: [fetch_current_account: 2]

  pipeline :api do
    plug :accepts, ["json"]
    plug PerpWalk.Identity.Gate
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PerpWalkWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug PerpWalk.Identity.Gate
    plug :fetch_current_account
  end

  pipeline :health do
    plug :accepts, ["json"]
  end

  scope "/health", PerpWalkWeb do
    pipe_through :health
    get "/", HealthController, :ready
    get "/live", HealthController, :live
    get "/ready", HealthController, :ready
  end

  scope "/api", PerpWalkWeb do
    pipe_through :api
    get "/reserves", ReservesController, :show
    get "/reserves/history", ReservesController, :history
  end

  scope "/", PerpWalkWeb do
    pipe_through :browser

    get "/auth/login", AuthController, :new
    post "/auth/login", AuthController, :login
    post "/auth/generate", AuthController, :generate
    get "/auth/welcome", AuthController, :welcome
    post "/auth/logout", AuthController, :logout

    post "/welcome/dismiss", WelcomeController, :dismiss

    live_session :markets, on_mount: {PerpWalkWeb.Auth, :default} do
      live "/", MarketsLive, :index
      live "/markets", MarketsLive, :index
      live "/markets/new", MarketNewLive, :new
      live "/markets/:id", MarketLive, :show
      live "/leaderboard", LeaderboardLive, :index
      live "/portfolio", PortfolioLive, :index
    end
  end
end
