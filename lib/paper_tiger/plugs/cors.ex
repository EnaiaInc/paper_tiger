defmodule PaperTiger.Plugs.CORS do
  @moduledoc """
  Handles CORS (Cross-Origin Resource Sharing) headers for browser-based testing.

  Allows requests from any origin with commonly needed headers and methods.

  ## Usage

      # In router
      plug PaperTiger.Plugs.CORS

  ## Headers Added

  - `Access-Control-Allow-Origin: *`
  - `Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS`
  - `Access-Control-Allow-Headers: Authorization, Content-Type, Idempotency-Key`
  - `Access-Control-Max-Age: 86400` (24 hours)

  ## Preflight Requests

  Handles OPTIONS requests for CORS preflight by responding with 200 OK.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> put_cors_headers()
    |> handle_preflight()
  end

  ## Private Functions

  defp put_cors_headers(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, DELETE, OPTIONS")
    |> put_resp_header(
      "access-control-allow-headers",
      "Authorization, Content-Type, Idempotency-Key"
    )
    |> put_resp_header("access-control-max-age", "86400")
  end

  defp handle_preflight(%{method: "OPTIONS"} = conn) do
    conn
    |> send_resp(200, "")
    |> halt()
  end

  defp handle_preflight(conn), do: conn
end
