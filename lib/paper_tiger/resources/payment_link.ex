defmodule PaperTiger.Resources.PaymentLink do
  @moduledoc """
  Handles Payment Link resource endpoints and deterministic hosted browser flow.
  """

  import PaperTiger.Resource

  alias PaperTiger.AutomaticTax
  alias PaperTiger.LineItems
  alias PaperTiger.Store.CheckoutSessions
  alias PaperTiger.Store.PaymentLinks

  @doc """
  Creates a Payment Link.
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:line_items]),
         :ok <- validate_line_items(conn.params.line_items),
         payment_link = build_payment_link(conn.params),
         {:ok, payment_link} <- PaymentLinks.insert(payment_link) do
      maybe_store_idempotency(conn, payment_link)

      payment_link
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :invalid_params, field} ->
        error_response(conn, PaperTiger.Error.invalid_request("Missing required parameter", field))

      {:error, :invalid_line_items, message} ->
        error_response(conn, PaperTiger.Error.invalid_request(message, "line_items"))
    end
  end

  @doc """
  Retrieves a Payment Link.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case PaymentLinks.get(id) do
      {:ok, payment_link} ->
        payment_link
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("payment_link", id))
    end
  end

  @doc """
  Updates a Payment Link.
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- PaymentLinks.get(id),
         {:ok, updated} <- update_payment_link(existing, conn.params),
         {:ok, updated} <- PaymentLinks.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("payment_link", id))

      {:error, :invalid_line_items, message} ->
        error_response(conn, PaperTiger.Error.invalid_request(message, "line_items"))
    end
  end

  @doc """
  Lists Payment Links.
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    conn.params
    |> parse_pagination_params()
    |> PaymentLinks.list()
    |> then(&json_response(conn, 200, &1))
  end

  @doc """
  Lists a Payment Link's line items with Stripe-style cursor pagination.
  """
  @spec line_items(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def line_items(conn, id) do
    case PaymentLinks.get(id) do
      {:ok, payment_link} ->
        payment_link
        |> Map.get(:line_items, [])
        |> LineItems.paginate(conn.params, "/v1/payment_links/#{id}/line_items")
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("payment_link", id))
    end
  end

  @doc """
  Browser-accessible Payment Link endpoint.

  PaperTiger creates a Checkout Session from the Payment Link and redirects to
  the existing checkout auto-completion URL. Visiting that URL completes the
  payment/subscription side effects and redirects to the configured success URL.
  """
  @spec browser_checkout(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def browser_checkout(conn, id) do
    case PaymentLinks.get(id) do
      {:ok, %{active: false}} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("This Payment Link is inactive.", "active")
        )

      {:ok, payment_link} ->
        session = build_checkout_session(payment_link)
        {:ok, session} = CheckoutSessions.insert(session)

        conn
        |> Plug.Conn.put_resp_header("location", session.url)
        |> Plug.Conn.send_resp(302, "")

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("payment_link", id))
    end
  end

  @doc """
  Deterministic success page used by Payment Links without redirect completion.
  """
  @spec browser_complete(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def browser_complete(conn, _id) do
    Plug.Conn.send_resp(conn, 200, "Payment link completed")
  end

  defp validate_line_items(line_items) when is_list(line_items) and line_items != [] do
    cond do
      length(line_items) > 20 ->
        {:error, :invalid_line_items, "You may provide up to 20 line items"}

      invalid_item = Enum.find(line_items, &(not valid_line_item?(&1))) ->
        {:error, :invalid_line_items, invalid_line_item_message(invalid_item)}

      true ->
        :ok
    end
  end

  defp validate_line_items(_line_items), do: {:error, :invalid_line_items, "Invalid array"}

  defp valid_line_item?(item) when is_map(item) do
    has_quantity?(item) and (has_price?(item) or valid_price_data?(LineItems.value(item, :price_data)))
  end

  defp valid_line_item?(_item), do: false

  defp has_quantity?(item), do: LineItems.value(item, :quantity) not in [nil, ""]
  defp has_price?(item), do: LineItems.value(item, :price) not in [nil, ""]

  defp valid_price_data?(price_data) when is_map(price_data) do
    product = LineItems.value(price_data, :product) || LineItems.value(price_data, :product_data)
    amount = LineItems.value(price_data, :unit_amount) || LineItems.value(price_data, :unit_amount_decimal)

    LineItems.value(price_data, :currency) not in [nil, ""] and
      product not in [nil, ""] and
      amount not in [nil, ""]
  end

  defp valid_price_data?(_price_data), do: false

  defp invalid_line_item_message(item) when is_map(item) do
    cond do
      not has_quantity?(item) ->
        "Missing required parameter: line_items.quantity"

      not (has_price?(item) or LineItems.value(item, :price_data)) ->
        "Missing required parameter: line_items.price"

      true ->
        "Invalid line_items.price_data"
    end
  end

  defp invalid_line_item_message(_item), do: "Invalid array"

  defp build_payment_link(params) do
    id = generate_id("plink", Map.get(params, :id))
    line_items = LineItems.normalize(Map.get(params, :line_items, []), :payment_link, id)
    totals = LineItems.totals(line_items)

    %{
      active: boolean_param(params, :active, true),
      after_completion: Map.get(params, :after_completion, %{type: "hosted_confirmation"}),
      allow_promotion_codes: boolean_param(params, :allow_promotion_codes, false),
      application_fee_amount: Map.get(params, :application_fee_amount),
      application_fee_percent: Map.get(params, :application_fee_percent),
      automatic_tax: AutomaticTax.automatic_tax(params, :checkout_session),
      billing_address_collection: Map.get(params, :billing_address_collection, "auto"),
      consent_collection: Map.get(params, :consent_collection),
      currency: Map.get(params, :currency) || LineItems.derive_currency(line_items),
      custom_fields: Map.get(params, :custom_fields, []),
      custom_text: Map.get(params, :custom_text),
      customer_creation: Map.get(params, :customer_creation),
      id: id,
      inactive_message: Map.get(params, :inactive_message),
      invoice_creation: Map.get(params, :invoice_creation),
      line_items: line_items,
      livemode: false,
      metadata: Map.get(params, :metadata, %{}),
      object: "payment_link",
      on_behalf_of: Map.get(params, :on_behalf_of),
      payment_intent_data: Map.get(params, :payment_intent_data),
      payment_method_collection: Map.get(params, :payment_method_collection, "always"),
      payment_method_types: Map.get(params, :payment_method_types, ["card"]),
      phone_number_collection: Map.get(params, :phone_number_collection, %{enabled: false}),
      restrictions: Map.get(params, :restrictions),
      shipping_address_collection: Map.get(params, :shipping_address_collection),
      shipping_options: Map.get(params, :shipping_options, []),
      submit_type: Map.get(params, :submit_type),
      subscription_data: Map.get(params, :subscription_data),
      tax_id_collection: Map.get(params, :tax_id_collection, %{enabled: false}),
      total_details: %{
        amount_discount: totals.amount_discount,
        amount_shipping: 0,
        amount_tax: totals.amount_tax
      },
      transfer_data: Map.get(params, :transfer_data),
      updated: PaperTiger.now(),
      url: payment_link_url(id)
    }
    |> Map.merge(%{
      amount_subtotal: totals.amount_subtotal,
      amount_total: totals.amount_total,
      created: PaperTiger.now()
    })
  end

  defp update_payment_link(payment_link, params) do
    with :ok <- validate_line_item_update(params) do
      params = normalize_update_params(params)

      updated =
        payment_link
        |> merge_updates(params, immutable_fields())
        |> maybe_update_line_items(params)
        |> put_updated_timestamp()

      {:ok, updated}
    end
  end

  defp validate_line_item_update(%{line_items: line_items}), do: validate_line_items(line_items)
  defp validate_line_item_update(_params), do: :ok

  defp maybe_update_line_items(payment_link, %{line_items: line_items}) do
    line_items = LineItems.normalize(line_items, :payment_link, payment_link.id)
    totals = LineItems.totals(line_items)

    payment_link
    |> Map.put(:line_items, line_items)
    |> Map.put(:amount_subtotal, totals.amount_subtotal)
    |> Map.put(:amount_total, totals.amount_total)
    |> Map.put(:total_details, %{
      amount_discount: totals.amount_discount,
      amount_shipping: 0,
      amount_tax: totals.amount_tax
    })
  end

  defp maybe_update_line_items(payment_link, _params), do: payment_link

  defp put_updated_timestamp(payment_link), do: Map.put(payment_link, :updated, PaperTiger.now())

  defp normalize_update_params(params) do
    params
    |> normalize_boolean_field(:active)
    |> normalize_boolean_field(:allow_promotion_codes)
  end

  defp normalize_boolean_field(params, key) do
    if Map.has_key?(params, key) do
      Map.put(params, key, to_boolean(Map.get(params, key)))
    else
      params
    end
  end

  defp boolean_param(params, key, default) do
    if Map.has_key?(params, key) do
      to_boolean(Map.get(params, key))
    else
      default
    end
  end

  defp immutable_fields do
    [
      :amount_subtotal,
      :amount_total,
      :created,
      :id,
      :line_items,
      :livemode,
      :object,
      :total_details,
      :url
    ]
  end

  defp build_checkout_session(payment_link) do
    session_id = generate_id("cs")
    line_items = LineItems.reassign(payment_link.line_items, :session, session_id)
    totals = LineItems.totals(line_items)
    now = PaperTiger.now()

    %{
      amount_subtotal: totals.amount_subtotal,
      amount_total: totals.amount_total,
      automatic_tax: payment_link.automatic_tax,
      billing_address_collection: payment_link.billing_address_collection,
      cancel_url: nil,
      completed_at: nil,
      consent_collection: payment_link.consent_collection,
      created: now,
      currency: payment_link.currency,
      customer: nil,
      customer_creation: payment_link.customer_creation,
      expires_at: now + 86_400,
      id: session_id,
      line_items: line_items,
      livemode: false,
      metadata: payment_link.metadata || %{},
      mode: checkout_mode(payment_link, line_items),
      object: "checkout.session",
      payment_intent: nil,
      payment_link: payment_link.id,
      payment_method_collection: payment_link.payment_method_collection,
      payment_method_types: payment_link.payment_method_types || ["card"],
      payment_status: "unpaid",
      phone_number_collection: payment_link.phone_number_collection,
      setup_intent: nil,
      shipping_address_collection: payment_link.shipping_address_collection,
      shipping_options: payment_link.shipping_options || [],
      status: "open",
      submit_type: payment_link.submit_type,
      subscription: nil,
      success_url: success_url(payment_link),
      total_details: payment_link.total_details,
      ui_mode: "hosted",
      url: checkout_url(session_id)
    }
  end

  defp checkout_mode(%{subscription_data: subscription_data}, _line_items) when is_map(subscription_data) do
    "subscription"
  end

  defp checkout_mode(_payment_link, line_items) do
    if Enum.any?(line_items, &recurring_line_item?/1), do: "subscription", else: "payment"
  end

  defp recurring_line_item?(line_item) do
    line_item
    |> LineItems.value(:price)
    |> LineItems.value(:recurring)
    |> is_map()
  end

  defp success_url(%{after_completion: %{redirect: %{url: url}, type: "redirect"}}) when is_binary(url) do
    url
  end

  defp success_url(%{after_completion: %{"redirect" => %{"url" => url}, "type" => "redirect"}}) when is_binary(url) do
    url
  end

  defp success_url(payment_link), do: "#{base_url()}/payment_links/#{payment_link.id}/complete"

  defp maybe_expand(payment_link, params) do
    expand_params = parse_expand_params(params)

    payment_link =
      if "line_items" in expand_params do
        Map.put(
          payment_link,
          :line_items,
          LineItems.paginate(payment_link.line_items, %{}, "/v1/payment_links/#{payment_link.id}/line_items")
        )
      else
        payment_link
      end

    PaperTiger.Hydrator.hydrate(payment_link, expand_params -- ["line_items"])
  end

  defp payment_link_url(id), do: "#{base_url()}/payment_links/#{id}"
  defp checkout_url(id), do: "#{base_url()}/checkout/#{id}/complete"

  defp base_url do
    port = Application.get_env(:paper_tiger, :actual_port) || Application.get_env(:paper_tiger, :port, 4001)
    "http://localhost:#{port}"
  end
end
