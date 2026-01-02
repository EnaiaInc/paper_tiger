defmodule PaperTiger.Plug.APIChaos do
  @moduledoc """
  Plug middleware that injects chaos into API requests.

  When API chaos is configured via `PaperTiger.ChaosCoordinator`, this plug
  may randomly:
  - Timeout requests (sleep then return 504)
  - Return rate limit errors (429)
  - Return server errors (500/502/503)

  ## Configuration

      PaperTiger.ChaosCoordinator.configure(%{
        api: %{
          timeout_rate: 0.02,      # 2% of requests timeout
          timeout_ms: 5000,        # How long to sleep before 504
          rate_limit_rate: 0.01,   # 1% get 429
          error_rate: 0.01,        # 1% get 500/502/503
          endpoint_overrides: %{
            "/v1/subscriptions" => :rate_limit  # Always rate limit this endpoint
          }
        }
      })
  """

  import Plug.Conn

  alias PaperTiger.ChaosCoordinator

  def init(opts), do: opts

  def call(conn, _opts) do
    case ChaosCoordinator.should_api_fail?(conn.request_path) do
      :ok ->
        conn

      {:timeout, ms} ->
        Process.sleep(ms)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(504, gateway_timeout_error())
        |> halt()

      :rate_limit ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("retry-after", "60")
        |> send_resp(429, rate_limit_error())
        |> halt()

      :server_error ->
        code = Enum.random([500, 502, 503])

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(code, server_error(code))
        |> halt()
    end
  end

  defp gateway_timeout_error do
    Jason.encode!(%{
      error: %{
        code: "request_timeout",
        message: "Request timed out. Please try again.",
        type: "api_error"
      }
    })
  end

  defp rate_limit_error do
    Jason.encode!(%{
      error: %{
        code: "rate_limit",
        message: "Rate limit exceeded. Please slow down your request rate.",
        type: "rate_limit_error"
      }
    })
  end

  defp server_error(500) do
    Jason.encode!(%{
      error: %{
        code: "internal_error",
        message: "An internal server error occurred.",
        type: "api_error"
      }
    })
  end

  defp server_error(502) do
    Jason.encode!(%{
      error: %{
        code: "bad_gateway",
        message: "Bad gateway. The upstream service is unavailable.",
        type: "api_error"
      }
    })
  end

  defp server_error(503) do
    Jason.encode!(%{
      error: %{
        code: "service_unavailable",
        message: "Service temporarily unavailable. Please try again later.",
        type: "api_error"
      }
    })
  end
end
