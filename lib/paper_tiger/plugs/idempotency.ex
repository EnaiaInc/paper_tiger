defmodule PaperTiger.Plugs.Idempotency do
  @moduledoc """
  Handles Stripe-compatible idempotency key processing.

  Prevents duplicate POST requests from creating duplicate resources by
  caching responses keyed by the `Idempotency-Key` header.

  ## Usage

      # In router
      plug PaperTiger.Plugs.Idempotency

  ## Behavior

  - **GET requests** - Idempotency keys ignored (safe methods)
  - **POST with key** - Check cache, return cached response if exists
  - **POST without key** - Process normally (not idempotent)

  ## Cache Storage

  Responses cached for 24 hours via `PaperTiger.Idempotency`.

  ## Implementation

  This plug only checks the cache. Storing responses happens in resource
  handlers after successful processing.

  ## Example

      # First request with key
      POST /v1/customers
      Idempotency-Key: abc123
      => Creates customer, stores response

      # Duplicate request (network retry)
      POST /v1/customers
      Idempotency-Key: abc123
      => Returns cached customer (no duplicate created)
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "POST"} = conn, _opts) do
    case get_req_header(conn, "idempotency-key") do
      [] ->
        # No idempotency key - process normally
        conn

      [key | _] ->
        check_idempotency(conn, key)
    end
  end

  def call(conn, _opts) do
    # GET, DELETE, etc. - idempotency not needed
    conn
  end

  ## Private Functions

  defp check_idempotency(conn, key) do
    case PaperTiger.Idempotency.check(key) do
      :new_request ->
        Logger.debug("Idempotency: new request with key=#{key}")
        assign(conn, :idempotency_key, key)

      {:cached, response} ->
        Logger.debug("Idempotency: returning cached response for key=#{key}")
        send_cached_response(conn, response)

      :in_progress ->
        Logger.debug("Idempotency: request in progress for key=#{key}")
        send_in_progress_response(conn, key)
    end
  end

  defp send_cached_response(conn, response) do
    conn
    |> put_resp_header("x-idempotency-cached", "true")
    |> send_json_response(200, response)
  end

  defp send_in_progress_response(conn, key) do
    error = %{
      error: %{
        idempotency_key: key,
        message: "A request with this idempotency key is currently being processed. Please retry in a moment.",
        type: "idempotency_error"
      }
    }

    conn
    |> put_resp_header("retry-after", "1")
    |> send_json_response(409, error)
  end

  defp send_json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
