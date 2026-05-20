defmodule PaperTiger.Resources.CreditNote do
  @moduledoc """
  Handles Credit Note resource endpoints.
  """

  import PaperTiger.Resource

  alias PaperTiger.CustomerBalance
  alias PaperTiger.Store.CreditNotes
  alias PaperTiger.Store.Invoices

  @doc """
  Creates a credit note and adjusts the finalized invoice.
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:invoice]),
         :ok <- validate_credit_amount_source(conn.params),
         {:ok, invoice} <- Invoices.get(conn.params.invoice),
         :ok <- validate_invoice_finalized(invoice),
         credit_note = build_credit_note(conn.params, invoice),
         {:ok, invoice} <- apply_credit_note(invoice, credit_note),
         {:ok, credit_note} <- CreditNotes.insert(credit_note) do
      maybe_store_idempotency(conn, credit_note)
      :telemetry.execute([:paper_tiger, :credit_note, :created], %{}, %{object: credit_note})
      :telemetry.execute([:paper_tiger, :invoice, :updated], %{}, %{object: invoice})

      credit_note
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :invalid_params, field} ->
        error_response(conn, PaperTiger.Error.invalid_request("Missing required parameter", field))

      {:error, :missing_amount_source} ->
        error_response(conn, PaperTiger.Error.invalid_request("Must provide amount, lines, or shipping_cost"))

      {:error, :invoice_not_finalized} ->
        error_response(conn, PaperTiger.Error.invalid_request("Credit notes can only be issued for finalized invoices"))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("invoice", conn.params.invoice))
    end
  end

  @doc """
  Previews a credit note without persisting it.
  """
  @spec preview(Plug.Conn.t()) :: Plug.Conn.t()
  def preview(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:invoice]),
         :ok <- validate_credit_amount_source(conn.params),
         {:ok, invoice} <- Invoices.get(conn.params.invoice),
         :ok <- validate_invoice_finalized(invoice) do
      conn.params
      |> build_credit_note(invoice, false)
      |> Map.put(:id, nil)
      |> Map.put(:number, nil)
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :invalid_params, field} ->
        error_response(conn, PaperTiger.Error.invalid_request("Missing required parameter", field))

      {:error, :missing_amount_source} ->
        error_response(conn, PaperTiger.Error.invalid_request("Must provide amount, lines, or shipping_cost"))

      {:error, :invoice_not_finalized} ->
        error_response(conn, PaperTiger.Error.invalid_request("Credit notes can only be issued for finalized invoices"))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("invoice", conn.params.invoice))
    end
  end

  @doc """
  Retrieves a credit note.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case CreditNotes.get(id) do
      {:ok, credit_note} ->
        credit_note
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("credit_note", id))
    end
  end

  @doc """
  Updates a credit note's memo/metadata.
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    case CreditNotes.get(id) do
      {:ok, existing} ->
        updated =
          merge_updates(existing, conn.params, [
            :amount,
            :created,
            :currency,
            :customer,
            :id,
            :invoice,
            :lines,
            :livemode,
            :object,
            :number,
            :status,
            :type
          ])

        {:ok, updated} = CreditNotes.update(updated)
        :telemetry.execute([:paper_tiger, :credit_note, :updated], %{}, %{object: updated})
        json_response(conn, 200, updated)

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("credit_note", id))
    end
  end

  @doc """
  Lists credit notes.
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result =
      case Map.get(conn.params, :invoice) do
        invoice_id when is_binary(invoice_id) and invoice_id != "" ->
          invoice_id
          |> CreditNotes.find_by_invoice()
          |> PaperTiger.List.paginate(Map.put(pagination_opts, :url, "/v1/credit_notes"))

        _ ->
          CreditNotes.list(pagination_opts)
      end

    json_response(conn, 200, result)
  end

  @doc """
  Lists credit note line items.
  """
  @spec lines(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def lines(conn, id) do
    case CreditNotes.get(id) do
      {:ok, credit_note} ->
        credit_note.lines
        |> Map.get(:data, [])
        |> paginate_lines(conn.params, "/v1/credit_notes/#{id}/lines")
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("credit_note", id))
    end
  end

  @doc """
  Lists preview line items.
  """
  @spec preview_lines(Plug.Conn.t()) :: Plug.Conn.t()
  def preview_lines(conn) do
    case Invoices.get(conn.params.invoice || "") do
      {:ok, invoice} ->
        conn.params
        |> build_credit_note(invoice, false)
        |> Map.fetch!(:lines)
        |> Map.get(:data, [])
        |> paginate_lines(conn.params, "/v1/credit_notes/preview/lines")
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("invoice", conn.params.invoice || ""))
    end
  end

  @doc """
  Voids a credit note.
  """
  @spec void(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def void(conn, id) do
    case CreditNotes.get(id) do
      {:ok, %{status: "void"} = credit_note} ->
        json_response(conn, 200, credit_note)

      {:ok, credit_note} ->
        voided =
          credit_note
          |> Map.put(:status, "void")
          |> Map.put(:voided_at, PaperTiger.now())

        {:ok, voided} = CreditNotes.update(voided)
        :telemetry.execute([:paper_tiger, :credit_note, :voided], %{}, %{object: voided})
        json_response(conn, 200, voided)

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("credit_note", id))
    end
  end

  defp validate_credit_amount_source(params) do
    if Map.has_key?(params, :amount) or Map.has_key?(params, :lines) or Map.has_key?(params, :shipping_cost) do
      :ok
    else
      {:error, :missing_amount_source}
    end
  end

  defp validate_invoice_finalized(%{status: "draft"}), do: {:error, :invoice_not_finalized}
  defp validate_invoice_finalized(_invoice), do: :ok

  defp build_credit_note(params, invoice, create_balance_transaction? \\ true) do
    amount = credit_amount(params, invoice)
    amount_remaining = Map.get(invoice, :amount_remaining, 0)
    pre_payment_amount = min(amount, amount_remaining)
    post_payment_amount = amount - pre_payment_amount
    credit_amount = get_integer(params, :credit_amount, post_payment_amount)
    id = generate_id("cn", Map.get(params, :id))
    lines = build_lines(params, invoice, id, amount)

    %{
      amount: amount,
      amount_shipping: 0,
      created: PaperTiger.now(),
      currency: invoice.currency || "usd",
      customer: invoice.customer,
      customer_balance_transaction: nil,
      discount_amount: 0,
      discount_amounts: [],
      effective_at: get_optional_integer(params, :effective_at) || PaperTiger.now(),
      id: id,
      invoice: invoice.id,
      lines: %{data: lines, has_more: false, object: "list", url: "/v1/credit_notes/#{id}/lines"},
      livemode: false,
      memo: Map.get(params, :memo),
      metadata: Map.get(params, :metadata, %{}),
      number:
        "#{invoice.number || invoice.id}-CN-#{CreditNotes.find_by_invoice(invoice.id) |> length() |> Kernel.+(1)}",
      object: "credit_note",
      out_of_band_amount: get_optional_integer(params, :out_of_band_amount),
      pdf: "https://pay.stripe.com/credit_notes/#{id}/pdf",
      post_payment_amount: post_payment_amount,
      pre_payment_amount: pre_payment_amount,
      reason: Map.get(params, :reason),
      refunds: [],
      shipping_cost: Map.get(params, :shipping_cost),
      status: "issued",
      subtotal: amount,
      subtotal_excluding_tax: amount,
      total: amount,
      total_excluding_tax: amount,
      total_taxes: [],
      type: if(post_payment_amount > 0, do: "post_payment", else: "pre_payment"),
      voided_at: nil
    }
    |> maybe_create_customer_balance_transaction(credit_amount, create_balance_transaction?)
  end

  defp maybe_create_customer_balance_transaction(credit_note, credit_amount, true) when credit_amount > 0 do
    {:ok, transaction} =
      CustomerBalance.create_transaction(credit_note.customer, %{
        amount: -credit_amount,
        credit_note: credit_note.id,
        currency: credit_note.currency,
        description: "Credit note #{credit_note.number}",
        type: "credit_note"
      })

    Map.put(credit_note, :customer_balance_transaction, transaction.id)
  end

  defp maybe_create_customer_balance_transaction(credit_note, _credit_amount, _create_balance_transaction?),
    do: credit_note

  defp credit_amount(%{amount: amount}, _invoice), do: to_integer(amount)
  defp credit_amount(%{lines: lines}, _invoice) when is_list(lines), do: Enum.reduce(lines, 0, &(&2 + line_amount(&1)))
  defp credit_amount(_params, invoice), do: Map.get(invoice, :amount_remaining, 0)

  defp build_lines(%{lines: lines}, invoice, credit_note_id, _amount) when is_list(lines) do
    Enum.map(lines, &build_line(&1, invoice, credit_note_id))
  end

  defp build_lines(_params, invoice, _credit_note_id, amount) do
    [
      %{
        amount: amount,
        description: "Credit for invoice #{invoice.id}",
        discount_amount: 0,
        discount_amounts: [],
        id: generate_id("cnli"),
        invoice_line_item: nil,
        livemode: false,
        object: "credit_note_line_item",
        quantity: 1,
        tax_rates: [],
        taxes: [],
        type: "custom_line_item",
        unit_amount: amount,
        unit_amount_decimal: to_string(amount)
      }
    ]
  end

  defp build_line(line, _invoice, _credit_note_id) do
    amount = line_amount(line)

    %{
      amount: amount,
      description: Map.get(line, :description),
      discount_amount: 0,
      discount_amounts: [],
      id: generate_id("cnli"),
      invoice_line_item: Map.get(line, :invoice_line_item),
      livemode: false,
      object: "credit_note_line_item",
      quantity: get_integer(line, :quantity, 1),
      tax_rates: Map.get(line, :tax_rates, []),
      taxes: [],
      type: Map.get(line, :type, "custom_line_item"),
      unit_amount: get_integer(line, :unit_amount, amount),
      unit_amount_decimal: to_string(get_integer(line, :unit_amount, amount))
    }
  end

  defp line_amount(line) do
    cond do
      Map.has_key?(line, :amount) ->
        get_integer(line, :amount)

      Map.has_key?(line, :unit_amount) ->
        get_integer(line, :unit_amount) * get_integer(line, :quantity, 1)

      true ->
        0
    end
  end

  defp apply_credit_note(invoice, credit_note) do
    amount_due = max(Map.get(invoice, :amount_due, 0) - credit_note.pre_payment_amount, 0)
    amount_remaining = max(Map.get(invoice, :amount_remaining, 0) - credit_note.pre_payment_amount, 0)

    updated =
      invoice
      |> Map.put(:amount_due, amount_due)
      |> Map.put(:amount_remaining, amount_remaining)
      |> Map.update(
        :pre_payment_credit_notes_amount,
        credit_note.pre_payment_amount,
        &(&1 + credit_note.pre_payment_amount)
      )
      |> Map.update(
        :post_payment_credit_notes_amount,
        credit_note.post_payment_amount,
        &(&1 + credit_note.post_payment_amount)
      )
      |> maybe_mark_invoice_paid()

    Invoices.update(updated)
  end

  defp maybe_mark_invoice_paid(%{amount_remaining: 0} = invoice) do
    invoice
    |> Map.put(:paid, true)
    |> Map.put(:status, "paid")
  end

  defp maybe_mark_invoice_paid(invoice), do: invoice

  defp paginate_lines(lines, params, url) do
    limit = params |> get_integer(:limit, 10) |> min(100)

    %{
      data: Enum.take(lines, limit),
      has_more: length(lines) > limit,
      object: "list",
      url: url
    }
  end

  defp maybe_expand(credit_note, params) do
    params
    |> parse_expand_params()
    |> then(&PaperTiger.Hydrator.hydrate(credit_note, &1))
  end
end
