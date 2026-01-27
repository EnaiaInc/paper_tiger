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

  alias PaperTiger.ChaosCoordinator
  alias PaperTiger.Store.InvoiceItems
  alias PaperTiger.Store.Invoices

  @doc """
  Creates a new invoice.

  ## Required Parameters

  - customer - Customer ID

  ## Optional Parameters

  - id - Custom ID (must start with "in_"). Useful for seeding deterministic data.
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

    customer = Map.get(conn.params, :customer) |> to_string_or_nil()
    status = Map.get(conn.params, :status) |> to_string_or_nil()
    subscription = Map.get(conn.params, :subscription) |> to_string_or_nil()

    # Get invoices with filters applied
    invoices = get_filtered_invoices(customer, status, subscription)

    result = PaperTiger.List.paginate(invoices, Map.put(pagination_opts, :url, "/v1/invoices"))

    json_response(conn, 200, result)
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(val) when is_binary(val), do: val
  defp to_string_or_nil(val) when is_atom(val), do: Atom.to_string(val)

  defp get_filtered_invoices(nil, nil, nil) do
    # No filters - return all
    Invoices.all()
  end

  defp get_filtered_invoices(customer_id, nil, nil) when is_binary(customer_id) do
    Invoices.find_by_customer(customer_id)
  end

  defp get_filtered_invoices(nil, status, nil) when is_binary(status) do
    Invoices.find_by_status(status)
  end

  defp get_filtered_invoices(nil, nil, subscription_id) when is_binary(subscription_id) do
    Invoices.find_by_subscription(subscription_id)
  end

  defp get_filtered_invoices(customer_id, status, nil) when is_binary(customer_id) and is_binary(status) do
    # Filter by both customer and status
    Invoices.find_by_customer(customer_id)
    |> Enum.filter(fn inv -> inv.status == status end)
  end

  defp get_filtered_invoices(customer_id, nil, subscription_id)
       when is_binary(customer_id) and is_binary(subscription_id) do
    # Filter by both customer and subscription
    Invoices.find_by_customer(customer_id)
    |> Enum.filter(fn inv -> inv.subscription == subscription_id end)
  end

  defp get_filtered_invoices(nil, status, subscription_id) when is_binary(status) and is_binary(subscription_id) do
    # Filter by both status and subscription
    Invoices.find_by_subscription(subscription_id)
    |> Enum.filter(fn inv -> inv.status == status end)
  end

  defp get_filtered_invoices(customer_id, status, subscription_id)
       when is_binary(customer_id) and is_binary(status) and is_binary(subscription_id) do
    # Filter by all three
    Invoices.find_by_customer(customer_id)
    |> Enum.filter(fn inv -> inv.status == status and inv.subscription == subscription_id end)
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
         :ok <- check_payment_chaos(invoice.customer) do
      paid = mark_invoice_paid(invoice)
      {:ok, paid} = Invoices.update(paid)
      paid_with_lines = load_invoice_lines(paid)
      :telemetry.execute([:paper_tiger, :invoice, :paid], %{}, %{object: paid_with_lines})
      :telemetry.execute([:paper_tiger, :invoice, :payment_succeeded], %{}, %{object: paid_with_lines})

      paid_with_lines
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("invoice", id))

      {:error, {:payment_failed, decline_code}} ->
        # Mark invoice as failed and return error
        with {:ok, invoice} <- Invoices.get(id) do
          failed = mark_invoice_payment_failed(invoice, decline_code)
          {:ok, _failed} = Invoices.update(failed)
          :telemetry.execute([:paper_tiger, :invoice, :payment_failed], %{}, %{object: failed})
        end

        error_response(conn, PaperTiger.Error.card_declined(code: to_string(decline_code)))
    end
  end

  defp check_payment_chaos(customer_id) do
    case ChaosCoordinator.should_payment_fail?(customer_id) do
      {:ok, :succeed} -> :ok
      {:ok, {:fail, decline_code}} -> {:error, {:payment_failed, decline_code}}
    end
  end

  defp mark_invoice_payment_failed(invoice, decline_code) do
    code_str = to_string(decline_code)

    invoice
    |> Map.put(:status, "open")
    |> Map.put(:attempted, true)
    |> Map.put(:attempt_count, (invoice[:attempt_count] || 0) + 1)
    |> Map.put(:last_finalization_error, %{
      code: code_str,
      message: "Your card was declined.",
      type: "card_error"
    })
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
    invoice_id = generate_id("in", Map.get(params, :id))
    total = get_integer(params, :total, 0)

    # Allow provided lines or use empty default
    default_lines = %{
      data: [],
      has_more: false,
      object: "list",
      url: "/v1/invoices/#{invoice_id}/lines"
    }

    lines = Map.get(params, :lines, default_lines)

    # Handle charge - empty string should be treated as nil
    charge = normalize_optional_string(params, :charge)

    # Use get_optional_integer for created to handle string->integer conversion
    created = get_optional_integer(params, :created) || now
    period_start = get_optional_integer(params, :period_start) || now
    period_end = get_optional_integer(params, :period_end) || now

    # Build status_transitions - accept from params or generate defaults
    status = Map.get(params, :status, "draft")
    default_status_transitions = build_default_status_transitions(status, now)

    status_transitions =
      case Map.get(params, :status_transitions) do
        nil -> default_status_transitions
        transitions -> normalize_status_transitions(transitions)
      end

    # Build base invoice - charge is only included when present (not for draft invoices)
    base_invoice = %{
      id: invoice_id,
      object: "invoice",
      created: created,
      status: status,
      status_transitions: status_transitions,
      customer: Map.get(params, :customer),
      amount_due: get_integer(params, :amount_due, total),
      amount_paid: get_integer(params, :amount_paid, 0),
      amount_remaining: get_integer(params, :amount_remaining, total),
      currency: currency,
      description: Map.get(params, :description),
      metadata: Map.get(params, :metadata, %{}),
      subscription: Map.get(params, :subscription),
      lines: lines,
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
      invoice_pdf: Map.get(params, :invoice_pdf),
      next_payment_attempt: nil,
      number: nil,
      paid: Map.get(params, :paid, false),
      period_end: period_end,
      period_start: period_start,
      receipt_number: nil,
      starting_balance: 0,
      statement_descriptor: Map.get(params, :statement_descriptor),
      subtotal: get_integer(params, :subtotal, total),
      tax: nil,
      total: total,
      webhooks_delivered_at: nil
    }

    # Only include charge key when there's an actual charge (matches real Stripe behavior)
    if charge do
      Map.put(base_invoice, :charge, charge)
    else
      base_invoice
    end
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

  # Build default status_transitions based on invoice status
  defp build_default_status_transitions("paid", now) do
    %{
      finalized_at: now,
      marked_uncollectible_at: nil,
      paid_at: now,
      voided_at: nil
    }
  end

  defp build_default_status_transitions("open", now) do
    %{
      finalized_at: now,
      marked_uncollectible_at: nil,
      paid_at: nil,
      voided_at: nil
    }
  end

  defp build_default_status_transitions("void", now) do
    %{
      finalized_at: now,
      marked_uncollectible_at: nil,
      paid_at: nil,
      voided_at: now
    }
  end

  defp build_default_status_transitions("uncollectible", now) do
    %{
      finalized_at: now,
      marked_uncollectible_at: now,
      paid_at: nil,
      voided_at: nil
    }
  end

  defp build_default_status_transitions(_status, _now) do
    %{
      finalized_at: nil,
      marked_uncollectible_at: nil,
      paid_at: nil,
      voided_at: nil
    }
  end

  # Normalize status_transitions - convert string timestamps to integers
  defp normalize_status_transitions(transitions) when is_map(transitions) do
    %{
      finalized_at: normalize_timestamp(Map.get(transitions, :finalized_at) || Map.get(transitions, "finalized_at")),
      marked_uncollectible_at:
        normalize_timestamp(
          Map.get(transitions, :marked_uncollectible_at) || Map.get(transitions, "marked_uncollectible_at")
        ),
      paid_at: normalize_timestamp(Map.get(transitions, :paid_at) || Map.get(transitions, "paid_at")),
      voided_at: normalize_timestamp(Map.get(transitions, :voided_at) || Map.get(transitions, "voided_at"))
    }
  end

  defp normalize_timestamp(nil), do: nil
  defp normalize_timestamp(value) when is_integer(value), do: value

  defp normalize_timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {num, _} -> num
      :error -> nil
    end
  end

  defp normalize_timestamp(_), do: nil

  # Normalize optional string fields - empty strings should be treated as nil
  defp normalize_optional_string(params, key) do
    case Map.get(params, key) do
      nil -> nil
      "" -> nil
      value when is_binary(value) -> value
      _ -> nil
    end
  end
end
