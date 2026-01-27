defmodule PaperTiger.Resources.Webhook do
  @moduledoc """
  Handles Webhook Endpoint resource endpoints.

  ## Endpoints

  - POST   /v1/webhook_endpoints      - Create webhook endpoint
  - GET    /v1/webhook_endpoints/:id  - Retrieve webhook endpoint
  - POST   /v1/webhook_endpoints/:id  - Update webhook endpoint
  - DELETE /v1/webhook_endpoints/:id  - Delete webhook endpoint
  - GET    /v1/webhook_endpoints      - List webhook endpoints

  ## Webhook Endpoint Object

      %{
        id: "we_...",
        object: "webhook_endpoint",
        created: 1234567890,
        url: "https://example.com/webhook",
        secret: "whsec_...",
        enabled_events: ["charge.succeeded", "customer.created"],
        status: "enabled",
        metadata: %{},
        # ... other fields
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Webhooks


  @doc """
  Creates a new webhook endpoint.

  ## Required Parameters

  - url - Webhook endpoint URL
  - enabled_events - Array of event types to subscribe to

  ## Optional Parameters

  - metadata - Key-value metadata
  - status - Initial status (default: "enabled")
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:url, :enabled_events]),
         webhook = build_webhook(conn.params),
         {:ok, webhook} <- Webhooks.insert(webhook) do
      maybe_store_idempotency(conn, webhook)

      webhook
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :invalid_params, field} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("Missing required parameter", field)
        )
    end
  end

  @doc """
  Retrieves a webhook endpoint by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case Webhooks.get(id) do
      {:ok, webhook} ->
        webhook
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("webhook_endpoint", id))
    end
  end

  @doc """
  Updates a webhook endpoint.

  ## Updatable Fields

  - url
  - enabled_events
  - metadata
  - status
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- Webhooks.get(id),
         updated = merge_updates(existing, conn.params),
         {:ok, updated} <- Webhooks.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("webhook_endpoint", id))
    end
  end

  @doc """
  Deletes a webhook endpoint.

  Returns a deletion confirmation object.
  """
  @spec delete(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def delete(conn, id) do
    case Webhooks.get(id) do
      {:ok, _webhook} ->
        :ok = Webhooks.delete(id)

        json_response(conn, 200, %{
          deleted: true,
          id: id,
          object: "webhook_endpoint"
        })

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("webhook_endpoint", id))
    end
  end

  @doc """
  Lists all webhook endpoints with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result = Webhooks.list(pagination_opts)

    json_response(conn, 200, result)
  end

  ## Private Functions

  defp build_webhook(params) do
    %{
      id: generate_id("we"),
      object: "webhook_endpoint",
      created: PaperTiger.now(),
      url: Map.get(params, :url),
      secret: generate_webhook_secret(),
      enabled_events: Map.get(params, :enabled_events, []),
      status: Map.get(params, :status, "enabled"),
      metadata: Map.get(params, :metadata, %{}),
      # Additional fields
      livemode: false,
      version: nil,
      connect: false,
      api_version: "2023-10-16"
    }
  end

  defp generate_webhook_secret do
    "whsec_" <>
      (:crypto.strong_rand_bytes(32)
       |> Base.encode16(case: :lower)
       |> binary_part(0, 32))
  end

  defp maybe_expand(webhook, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(webhook, expand_params)
  end
end
