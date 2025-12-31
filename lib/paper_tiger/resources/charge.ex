defmodule PaperTiger.Resources.Charge do
  @moduledoc """
  Handles Charge resource endpoints.

  ## Endpoints

  - POST   /v1/charges      - Create charge
  - GET    /v1/charges/:id  - Retrieve charge
  - POST   /v1/charges/:id  - Update charge
  - GET    /v1/charges      - List charges

  Note: Charges cannot be deleted (immutable resource).

  ## Charge Object

      %{
        id: "ch_...",
        object: "charge",
        created: 1234567890,
        amount: 2000,  # in cents ($20.00)
        currency: "usd",
        status: "succeeded",
        customer: "cus_...",
        payment_method: "pm_...",
        metadata: %{},
        refunded: false,
        amount_refunded: 0,
        # ... other fields
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Charges

  require Logger

  @doc """
  Creates a new charge.

  ## Required Parameters

  - amount - Amount in cents (e.g., 2000 for $20.00)
  - currency - Three-letter ISO currency code (e.g., "usd")

  ## Optional Parameters

  - customer - Customer ID
  - payment_method - Payment method ID
  - description - Charge description
  - metadata - Key-value metadata
  - statement_descriptor - Descriptor for bank statements
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:amount, :currency]),
         charge = build_charge(conn.params),
         {:ok, charge} <- Charges.insert(charge) do
      maybe_store_idempotency(conn, charge)

      charge
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
  Retrieves a charge by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case Charges.get(id) do
      {:ok, charge} ->
        charge
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("charge", id))
    end
  end

  @doc """
  Updates a charge.

  Note: Charges can only have limited fields updated.

  ## Updatable Fields

  - metadata
  - description
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- Charges.get(id),
         updated =
           merge_updates(existing, conn.params, [
             :id,
             :object,
             :created,
             :amount,
             :currency,
             :status,
             :customer,
             :payment_method,
             :refunded,
             :amount_refunded
           ]),
         {:ok, updated} <- Charges.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("charge", id))
    end
  end

  @doc """
  Lists all charges with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  - customer - Filter by customer ID
  - status - Filter by status (succeeded, pending, failed)
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result = Charges.list(pagination_opts)

    json_response(conn, 200, result)
  end

  ## Private Functions

  defp build_charge(params) do
    %{
      id: generate_id("ch"),
      object: "charge",
      created: PaperTiger.now(),
      amount: Map.get(params, :amount),
      currency: Map.get(params, :currency),
      status: Map.get(params, :status, "succeeded"),
      customer: Map.get(params, :customer),
      payment_method: Map.get(params, :payment_method),
      description: Map.get(params, :description),
      metadata: Map.get(params, :metadata, %{}),
      refunded: Map.get(params, :refunded, false),
      amount_refunded: Map.get(params, :amount_refunded, 0),
      # Additional fields
      livemode: false,
      receipt_email: Map.get(params, :receipt_email),
      receipt_number: Map.get(params, :receipt_number),
      receipt_url: nil,
      statement_descriptor: Map.get(params, :statement_descriptor),
      failure_code: nil,
      failure_message: nil,
      fraud_details: nil,
      outcome: %{
        network_status: "approved_by_network",
        reason: nil,
        risk_level: "normal",
        type: "authorized"
      },
      paid: true,
      captured: true,
      balance_transaction: nil,
      billing_details: Map.get(params, :billing_details),
      invoice: Map.get(params, :invoice)
    }
  end

  defp maybe_expand(charge, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(charge, expand_params)
  end
end
