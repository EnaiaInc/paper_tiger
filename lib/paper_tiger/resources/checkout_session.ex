defmodule PaperTiger.Resources.CheckoutSession do
  @moduledoc """
  Handles Checkout Session resource endpoints.

  ## Endpoints

  - POST   /v1/checkout/sessions     - Create checkout session
  - GET    /v1/checkout/sessions/:id - Retrieve checkout session
  - GET    /v1/checkout/sessions     - List checkout sessions

  Note: Checkout sessions are immutable after creation (no update or delete).

  ## Checkout Session Object

      %{
        id: "cs_...",
        object: "checkout.session",
        created: 1234567890,
        customer: "cus_...",
        mode: "payment",
        payment_status: "unpaid",
        status: "open",
        success_url: "https://example.com/success",
        cancel_url: "https://example.com/cancel",
        line_items: [],
        metadata: %{},
        # ... other fields
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.CheckoutSessions

  require Logger

  @doc """
  Creates a new checkout session.

  ## Required Parameters

  - success_url - URL to redirect to after successful payment
  - cancel_url - URL to redirect to if customer cancels payment
  - mode - One of "payment", "setup", or "subscription"

  ## Optional Parameters

  - customer - Customer ID
  - line_items - Array of line items
  - metadata - Key-value metadata
  - payment_status - One of "paid", "unpaid", "no_payment_required"
  - status - One of "open", "complete", "expired"
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:success_url, :cancel_url, :mode]),
         session = build_session(conn.params),
         {:ok, session} <- CheckoutSessions.insert(session) do
      maybe_store_idempotency(conn, session)

      session
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
  Retrieves a checkout session by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case CheckoutSessions.get(id) do
      {:ok, session} ->
        session
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("checkout.session", id))
    end
  end

  @doc """
  Lists all checkout sessions with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  - customer - Filter by customer ID
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    # Apply customer filter if provided
    result =
      if customer_id = Map.get(conn.params, :customer) do
        CheckoutSessions.find_by_customer(customer_id)
        |> PaperTiger.List.paginate(Map.put(pagination_opts, :url, "/v1/checkout/sessions"))
      else
        CheckoutSessions.list(pagination_opts)
      end

    json_response(conn, 200, result)
  end

  ## Private Functions

  defp build_session(params) do
    %{
      id: generate_id("cs"),
      object: "checkout.session",
      created: PaperTiger.now(),
      customer: Map.get(params, :customer),
      mode: Map.get(params, :mode),
      payment_status: Map.get(params, :payment_status, "unpaid"),
      status: Map.get(params, :status, "open"),
      success_url: Map.get(params, :success_url),
      cancel_url: Map.get(params, :cancel_url),
      line_items: Map.get(params, :line_items, []),
      metadata: Map.get(params, :metadata, %{}),
      # Additional fields
      livemode: false,
      billing_address_collection: Map.get(params, :billing_address_collection),
      shipping_address_collection: Map.get(params, :shipping_address_collection),
      consent_collection: Map.get(params, :consent_collection),
      currency: Map.get(params, :currency),
      customer_creation: Map.get(params, :customer_creation),
      expires_at: PaperTiger.now() + 86_400,
      locale: Map.get(params, :locale),
      payment_method_collection: Map.get(params, :payment_method_collection),
      payment_method_types: Map.get(params, :payment_method_types, ["card"]),
      phone_number_collection: Map.get(params, :phone_number_collection),
      recovered_from: Map.get(params, :recovered_from),
      submit_type: Map.get(params, :submit_type),
      subscription: Map.get(params, :subscription),
      total_details: Map.get(params, :total_details)
    }
  end

  defp maybe_expand(session, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(session, expand_params)
  end
end
