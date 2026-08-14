defmodule PerpWalkWeb do
  @moduledoc """
  The entrypoint for defining the user-facing web interface.

  Provides JSON API and LiveView markets UI.
  """

  @spec static_paths() :: [String.t()]
  def static_paths, do: ~w(assets fonts images favicon.ico favicon.svg robots.txt)

  @spec router() :: Macro.t()
  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  @spec controller() :: Macro.t()
  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: PerpWalkWeb.Layouts]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  @spec live_view() :: Macro.t()
  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {PerpWalkWeb.Layouts, :app}

      unquote(html_helpers())
    end
  end

  @spec live_component() :: Macro.t()
  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  @spec html() :: Macro.t()
  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import Phoenix.LiveView.Helpers, only: []
      use Blueprint.Components

      alias Phoenix.LiveView.JS

      unquote(verified_routes())
    end
  end

  @spec verified_routes() :: Macro.t()
  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: PerpWalkWeb.Endpoint,
        router: PerpWalkWeb.Router,
        statics: PerpWalkWeb.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
