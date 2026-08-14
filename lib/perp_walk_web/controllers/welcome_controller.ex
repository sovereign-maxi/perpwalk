defmodule PerpWalkWeb.WelcomeController do
  @moduledoc """
  Handles dismissal of the first-visit welcome modal.

  The modal is a phishing-defense + orientation surface rendered by
  the root layout when `get_session(conn, :welcomed)` is not true.
  Users click CONTINUE, which submits an HTML form here; we mark
  the session welcomed and redirect back to where they were.

  Deliberately server-side and JavaScript-free — Tor Browser
  safest-mode disables JS, and the welcome surface is exactly the
  interaction we cannot afford to break for that audience.
  """

  use PerpWalkWeb, :controller

  @doc """
  Safely determines whether this connection's session is marked
  welcomed. Returns `true` (skip modal) if the session hasn't been
  fetched — some LiveView render paths don't have session state
  attached, and defaulting to "welcomed" avoids spurious modal
  renders in those contexts.
  """
  @spec welcomed?(Plug.Conn.t()) :: boolean()
  def welcomed?(%Plug.Conn{private: %{plug_session: session}}) when is_map(session),
    do: Map.get(session, "welcomed") == true

  def welcomed?(_conn), do: true

  @doc """
  Marks the session as having seen the welcome modal, then
  redirects to the safe caller-supplied path (or `/` as fallback).
  """
  def dismiss(conn, params) do
    conn
    |> put_session(:welcomed, true)
    |> redirect(to: safe_redirect(params["redirect_to"]))
  end

  # Only accept same-origin relative paths — reject external URLs,
  # protocol-relative URLs, and anything that would bounce the user
  # off the venue.
  defp safe_redirect(nil), do: "/"
  defp safe_redirect(""), do: "/"

  defp safe_redirect(<<"/", rest::binary>>) do
    # Reject "//host" (protocol-relative) AND "/\host" — WHATWG URL
    # parsing treats backslash as a separator for special schemes,
    # so browsers navigate "/\evil.com" to "//evil.com". Both are
    # open-redirect shapes.
    case String.first(rest) do
      "/" -> "/"
      "\\" -> "/"
      _ -> "/" <> rest
    end
  end

  defp safe_redirect(_), do: "/"
end
