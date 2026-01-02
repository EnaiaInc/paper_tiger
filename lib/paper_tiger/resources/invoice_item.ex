defmodule PaperTiger.Resources.InvoiceItem do
  @moduledoc """
  Handles InvoiceItem resource endpoints.

  ## Endpoints

  - POST   /v1/invoiceitems      - Create invoice item
  - GET    /v1/invoiceitems/:id  - Retrieve invoice item
  - POST   /v1/invoiceitems/:id  - Update invoice item
  - DELETE /v1/invoiceitems/:id  - Delete invoice item
  - GET    /v1/invoiceitems      - List invoice items

  ## InvoiceItem Object

      %{
        id: "ii_...",
        object: "invoiceitem",
        created: 1234567890,
        customer: "cus_...",
        invoice: "in_..." | nil,
        amount: 2000,
        currency: "usd",
        description: "Premium Plan",
        quantity: 1,
        metadata: %{},
        # ... other fields
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.InvoiceItems

  require Logger

  @doc """
  Creates a new invoice item.

  ## Required Parameters

  - customer - Customer ID
  - amount - Amount in cents (integer)
  - currency - Three-letter ISO currency code (e.g., "usd")

  ## Optional Parameters

  - invoice - Invoice ID (optional until invoice is finalized)
  - description - Item description
  - quantity - Quantity (default: 1)
  - metadata - Key-value metadata
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:customer, :amount, :currency]),
         invoice_item = build_invoice_item(conn.params),
         {:ok, invoice_item} <- InvoiceItems.insert(invoice_item) do
      maybe_store_idempotency(conn, invoice_item)

      invoice_item
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
  Retrieves an invoice item by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case InvoiceItems.get(id) do
      {:ok, invoice_item} ->
        invoice_item
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("invoiceitem", id))
    end
  end

  @doc """
  Updates an invoice item.

  ## Updatable Fields

  - amount
  - description
  - metadata
  - quantity
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- InvoiceItems.get(id),
         updated = merge_updates(existing, conn.params),
         {:ok, updated} <- InvoiceItems.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("invoiceitem", id))
    end
  end

  @doc """
  Deletes an invoice item.

  Note: Invoice items can only be deleted if not part of a finalized invoice.

  Returns a deletion confirmation object.
  """
  @spec delete(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def delete(conn, id) do
    case InvoiceItems.get(id) do
      {:ok, _invoice_item} ->
        :ok = InvoiceItems.delete(id)

        json_response(conn, 200, %{
          deleted: true,
          id: id,
          object: "invoiceitem"
        })

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("invoiceitem", id))
    end
  end

  @doc """
  Lists all invoice items with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  - customer - Filter by customer
  - invoice - Filter by invoice
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result = InvoiceItems.list(pagination_opts)

    json_response(conn, 200, result)
  end

  ## Private Functions

  defp build_invoice_item(params) do
    amount = get_integer(params, :amount)

    %{
      id: generate_id("ii"),
      object: "invoiceitem",
      created: PaperTiger.now(),
      customer: Map.get(params, :customer),
      invoice: Map.get(params, :invoice),
      amount: amount,
      currency: Map.get(params, :currency),
      description: Map.get(params, :description),
      quantity: get_integer(params, :quantity, 1),
      metadata: Map.get(params, :metadata, %{}),
      # Additional fields
      livemode: false,
      period: %{
        end: nil,
        start: nil
      },
      price: %{
        billing_scheme: "per_unit",
        created: PaperTiger.now(),
        currency: Map.get(params, :currency),
        custom_unit_amount: nil,
        id: generate_id("price"),
        livemode: false,
        lookup_key: nil,
        metadata: %{},
        nickname: nil,
        object: "price",
        product: nil,
        recurring: nil,
        tax_behavior: "unspecified",
        tiers_mode: nil,
        type: "one_time",
        unit_amount: amount,
        unit_amount_decimal: nil
      },
      proration: false,
      proration_details: %{
        credited_items: nil
      },
      subscription: Map.get(params, :subscription),
      subscription_item: nil,
      type: "invoiceitem",
      unit_amount_excluding_tax: amount
    }
  end

  defp maybe_expand(invoice_item, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(invoice_item, expand_params)
  end
end
