defmodule PerpWalkWeb.Plugs.SecurityHeaders do
  @moduledoc """
  Plug enforcing strict security headers and stripping identifying headers.

  Ensures no response leaks information about the server software,
  framework, or infrastructure. All responses get strict CSP,
  cache-control, and standard security headers.
  """

  # CORS is intentionally not configured. The user surface is accessed via Tor
  # hidden services. The CSP `default-src 'none'` on API routes provides
  # implicit cross-origin protection for the rare case of browser-based access.

  @behaviour Plug

  import Plug.Conn

  @api_csp "default-src 'none'; frame-ancestors 'none'"

  @browser_csp [
                 "default-src 'self'",
                 "script-src 'self'",
                 # LiveView DOM patching requires inline styles.
                 "style-src 'self' 'unsafe-inline'",
                 "font-src 'self'",
                 "img-src 'self' data:",
                 # Media (audio/video/track) fall back to default-src
                 # without an explicit directive; `data:` is needed for
                 # any inline sound/notification asset shipped in-page.
                 "media-src 'self' data:",
                 "connect-src 'self'",
                 "frame-ancestors 'none'"
               ]
               |> Enum.join("; ")

  @common_headers [
    {"x-content-type-options", "nosniff"},
    {"x-frame-options", "DENY"},
    {"cache-control", "no-store"},
    {"referrer-policy", "no-referrer"}
  ]

  @stripped_headers ["server", "x-powered-by", "x-request-id"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    csp = if browser_request?(conn), do: @browser_csp, else: @api_csp

    conn
    |> put_resp_header("content-security-policy", csp)
    |> set_common_headers()
    |> register_before_send(&strip_identifying_headers/1)
  end

  defp browser_request?(conn) do
    case get_req_header(conn, "accept") do
      [accept | _] -> String.contains?(accept, "text/html")
      _ -> false
    end
  end

  defp set_common_headers(conn) do
    Enum.reduce(@common_headers, conn, fn {key, value}, acc ->
      put_resp_header(acc, key, value)
    end)
  end

  defp strip_identifying_headers(conn) do
    Enum.reduce(@stripped_headers, conn, fn header, acc ->
      delete_resp_header(acc, header)
    end)
  end
end
