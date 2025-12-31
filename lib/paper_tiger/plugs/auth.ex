defmodule PaperTiger.Plugs.Auth do
  @moduledoc """
  Authenticates requests using Stripe-compatible API key verification.

  ## Authentication Modes

  - **Lenient (default)** - Accepts any non-empty Authorization header
  - **Strict** - Validates key format (sk_test_*, sk_live_*)

  ## Usage

      # In router
      plug PaperTiger.Plugs.Auth
      plug PaperTiger.Plugs.Auth, mode: :strict

  ## Stripe Authentication Format

  Stripe uses HTTP Basic Auth with the API key as the username:

      Authorization: Bearer sk_test_abc123
      # or
      Authorization: Basic c2tfdGVzdF9hYmMxMjM6  (base64 of "sk_test_abc123:")

  ## Error Response

      {
        "error": {
          "type": "invalid_request_error",
          "message": "You did not provide an API key..."
        }
      }
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @impl true
  def init(opts), do: Keyword.get(opts, :mode, :lenient)

  @impl true
  def call(conn, mode) do
    case get_req_header(conn, "authorization") do
      [] ->
        send_auth_error(conn, "You did not provide an API key.")

      [auth_header | _] ->
        validate_auth_header(conn, auth_header, mode)
    end
  end

  ## Private Functions

  defp validate_auth_header(conn, "Bearer " <> key, mode) do
    validate_key(conn, key, mode)
  end

  defp validate_auth_header(conn, "Basic " <> encoded, mode) do
    # Decode base64 and extract key (format: "sk_test_key:")
    case Base.decode64(encoded) do
      {:ok, decoded} ->
        key = decoded |> String.split(":") |> List.first()
        validate_key(conn, key, mode)

      :error ->
        send_auth_error(conn, "Invalid authorization header encoding.")
    end
  end

  defp validate_auth_header(conn, _invalid, _mode) do
    send_auth_error(
      conn,
      "Invalid authorization header format. Use 'Bearer sk_test_...' or 'Basic ...'."
    )
  end

  defp validate_key(conn, key, :lenient) when is_binary(key) and byte_size(key) > 0 do
    Logger.debug("Auth: accepted key in lenient mode")
    assign(conn, :api_key, key)
  end

  defp validate_key(conn, key, :strict) do
    cond do
      String.starts_with?(key, "sk_test_") ->
        Logger.debug("Auth: accepted test key")
        assign(conn, :api_key, key)

      String.starts_with?(key, "sk_live_") ->
        Logger.debug("Auth: accepted live key")
        assign(conn, :api_key, key)

      true ->
        send_auth_error(conn, "Invalid API key format. Expected 'sk_test_*' or 'sk_live_*'.")
    end
  end

  defp validate_key(conn, _empty_key, _mode) do
    send_auth_error(conn, "You did not provide an API key.")
  end

  defp send_auth_error(conn, message) do
    Logger.debug("Auth: rejected - #{message}")

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      401,
      Jason.encode!(%{
        error: %{
          message: message,
          type: "invalid_request_error"
        }
      })
    )
    |> halt()
  end
end
