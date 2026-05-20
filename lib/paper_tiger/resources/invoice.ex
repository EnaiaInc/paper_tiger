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
  alias PaperTiger.CustomerBalance
  alias PaperTiger.Search
  alias PaperTiger.Store.InvoiceItems
  alias PaperTiger.Store.Invoices
  alias PaperTiger.Store.PaymentIntents
  alias PaperTiger.Store.Prices
  alias PaperTiger.Store.SubscriptionItems
  alias PaperTiger.Store.Subscriptions

  @search_fields %{
    "created" => :numeric,
    "currency" => :token,
    "customer" => :token,
    "last_finalization_error.code" => :token,
    "last_finalization_error.type" => :token,
    "metadata" => :token,
    "number" => :string,
    "receipt_number" => :string,
    "status" => :string,
    "subscription" => :token,
    "total" => :numeric
  }

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
    # No filters - return all
    # Filter by both customer and status
    # Filter by both customer and subscription
    # Filter by both status and subscription
    # Filter by all three
    # Mark invoice as failed and return error
    ## Private Functions
    # Allow provided lines or use empty default
    # Handle charge - empty string should be treated as nil
    # Use get_optional_integer for created to handle string->integer conversion
    # Build status_transitions - accept from params or generate defaults
    # Build base invoice - charge is only included when present (not for draft invoices)
    invoices = get_filtered_invoices(customer, status, subscription)

    result = PaperTiger.List.paginate(invoices, Map.put(pagination_opts, :url, "/v1/invoices"))

    json_response(conn, 200, result)
  end

  @doc """
  Searches invoices with Stripe-style search query syntax.
  """
  @spec search(Plug.Conn.t()) :: Plug.Conn.t()
  def search(conn) do
    Invoices.list_namespace(PaperTiger.Connect.storage_namespace())
    |> Search.run(conn.params,
      fields: @search_fields,
      url: "/v1/invoices/search",
      decorate: fn invoice ->
        invoice
        |> load_invoice_lines()
        |> maybe_expand(conn.params)
      end
    )
    |> respond_to_search(conn)
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(val) when is_binary(val), do: val
  defp to_string_or_nil(val) when is_atom(val), do: Atom.to_string(val)

  defp respond_to_search({:ok, result}, conn), do: json_response(conn, 200, result)
  defp respond_to_search({:error, error}, conn), do: error_response(conn, error)

  defp get_filtered_invoices(nil, nil, nil) do
    Invoices.all()
  end

  # Additional fields
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
    Invoices.find_by_customer(customer_id)
    |> Enum.filter(fn inv -> inv.status == status end)
  end

  defp get_filtered_invoices(customer_id, nil, subscription_id)
       when is_binary(customer_id) and is_binary(subscription_id) do
    Invoices.find_by_customer(customer_id)
    |> Enum.filter(fn inv -> inv.subscription == subscription_id end)
  end

  defp get_filtered_invoices(nil, status, subscription_id) when is_binary(status) and is_binary(subscription_id) do
    Invoices.find_by_subscription(subscription_id)
    |> Enum.filter(fn inv -> inv.status == status end)
  end

  defp get_filtered_invoices(customer_id, status, subscription_id)
       when is_binary(customer_id) and is_binary(status) and is_binary(subscription_id) do
    Invoices.find_by_customer(customer_id)
    |> Enum.filter(fn inv -> inv.status == status and inv.subscription == subscription_id end)
  end

  @doc """
  Retrieves an upcoming invoice preview for a subscription.

  GET /v1/invoices/upcoming

  Builds a synthetic invoice from the subscription's current items (or from
  `subscription_items` if provided for proration preview).
  Not persisted to ETS.
  """
  @spec upcoming(Plug.Conn.t()) :: Plug.Conn.t()
  def upcoming(conn) do
    subscription_id = to_string_or_nil(Map.get(conn.params, :subscription))

    if is_nil(subscription_id) do
      error_response(conn, PaperTiger.Error.invalid_request("Missing required parameter", "subscription"))
    else
      with :ok <-
             validate_item_collection_quantities(param_value(conn.params, :subscription_items), "subscription_items"),
           {:ok, subscription} <- Subscriptions.get(subscription_id) do
        items = load_items_for_preview(subscription_id, conn.params)
        invoice = build_upcoming_invoice(subscription, items)
        json_response(conn, 200, invoice)
      else
        {:error, :invalid_quantity, field} ->
          error_response(conn, PaperTiger.Error.invalid_request("Invalid integer", field))

        {:error, :not_found} ->
          error_response(conn, PaperTiger.Error.not_found("subscription", subscription_id))
      end
    end
  end

  @doc """
  Creates a preview invoice for proposed subscription changes.

  POST /v1/invoices/create_preview

  Reads `subscription` and `subscription_details[items]` from params,
  merges proposed changes with existing items, and returns a synthetic invoice.
  Not persisted to ETS.
  """
  @spec create_preview(Plug.Conn.t()) :: Plug.Conn.t()
  def create_preview(conn) do
    subscription_id = to_string_or_nil(Map.get(conn.params, :subscription))

    if is_nil(subscription_id) do
      error_response(conn, PaperTiger.Error.invalid_request("Missing required parameter", "subscription"))
    else
      with :ok <- validate_preview_quantity_params(conn.params),
           {:ok, subscription} <- Subscriptions.get(subscription_id) do
        sd = param_value(conn.params, :subscription_details) || %{}
        proposed_items = param_value(sd, :items) || %{}
        existing = SubscriptionItems.find_by_subscription(subscription_id)
        existing_resolved = Enum.map(existing, &resolve_item_for_preview/1)
        merged = merge_preview_items(subscription_id, proposed_items)
        invoice = build_preview_invoice(subscription, merged, existing_resolved)
        json_response(conn, 200, invoice)
      else
        {:error, :invalid_quantity, field} ->
          error_response(conn, PaperTiger.Error.invalid_request("Invalid integer", field))

        {:error, :not_found} ->
          error_response(conn, PaperTiger.Error.not_found("subscription", subscription_id))
      end
    end
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
         finalized = invoice |> finalize_invoice() |> CustomerBalance.apply_to_invoice(),
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
    |> Map.put(:status, payment_failed_status(invoice))
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
      voided_with_lines = load_invoice_lines(voided)
      :telemetry.execute([:paper_tiger, :invoice, :voided], %{}, %{object: voided_with_lines})

      voided_with_lines
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("invoice", id))
    end
  end

  @doc """
  Sends an invoice to the customer.

  POST /v1/invoices/:id/send

  Emits invoice.sent and returns the invoice. The invoice remains open.
  """
  @spec send_invoice(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def send_invoice(conn, id) do
    with {:ok, invoice} <- Invoices.get(id),
         :ok <- validate_sendable(invoice),
         sent = mark_invoice_sent(invoice),
         {:ok, sent} <- Invoices.update(sent) do
      sent_with_lines = load_invoice_lines(sent)
      :telemetry.execute([:paper_tiger, :invoice, :sent], %{}, %{object: sent_with_lines})

      sent_with_lines
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("invoice", id))

      {:error, :not_sendable, status} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request(
            "This invoice's status (#{status}) does not allow sending.",
            "status"
          )
        )
    end
  end

  @doc """
  Marks an invoice as uncollectible.

  POST /v1/invoices/:id/mark_uncollectible
  """
  @spec mark_uncollectible(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def mark_uncollectible(conn, id) do
    with {:ok, invoice} <- Invoices.get(id),
         :ok <- validate_mark_uncollectible(invoice),
         uncollectible = mark_invoice_uncollectible(invoice),
         {:ok, uncollectible} <- Invoices.update(uncollectible) do
      uncollectible_with_lines = load_invoice_lines(uncollectible)

      :telemetry.execute([:paper_tiger, :invoice, :marked_uncollectible], %{}, %{
        object: uncollectible_with_lines
      })

      uncollectible_with_lines
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("invoice", id))

      {:error, :not_markable_uncollectible, status} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request(
            "This invoice's status (#{status}) does not allow marking it uncollectible.",
            "status"
          )
        )
    end
  end

  @doc """
  Attaches a payment to an invoice.

  POST /v1/invoices/:id/attach_payment
  """
  @spec attach_payment(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def attach_payment(conn, id) do
    with {:ok, invoice} <- Invoices.get(id),
         :ok <- validate_can_attach_payment(invoice),
         {:ok, payment} <- resolve_invoice_payment(conn.params),
         {:ok, updated} <- attach_invoice_payment(invoice, payment) do
      updated_with_lines = load_invoice_lines(updated)
      :telemetry.execute([:paper_tiger, :invoice, :updated], %{}, %{object: updated_with_lines})
      maybe_emit_invoice_paid(invoice, updated_with_lines)

      updated_with_lines
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("invoice", id))

      {:error, :payment_intent_not_found, payment_intent_id} ->
        error_response(conn, PaperTiger.Error.not_found("payment_intent", payment_intent_id))

      {:error, :missing_payment} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("Missing required parameter", "payment_intent")
        )

      {:error, :multiple_payments} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("Specify only one of payment_intent or payment_record")
        )

      {:error, :payment_record_unsupported} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("PaymentRecord attachment is not supported", "payment_record")
        )

      {:error, :not_attachable, status} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request(
            "This invoice's status (#{status}) does not allow attaching payments.",
            "status"
          )
        )
    end
  end

  defp build_invoice(params) do
    now = PaperTiger.now()
    currency = Map.get(params, :currency, "usd")
    invoice_id = generate_id("in", Map.get(params, :id))
    total = get_integer(params, :total, 0)

    default_lines = %{
      data: [],
      has_more: false,
      object: "list",
      url: "/v1/invoices/#{invoice_id}/lines"
    }

    lines = Map.get(params, :lines, default_lines)
    charge = normalize_optional_string(params, :charge)
    created = get_optional_integer(params, :created) || now
    period_start = get_optional_integer(params, :period_start) || now
    period_end = get_optional_integer(params, :period_end) || now
    status = Map.get(params, :status, "draft")
    default_status_transitions = build_default_status_transitions(status, now)

    status_transitions =
      case Map.get(params, :status_transitions) do
        nil -> default_status_transitions
        transitions -> normalize_status_transitions(transitions)
      end

    base_invoice = %{
      account_country: "US",
      account_name: "PaperTiger Test",
      amount_due: get_integer(params, :amount_due, total),
      amount_paid: get_integer(params, :amount_paid, 0),
      amount_remaining: get_integer(params, :amount_remaining, total),
      auto_advance: Map.get(params, :auto_advance, true),
      collection_method: Map.get(params, :collection_method, "charge_automatically"),
      created: created,
      currency: currency,
      customer: Map.get(params, :customer),
      description: Map.get(params, :description),
      due_date: Map.get(params, :due_date),
      ending_balance: nil,
      footer: Map.get(params, :footer),
      hosted_invoice_url: nil,
      id: invoice_id,
      invoice_pdf: Map.get(params, :invoice_pdf),
      lines: lines,
      livemode: false,
      metadata: Map.get(params, :metadata, %{}),
      next_payment_attempt: nil,
      number: nil,
      object: "invoice",
      paid: Map.get(params, :paid, false),
      payment_intent: Map.get(params, :payment_intent),
      period_end: period_end,
      period_start: period_start,
      receipt_number: nil,
      starting_balance: 0,
      statement_descriptor: Map.get(params, :statement_descriptor),
      status: status,
      status_transitions: status_transitions,
      subscription: Map.get(params, :subscription),
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

  defp validate_sendable(%{status: status}) when status in ["open", "paid"], do: :ok
  defp validate_sendable(%{status: status}), do: {:error, :not_sendable, status}

  defp validate_mark_uncollectible(%{status: "open"}), do: :ok
  defp validate_mark_uncollectible(%{status: status}), do: {:error, :not_markable_uncollectible, status}

  defp validate_can_attach_payment(%{status: status}) when status in ["open", "uncollectible"], do: :ok
  defp validate_can_attach_payment(%{status: status}), do: {:error, :not_attachable, status}

  defp finalize_invoice(invoice) do
    now = PaperTiger.now()

    invoice
    |> Map.put(:number, invoice[:number] || generate_id("inv"))
    |> Map.put(:period_end, now)
    |> Map.put(:status, "open")
    |> Map.put(:hosted_invoice_url, hosted_invoice_url(invoice))
    |> Map.put(:invoice_pdf, invoice_pdf_url(invoice))
    |> Map.put(:webhooks_delivered_at, now)
    |> put_status_transition(:finalized_at, now)
  end

  defp mark_invoice_paid(invoice) do
    now = PaperTiger.now()
    amount_due = Map.get(invoice, :amount_due, 0)

    invoice
    |> Map.put(:amount_paid, amount_due)
    |> Map.put(:amount_remaining, 0)
    |> Map.put(:paid, true)
    |> Map.put(:status, "paid")
    |> Map.put(:webhooks_delivered_at, now)
    |> put_status_transition(:paid_at, now)
  end

  defp mark_invoice_void(invoice) do
    now = PaperTiger.now()

    invoice
    |> Map.put(:status, "void")
    |> Map.put(:webhooks_delivered_at, now)
    |> put_status_transition(:voided_at, now)
  end

  defp mark_invoice_sent(invoice) do
    now = PaperTiger.now()

    invoice
    |> Map.put(:attempted, true)
    |> Map.put(:hosted_invoice_url, hosted_invoice_url(invoice))
    |> Map.put(:invoice_pdf, invoice_pdf_url(invoice))
    |> Map.put(:webhooks_delivered_at, now)
  end

  defp mark_invoice_uncollectible(invoice) do
    now = PaperTiger.now()

    invoice
    |> Map.put(:status, "uncollectible")
    |> Map.put(:paid, false)
    |> Map.put(:webhooks_delivered_at, now)
    |> put_status_transition(:marked_uncollectible_at, now)
  end

  defp put_status_transition(invoice, field, timestamp) do
    transitions =
      invoice
      |> Map.get(:status_transitions, %{})
      |> Map.put(field, timestamp)

    Map.put(invoice, :status_transitions, transitions)
  end

  defp payment_failed_status(%{status: "uncollectible"}), do: "uncollectible"
  defp payment_failed_status(_invoice), do: "open"

  defp hosted_invoice_url(invoice), do: "https://invoice.stripe.com/i/#{invoice.id}"
  defp invoice_pdf_url(invoice), do: "https://pay.stripe.com/invoice/#{invoice.id}/pdf"

  defp resolve_invoice_payment(params) do
    payment_intent_id = normalize_optional_string(params, :payment_intent)
    payment_record_id = normalize_optional_string(params, :payment_record)

    case {payment_intent_id, payment_record_id} do
      {nil, nil} ->
        {:error, :missing_payment}

      {_payment_intent_id, _payment_record_id} when is_binary(payment_intent_id) and is_binary(payment_record_id) ->
        {:error, :multiple_payments}

      {payment_intent_id, nil} ->
        case PaymentIntents.get(payment_intent_id) do
          {:ok, payment_intent} -> {:ok, {:payment_intent, payment_intent}}
          {:error, :not_found} -> {:error, :payment_intent_not_found, payment_intent_id}
        end

      {nil, _payment_record_id} ->
        {:error, :payment_record_unsupported}
    end
  end

  defp attach_invoice_payment(invoice, {:payment_intent, payment_intent}) do
    now = PaperTiger.now()
    payment_amount = payment_intent_amount(payment_intent)
    credited_amount = credited_payment_amount(invoice, payment_intent)
    invoice_payment = build_invoice_payment(invoice, payment_intent, payment_amount, credited_amount, now)

    updated_invoice =
      invoice
      |> Map.put(:payment_intent, payment_intent.id)
      |> append_invoice_payment(invoice_payment)
      |> credit_invoice_payment(credited_amount, now)

    updated_payment_intent = Map.put(payment_intent, :invoice, invoice.id)

    with {:ok, _payment_intent} <- PaymentIntents.update(updated_payment_intent) do
      Invoices.update(updated_invoice)
    end
  end

  defp payment_intent_amount(payment_intent) do
    Map.get(payment_intent, :amount_received, 0)
    |> max(Map.get(payment_intent, :amount, 0))
  end

  defp credited_payment_amount(_invoice, %{status: status}) when status != "succeeded", do: 0

  defp credited_payment_amount(invoice, payment_intent) do
    invoice
    |> Map.get(:amount_remaining, 0)
    |> min(Map.get(payment_intent, :amount_received, 0))
  end

  defp build_invoice_payment(invoice, payment_intent, amount_requested, amount_paid, now) when is_map(payment_intent) do
    %{
      amount_paid: amount_paid,
      amount_requested: amount_requested,
      created: now,
      currency: invoice.currency,
      id: generate_id("inpay"),
      invoice: invoice.id,
      is_default: true,
      livemode: false,
      object: "invoice_payment",
      payment: %{payment_intent: payment_intent.id, type: "payment_intent"},
      status: if(amount_paid > 0, do: "paid", else: "open"),
      status_transitions: %{canceled_at: nil, paid_at: if(amount_paid > 0, do: now)}
    }
  end

  defp append_invoice_payment(invoice, invoice_payment) do
    payments =
      invoice
      |> Map.get(:payments)
      |> normalize_payments_list(invoice.id)
      |> Map.update!(:data, fn payments -> payments ++ [invoice_payment] end)

    Map.put(invoice, :payments, payments)
  end

  defp normalize_payments_list(nil, invoice_id) do
    %{data: [], has_more: false, object: "list", url: "/v1/invoices/#{invoice_id}/payments"}
  end

  defp normalize_payments_list(%{data: data} = payments, _invoice_id) when is_list(data), do: payments

  defp credit_invoice_payment(invoice, 0, _now), do: invoice

  defp credit_invoice_payment(invoice, credited_amount, now) do
    amount_paid = Map.get(invoice, :amount_paid, 0) + credited_amount
    amount_remaining = max(Map.get(invoice, :amount_due, 0) - amount_paid, 0)

    invoice =
      invoice
      |> Map.put(:amount_paid, amount_paid)
      |> Map.put(:amount_remaining, amount_remaining)

    if amount_remaining == 0 do
      invoice
      |> Map.put(:paid, true)
      |> Map.put(:status, "paid")
      |> Map.put(:webhooks_delivered_at, now)
      |> put_status_transition(:paid_at, now)
    else
      invoice
    end
  end

  defp maybe_emit_invoice_paid(%{status: old_status}, %{status: "paid"} = invoice) when old_status != "paid" do
    :telemetry.execute([:paper_tiger, :invoice, :paid], %{}, %{object: invoice})
    :telemetry.execute([:paper_tiger, :invoice, :payment_succeeded], %{}, %{object: invoice})
  end

  defp maybe_emit_invoice_paid(_old_invoice, _new_invoice), do: :ok

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

  ## Upcoming / Preview helpers

  defp param_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp parse_quantity(value, default)
  defp parse_quantity(nil, default), do: {:ok, default}
  defp parse_quantity(value, _default) when is_integer(value), do: {:ok, value}

  defp parse_quantity(value, _default) when is_binary(value) do
    case Integer.parse(value) do
      {num, ""} -> {:ok, num}
      _ -> :error
    end
  end

  defp parse_quantity(_value, _default), do: :error

  defp validate_preview_quantity_params(params) do
    with :ok <- validate_item_collection_quantities(param_value(params, :subscription_items), "subscription_items") do
      validate_subscription_details_quantities(params)
    end
  end

  defp validate_subscription_details_quantities(params) do
    subscription_details = param_value(params, :subscription_details) || %{}
    validate_item_collection_quantities(param_value(subscription_details, :items), "subscription_details[items]")
  end

  defp validate_item_collection_quantities(nil, _base_field), do: :ok

  defp validate_item_collection_quantities(items, base_field) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, idx}, _acc ->
      case validate_item_quantity(item, "#{base_field}[#{idx}][quantity]") do
        :ok -> {:cont, :ok}
        {:error, _reason, _field} = error -> {:halt, error}
      end
    end)
  end

  defp validate_item_collection_quantities(items, base_field) when is_map(items) do
    items
    |> Enum.sort_by(fn {idx, _item} -> to_string(idx) end)
    |> Enum.reduce_while(:ok, fn {idx, item}, _acc ->
      case validate_item_quantity(item, "#{base_field}[#{idx}][quantity]") do
        :ok -> {:cont, :ok}
        {:error, _reason, _field} = error -> {:halt, error}
      end
    end)
  end

  defp validate_item_collection_quantities(_items, _base_field), do: :ok

  defp validate_item_quantity(item, field) when is_map(item) do
    case parse_quantity(param_value(item, :quantity), 1) do
      {:ok, _} -> :ok
      :error -> {:error, :invalid_quantity, field}
    end
  end

  defp validate_item_quantity(_item, _field), do: :ok

  # Load items for upcoming invoice preview. If subscription_items param is
  # provided (proration preview), use those; otherwise use the subscription's
  # current items.
  defp load_items_for_preview(subscription_id, params) do
    case param_value(params, :subscription_items) do
      nil ->
        SubscriptionItems.find_by_subscription(subscription_id)
        |> Enum.map(&resolve_item_for_preview/1)

      proposed when is_map(proposed) ->
        # subscription_items comes as indexed map: %{"0" => %{...}, "1" => %{...}}
        proposed
        |> Enum.sort_by(fn {k, _} -> k end)
        |> Enum.map(fn {_idx, item} -> resolve_proposed_item(item) end)
        |> Enum.reject(&is_nil/1)

      _ ->
        SubscriptionItems.find_by_subscription(subscription_id)
        |> Enum.map(&resolve_item_for_preview/1)
    end
  end

  defp resolve_item_for_preview(sub_item) do
    price_id = sub_item[:price] || sub_item.price
    price_id = if is_map(price_id), do: price_id[:id] || price_id["id"], else: price_id
    quantity = sub_item[:quantity] || sub_item["quantity"] || 1

    case Prices.get(to_string(price_id)) do
      {:ok, price} ->
        %{price_id: price.id, product: price.product, quantity: quantity, unit_amount: price.unit_amount}

      _ ->
        %{price_id: to_string(price_id), product: nil, quantity: quantity, unit_amount: 0}
    end
  end

  defp resolve_proposed_item(item) do
    if !deleted_item?(item), do: resolve_active_proposed_item(item)
  end

  defp deleted_item?(item) do
    deleted = item[:deleted] || item["deleted"]
    deleted in [true, "true"]
  end

  defp resolve_active_proposed_item(item) do
    case parse_quantity(param_value(item, :quantity), 1) do
      {:ok, quantity} ->
        case param_value(item, :price) do
          nil -> resolve_existing_proposed_item(item, quantity)
          price_id -> build_preview_item(price_id, quantity)
        end

      _ ->
        nil
    end
  end

  defp resolve_existing_proposed_item(item, quantity) do
    case param_value(item, :id) do
      nil ->
        nil

      item_id ->
        case lookup_subscription_item_price(to_string(item_id)) do
          {:ok, price_id_str, unit_amount, product} ->
            %{price_id: price_id_str, product: product, quantity: quantity, unit_amount: unit_amount}

          _ ->
            nil
        end
    end
  end

  defp lookup_subscription_item_price(item_id) do
    # SubscriptionItems store uses the same get pattern
    case SubscriptionItems.get(item_id) do
      {:ok, sub_item} ->
        price_id = sub_item[:price] || sub_item.price
        price_id = if is_map(price_id), do: price_id[:id] || price_id["id"], else: price_id

        case Prices.get(to_string(price_id)) do
          {:ok, price} -> {:ok, price.id, price.unit_amount, price.product}
          _ -> {:ok, to_string(price_id), 0, nil}
        end

      _ ->
        :error
    end
  end

  defp build_upcoming_invoice(subscription, items) do
    now = PaperTiger.now()
    invoice_id = generate_id("in")

    lines =
      Enum.map(items, fn item ->
        amount = (item.unit_amount || 0) * (item.quantity || 1)

        %{
          amount: amount,
          currency: "usd",
          description: "#{item.quantity} x (#{item.price_id})",
          id: generate_id("il"),
          object: "line_item",
          price: %{id: item.price_id, product: item.product, unit_amount: item.unit_amount},
          proration: false,
          quantity: item.quantity,
          type: "subscription"
        }
      end)

    total = Enum.reduce(lines, 0, fn line, acc -> acc + line.amount end)
    period_end = subscription[:current_period_end] || now

    discount = subscription[:discount]

    %{
      amount_due: total,
      amount_paid: 0,
      amount_remaining: total,
      created: now,
      currency: "usd",
      customer: subscription[:customer],
      discount: discount,
      id: invoice_id,
      lines: %{
        data: lines,
        has_more: false,
        object: "list",
        url: "/v1/invoices/#{invoice_id}/lines"
      },
      livemode: false,
      object: "invoice",
      period_end: period_end + 30 * 86_400,
      period_start: period_end,
      status: "draft",
      subscription: subscription[:id],
      subtotal: total,
      total: total
    }
  end

  defp merge_preview_items(subscription_id, proposed_items) do
    existing = SubscriptionItems.find_by_subscription(subscription_id)
    existing_by_id = map_existing_items_by_id(existing)
    proposed_list = normalize_proposed_preview_items(proposed_items)
    state = reduce_proposed_preview_items(proposed_list, existing_by_id)

    updated_existing = updated_existing_preview_items(existing, state.updated_by_id)
    kept_existing = kept_existing_preview_items(existing, state.deleted_ids, state.updated_by_id)
    updated_existing ++ Enum.reverse(state.new_items, kept_existing)
  end

  defp map_existing_items_by_id(existing) do
    Map.new(existing, fn item -> {to_string(item.id), item} end)
  end

  defp normalize_proposed_preview_items(items) when is_list(items), do: items

  defp normalize_proposed_preview_items(items) when is_map(items) do
    items
    |> Enum.sort_by(fn {idx, _item} -> idx end)
    |> Enum.map(fn {_idx, item} -> item end)
  end

  defp normalize_proposed_preview_items(_), do: []

  defp reduce_proposed_preview_items(proposed_list, existing_by_id) do
    initial_state = %{deleted_ids: MapSet.new(), new_items: [], updated_by_id: %{}}
    Enum.reduce(proposed_list, initial_state, &reduce_preview_item(&1, &2, existing_by_id))
  end

  defp reduce_preview_item(item, state, existing_by_id) do
    parsed = parse_proposed_preview_item(item)

    cond do
      parsed.deleted? ->
        mark_preview_item_deleted(state, parsed.item_id)

      parsed.quantity == :error ->
        state

      true ->
        apply_proposed_preview_item(state, parsed, existing_by_id)
    end
  end

  defp parse_proposed_preview_item(item) do
    %{
      deleted?: deleted_item?(item),
      item_id: maybe_string(param_value(item, :id)),
      price_id: param_value(item, :price),
      quantity: parse_quantity(param_value(item, :quantity), 1)
    }
  end

  defp maybe_string(nil), do: nil
  defp maybe_string(value), do: to_string(value)

  defp mark_preview_item_deleted(state, nil), do: state

  defp mark_preview_item_deleted(state, item_id) do
    %{
      state
      | deleted_ids: MapSet.put(state.deleted_ids, item_id),
        updated_by_id: Map.delete(state.updated_by_id, item_id)
    }
  end

  defp apply_proposed_preview_item(state, %{item_id: item_id} = parsed, existing_by_id)
       when is_binary(item_id) and is_map_key(existing_by_id, item_id) do
    {:ok, quantity} = parsed.quantity
    sub_item = Map.fetch!(existing_by_id, item_id)
    resolved_price_id = parsed.price_id || extract_price_id(sub_item)
    resolved_item = build_preview_item(resolved_price_id, quantity)
    %{state | updated_by_id: Map.put(state.updated_by_id, item_id, resolved_item)}
  end

  defp apply_proposed_preview_item(state, %{price_id: price_id, quantity: {:ok, quantity}}, _existing_by_id)
       when not is_nil(price_id) do
    %{state | new_items: [build_preview_item(price_id, quantity) | state.new_items]}
  end

  defp apply_proposed_preview_item(state, _parsed, _existing_by_id), do: state

  defp updated_existing_preview_items(existing, updated_by_id) do
    existing
    |> Enum.map(fn item -> Map.get(updated_by_id, to_string(item.id)) end)
    |> Enum.reject(&is_nil/1)
  end

  defp kept_existing_preview_items(existing, deleted_ids, updated_by_id) do
    existing
    |> Enum.reject(fn item ->
      item_id = to_string(item.id)
      MapSet.member?(deleted_ids, item_id) or Map.has_key?(updated_by_id, item_id)
    end)
    |> Enum.map(&resolve_item_for_preview/1)
  end

  defp extract_price_id(sub_item) do
    price_id = sub_item[:price] || sub_item.price
    if is_map(price_id), do: price_id[:id] || price_id["id"], else: price_id
  end

  defp build_preview_item(price_id, quantity) do
    case Prices.get(to_string(price_id)) do
      {:ok, price} ->
        %{price_id: price.id, product: price.product, quantity: quantity, unit_amount: price.unit_amount}

      _ ->
        %{price_id: to_string(price_id), product: nil, quantity: quantity, unit_amount: 0}
    end
  end

  defp aggregate_items_by_price(items) do
    Enum.reduce(items, %{}, fn item, acc ->
      price_id = item.price_id
      quantity = item.quantity || 1
      unit_amount = item.unit_amount || 0
      amount = unit_amount * quantity

      Map.update(
        acc,
        price_id,
        %{amount: amount, product: item.product, quantity: quantity, unit_amount: unit_amount},
        fn existing ->
          %{
            amount: existing.amount + amount,
            product: existing.product || item.product,
            quantity: existing.quantity + quantity,
            unit_amount: existing.unit_amount
          }
        end
      )
    end)
  end

  defp build_preview_invoice(subscription, items, existing_items) do
    now = PaperTiger.now()
    invoice_id = generate_id("in")

    # Regular subscription lines (what the next invoice will look like)
    regular_lines =
      Enum.map(items, fn item ->
        amount = (item.unit_amount || 0) * (item.quantity || 1)

        %{
          amount: amount,
          currency: "usd",
          description: "#{item.quantity} x (#{item.price_id})",
          id: generate_id("il"),
          object: "line_item",
          price: %{id: item.price_id, product: item.product, unit_amount: item.unit_amount},
          proration: false,
          quantity: item.quantity,
          type: "subscription"
        }
      end)

    # Proration lines for mid-cycle changes
    proration_lines = build_proration_lines(existing_items, items)

    lines = regular_lines ++ proration_lines
    total = Enum.reduce(lines, 0, fn line, acc -> acc + line.amount end)

    %{
      amount_due: total,
      amount_paid: 0,
      amount_remaining: total,
      created: now,
      currency: "usd",
      customer: subscription[:customer],
      discount: subscription[:discount],
      id: invoice_id,
      lines: %{
        data: lines,
        has_more: false,
        object: "list",
        url: "/v1/invoices/#{invoice_id}/lines"
      },
      livemode: false,
      object: "invoice",
      period_end: now + 30 * 86_400,
      period_start: now,
      status: "draft",
      subscription: subscription[:id],
      subtotal: total,
      total: total,
      total_discount_amounts: []
    }
  end

  # Generates proration lines by comparing existing subscription items with proposed items.
  # Credits for removed/reduced items (negative), charges for added/increased items (positive).
  # Assumes half a billing period remaining for simplicity.
  defp build_proration_lines(existing_items, new_items) do
    old_by_price = aggregate_items_by_price(existing_items)
    new_by_price = aggregate_items_by_price(new_items)
    price_ids = all_proration_price_ids(old_by_price, new_by_price)
    Enum.flat_map(price_ids, &build_proration_lines_for_price(&1, old_by_price, new_by_price))
  end

  defp all_proration_price_ids(old_by_price, new_by_price) do
    MapSet.union(MapSet.new(Map.keys(old_by_price)), MapSet.new(Map.keys(new_by_price)))
  end

  defp build_proration_lines_for_price(price_id, old_by_price, new_by_price) do
    old = Map.get(old_by_price, price_id)
    new = Map.get(new_by_price, price_id)
    old_amount = proration_amount(old)
    new_amount = proration_amount(new)

    if old_amount == new_amount do
      []
    else
      [build_credit_proration_line(price_id, old, new), build_charge_proration_line(price_id, old, new)]
      |> Enum.reject(&is_nil/1)
    end
  end

  defp proration_amount(nil), do: 0
  defp proration_amount(item), do: item.amount

  defp build_credit_proration_line(_price_id, nil, _new), do: nil

  defp build_credit_proration_line(price_id, old, new) do
    amount = proration_amount(old)

    if amount > 0 do
      base_item = new || old

      %{
        amount: -div(amount, 2),
        currency: "usd",
        description: "Unused time on #{proration_quantity(old)} x (#{price_id})",
        id: generate_id("il"),
        object: "line_item",
        price: %{id: price_id, product: base_item.product, unit_amount: old.unit_amount},
        proration: true,
        quantity: proration_quantity(old),
        type: "subscription"
      }
    end
  end

  defp build_charge_proration_line(_price_id, _old, nil), do: nil

  defp build_charge_proration_line(price_id, _old, new) do
    amount = proration_amount(new)

    if amount > 0 do
      %{
        amount: div(amount, 2),
        currency: "usd",
        description: "Remaining time on #{proration_quantity(new)} x (#{price_id})",
        id: generate_id("il"),
        object: "line_item",
        price: %{id: price_id, product: new.product, unit_amount: new.unit_amount},
        proration: true,
        quantity: proration_quantity(new),
        type: "subscription"
      }
    end
  end

  defp proration_quantity(item), do: item.quantity
end
