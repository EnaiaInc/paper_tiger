defmodule PaperTiger.Resources.Invoice do
  @moduledoc """
  Handles Invoice resource endpoints.

  ## Endpoints

  - POST   /v1/invoices      - Create invoice
  - GET    /v1/invoices/:id  - Retrieve invoice
  - POST   /v1/invoices/:id  - Update invoice
  - DELETE /v1/invoices/:id  - Delete invoice (draft only)
  - GET    /v1/invoices      - List invoices

  ## Invoice Object

      %{
        id: "in_...",
        object: "invoice",
        created: 1234567890,
        status: "draft",
        customer: "cus_...",
        amount_due: 2000,
        amount_paid: 0,
        currency: "usd",
        lines: %{
          data: [%{amount: 2000, description: "Premium Plan"}]
        },
        # ... other fields
      }

  ## Invoice Statuses

  - draft - Not yet finalized
  - open - Sent to customer, awaiting payment
  - paid - Payment successful
  - uncollectible - Payment attempts failed
  - void - Invoice voided
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.InvoiceItems
  alias PaperTiger.Store.Invoices

  require Logger

  @doc """
  Creates a new invoice.

  ## Required Parameters

  - customer - Customer ID

  ## Optional Parameters

  - auto_advance - Auto-finalize invoice (default: true)
  - collection_method - charge_automatically or send_invoice
  - currency - Three-letter ISO currency code (default: "usd")
  - description - Invoice description
  - metadata - Key-value metadata
  - subscription - Subscription ID (if subscription invoice)
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:customer]),
         invoice = build_invoice(conn.params),
         {:ok, invoice} <- Invoices.insert(invoice) do
      maybe_store_idempotency(conn, invoice)

      invoice_with_lines = load_invoice_lines(invoice)
      :telemetry.execute([:paper_tiger, :invoice, :created], %{}, %{object: invoice_with_lines})

      invoice_with_lines
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
  Retrieves an invoice by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case Invoices.get(id) do
      {:ok, invoice} ->
        invoice
        |> load_invoice_lines()
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("invoice", id))
    end
  end

  @doc """
  Updates an invoice.

  ## Updatable Fields

  - description
  - metadata
  - auto_advance
  - collection_method
  - due_date
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- Invoices.get(id),
         updated = merge_updates(existing, conn.params),
         {:ok, updated} <- Invoices.update(updated) do
      updated_with_lines = load_invoice_lines(updated)
      :telemetry.execute([:paper_tiger, :invoice, :updated], %{}, %{object: updated_with_lines})

      updated_with_lines
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("invoice", id))
    end
  end

  @doc """
  Deletes an invoice.

  Note: Only draft invoices can be deleted.
  """
  @spec delete(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def delete(conn, id) do
    with {:ok, invoice} <- Invoices.get(id),
         :ok <- validate_deletable(invoice),
         :ok <- Invoices.delete(id) do
      json_response(conn, 200, %{
        deleted: true,
        id: id,
        object: "invoice"
      })
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("invoice", id))

      {:error, :not_draft} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("Cannot delete invoice that is not in draft status")
        )
    end
  end

  @doc """
  Lists all invoices with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  - customer - Filter by customer
  - status - Filter by status
  - subscription - Filter by subscription
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result = Invoices.list(pagination_opts)

    json_response(conn, 200, result)
  end

  @doc """
  Finalizes a draft invoice.

  POST /v1/invoices/:id/finalize

  Transitions the invoice from draft to open status.
  Only draft invoices can be finalized.
  """
  @spec finalize(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def finalize(conn, id) do
    with {:ok, invoice} <- Invoices.get(id),
         :ok <- validate_can_finalize(invoice),
         finalized = finalize_invoice(invoice),
         {:ok, finalized} <- Invoices.update(finalized) do
      finalized_with_lines = load_invoice_lines(finalized)
      :telemetry.execute([:paper_tiger, :invoice, :finalized], %{}, %{object: finalized_with_lines})

      finalized_with_lines
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("invoice", id))

      {:error, :not_draft} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("Cannot finalize invoice that is not in draft status")
        )
    end
  end

  @doc """
  Marks an invoice as paid.

  POST /v1/invoices/:id/pay

  Transitions the invoice to paid status.
  """
  @spec pay(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def pay(conn, id) do
    with {:ok, invoice} <- Invoices.get(id),
         paid = mark_invoice_paid(invoice),
         {:ok, paid} <- Invoices.update(paid) do
      paid_with_lines = load_invoice_lines(paid)
      :telemetry.execute([:paper_tiger, :invoice, :paid], %{}, %{object: paid_with_lines})
      :telemetry.execute([:paper_tiger, :invoice, :payment_succeeded], %{}, %{object: paid_with_lines})

      paid_with_lines
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("invoice", id))
    end
  end

  @doc """
  Voids an invoice.

  POST /v1/invoices/:id/void

  Transitions the invoice to void status.
  Open invoices can be voided.
  """
  @spec void_invoice(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def void_invoice(conn, id) do
    with {:ok, invoice} <- Invoices.get(id),
         voided = mark_invoice_void(invoice),
         {:ok, voided} <- Invoices.update(voided) do
      voided
      |> load_invoice_lines()
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("invoice", id))
    end
  end

  ## Private Functions

  defp build_invoice(params) do
    now = PaperTiger.now()
    currency = Map.get(params, :currency, "usd")

    %{
      id: generate_id("in"),
      object: "invoice",
      created: now,
      status: "draft",
      customer: Map.get(params, :customer),
      amount_due: 0,
      amount_paid: 0,
      amount_remaining: 0,
      currency: currency,
      description: Map.get(params, :description),
      metadata: Map.get(params, :metadata, %{}),
      subscription: Map.get(params, :subscription),
      # Lines will be loaded separately
      lines: %{
        data: [],
        has_more: false,
        object: "list",
        url: "/v1/invoices/#{generate_id("in")}/lines"
      },
      # Additional fields
      livemode: false,
      account_country: "US",
      account_name: "PaperTiger Test",
      auto_advance: Map.get(params, :auto_advance, true),
      collection_method: Map.get(params, :collection_method, "charge_automatically"),
      due_date: Map.get(params, :due_date),
      ending_balance: nil,
      footer: Map.get(params, :footer),
      hosted_invoice_url: nil,
      invoice_pdf: nil,
      next_payment_attempt: nil,
      number: nil,
      paid: false,
      period_end: now,
      period_start: now,
      receipt_number: nil,
      starting_balance: 0,
      statement_descriptor: Map.get(params, :statement_descriptor),
      subtotal: 0,
      tax: nil,
      total: 0,
      webhooks_delivered_at: nil
    }
  end

  defp load_invoice_lines(invoice) do
    lines = InvoiceItems.find_by_invoice(invoice.id)

    %{
      invoice
      | lines: %{
          data: lines,
          has_more: false,
          object: "list",
          url: "/v1/invoices/#{invoice.id}/lines"
        }
    }
  end

  defp validate_deletable(%{status: "draft"}), do: :ok
  defp validate_deletable(_invoice), do: {:error, :not_draft}

  defp validate_can_finalize(%{status: "draft"}), do: :ok
  defp validate_can_finalize(_invoice), do: {:error, :not_draft}

  defp finalize_invoice(invoice) do
    now = PaperTiger.now()

    %{
      invoice
      | number: generate_id("inv"),
        period_end: now,
        status: "open",
        webhooks_delivered_at: now
    }
  end

  defp mark_invoice_paid(invoice) do
    %{
      invoice
      | amount_paid: invoice.amount_due,
        amount_remaining: 0,
        paid: true,
        status: "paid"
    }
  end

  defp mark_invoice_void(invoice) do
    %{
      invoice
      | status: "void"
    }
  end

  defp maybe_expand(invoice, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(invoice, expand_params)
  end
end
