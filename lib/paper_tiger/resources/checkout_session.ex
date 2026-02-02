defmodule PaperTiger.Resources.CheckoutSession do
  @moduledoc """
  Handles Checkout Session resource endpoints.

  ## Endpoints

  - POST   /v1/checkout/sessions            - Create checkout session
  - GET    /v1/checkout/sessions/:id        - Retrieve checkout session
  - GET    /v1/checkout/sessions            - List checkout sessions
  - POST   /v1/checkout/sessions/:id/expire - Expire checkout session (Stripe API)

  ## Test Endpoints

  - POST   /_test/checkout/sessions/:id/complete - Complete checkout session (test helper)

  Note: Checkout sessions are immutable after creation (no update or delete).
  The complete endpoint is a PaperTiger test helper - real Stripe completes sessions
  automatically when payment succeeds.

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
  alias PaperTiger.Store.Invoices
  alias PaperTiger.Store.PaymentIntents
  alias PaperTiger.Store.PaymentMethods
  alias PaperTiger.Store.Prices
  alias PaperTiger.Store.SetupIntents
  alias PaperTiger.Store.SubscriptionItems
  alias PaperTiger.Store.Subscriptions

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

  @doc """
  Expires an open checkout session.

  POST /v1/checkout/sessions/:id/expire

  A Checkout Session can only be expired when its status is "open".
  After expiration, customers cannot complete the session.
  """
  @spec expire(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def expire(conn, id) do
    case CheckoutSessions.get(id) do
      {:ok, %{status: "open"} = session} ->
        expired_session = %{session | status: "expired"}
        {:ok, expired_session} = CheckoutSessions.update(expired_session)

        :telemetry.execute(
          [:paper_tiger, :checkout, :session, :expired],
          %{},
          %{object: expired_session}
        )

        expired_session
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:ok, %{status: status}} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request(
            "This Session is not in an expireable state. Session status: #{status}",
            "status"
          )
        )

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("checkout.session", id))
    end
  end

  @doc """
  Completes a checkout session (test helper).

  POST /_test/checkout/sessions/:id/complete

  This is a PaperTiger test helper endpoint - real Stripe completes sessions
  automatically when payment succeeds. Use this to simulate successful checkout
  completion in tests.

  Based on the session mode, this will:
  - payment: Creates a succeeded PaymentIntent
  - subscription: Creates an active Subscription with items
  - setup: Creates a succeeded SetupIntent

  Fires the checkout.session.completed webhook event.
  """
  @spec complete(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def complete(conn, id) do
    case CheckoutSessions.get(id) do
      {:ok, %{status: "open"} = session} ->
        completed_session = complete_session(session)
        {:ok, completed_session} = CheckoutSessions.update(completed_session)

        :telemetry.execute(
          [:paper_tiger, :checkout, :session, :completed],
          %{},
          %{object: completed_session}
        )

        completed_session
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:ok, %{status: "complete"}} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request(
            "This Session has already been completed.",
            "status"
          )
        )

      {:ok, %{status: status}} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request(
            "This Session cannot be completed. Session status: #{status}",
            "status"
          )
        )

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("checkout.session", id))
    end
  end

  @doc """
  Browser-accessible checkout completion endpoint.

  GET /checkout/:id/complete

  This is called when a user is redirected to the checkout URL. Unlike the
  `/_test/checkout/sessions/:id/complete` POST endpoint (for programmatic use),
  this handles the browser redirect flow:

  1. Completes the checkout session (creates subscription/payment/setup intent)
  2. Redirects the browser to the session's success_url

  This makes checkout flows work transparently in tests - the application just
  redirects to the checkout URL and the user ends up at success_url with the
  session completed.
  """
  @spec browser_complete(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def browser_complete(conn, id) do
    case CheckoutSessions.get(id) do
      {:ok, %{status: "open", success_url: success_url} = session} ->
        completed_session = complete_session(session)
        {:ok, _completed_session} = CheckoutSessions.update(completed_session)

        :telemetry.execute(
          [:paper_tiger, :checkout, :session, :completed],
          %{},
          %{object: completed_session}
        )

        # Redirect browser to success URL
        conn
        |> Plug.Conn.put_resp_header("location", success_url)
        |> Plug.Conn.send_resp(302, "")

      {:ok, %{status: "complete", success_url: success_url}} ->
        # Already completed, just redirect
        conn
        |> Plug.Conn.put_resp_header("location", success_url)
        |> Plug.Conn.send_resp(302, "")

      {:ok, %{status: status}} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request(
            "This Session cannot be completed. Session status: #{status}",
            "status"
          )
        )

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("checkout.session", id))
    end
  end

  ## Private Functions

  defp complete_session(session) do
    Logger.info(
      "complete_session called for #{session.id}, mode: #{session.mode}, customer: #{inspect(session.customer)}"
    )

    now = PaperTiger.now()

    # Create a payment method and attach to customer (fires payment_method.attached event)
    payment_method = create_payment_method_for_session(session)

    # Create side effects based on mode
    {subscription_id, payment_intent_id, setup_intent_id} =
      case session.mode do
        "subscription" ->
          subscription = create_subscription_from_session(session, payment_method)
          {subscription.id, nil, nil}

        "payment" ->
          payment_intent = create_payment_intent_from_session(session, payment_method)
          {nil, payment_intent.id, nil}

        "setup" ->
          Logger.info("Setup mode detected, creating setup intent and checking for incomplete subscriptions")
          setup_intent = create_setup_intent_from_session(session, payment_method)
          # For setup mode, check if customer has incomplete subscription and pay first invoice
          Logger.info("Checking incomplete subscriptions for customer: #{session.customer}")
          maybe_pay_incomplete_subscription_invoice(session.customer, payment_method)
          {nil, nil, setup_intent.id}

        _ ->
          {nil, nil, nil}
      end

    %{
      session
      | completed_at: now,
        payment_intent: payment_intent_id,
        payment_status: "paid",
        setup_intent: setup_intent_id,
        status: "complete",
        subscription: subscription_id
    }
  end

  defp create_payment_method_for_session(session) do
    now = PaperTiger.now()
    exp_year = now |> DateTime.from_unix!() |> Map.get(:year) |> Kernel.+(3)

    payment_method = %{
      billing_details: %{
        address: %{
          city: nil,
          country: nil,
          line1: nil,
          line2: nil,
          postal_code: nil,
          state: nil
        },
        email: nil,
        name: nil,
        phone: nil
      },
      card: %{
        brand: "visa",
        checks: %{
          address_line1_check: nil,
          address_postal_code_check: nil,
          cvc_check: "pass"
        },
        country: "US",
        exp_month: 12,
        exp_year: exp_year,
        fingerprint: generate_fingerprint(),
        funding: "credit",
        generated_from: nil,
        last4: "4242",
        networks: %{available: ["visa"], preferred: nil},
        three_d_secure_usage: %{supported: true},
        wallet: nil
      },
      created: now,
      customer: session.customer,
      id: generate_id("pm"),
      livemode: false,
      metadata: %{},
      object: "payment_method",
      type: "card"
    }

    {:ok, payment_method} = PaymentMethods.insert(payment_method)

    # Fire payment_method.attached event - this is critical for downstream processing
    :telemetry.execute(
      [:paper_tiger, :payment_method, :attached],
      %{},
      %{object: payment_method}
    )

    payment_method
  end

  defp generate_fingerprint do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end

  defp create_subscription_from_session(session, payment_method) do
    now = PaperTiger.now()

    subscription = %{
      billing_cycle_anchor: now,
      cancel_at: nil,
      cancel_at_period_end: false,
      canceled_at: nil,
      collection_method: "charge_automatically",
      created: now,
      current_period_end: now + 30 * 86_400,
      current_period_start: now,
      customer: session.customer,
      days_until_due: nil,
      default_payment_method: payment_method.id,
      ended_at: nil,
      id: generate_id("sub"),
      items: %{data: [], has_more: false, object: "list", url: "/v1/subscription_items"},
      latest_invoice: nil,
      livemode: false,
      metadata: session.metadata || %{},
      next_pending_invoice_item_invoice: nil,
      object: "subscription",
      pending_setup_intent: nil,
      pending_update: nil,
      start_date: now,
      status: "active",
      trial_end: nil,
      trial_start: nil
    }

    {:ok, subscription} = Subscriptions.insert(subscription)

    # Create subscription items from line items
    create_subscription_items_from_line_items(subscription.id, session.line_items)

    subscription
  end

  defp create_subscription_items_from_line_items(subscription_id, line_items) when is_list(line_items) do
    now = PaperTiger.now()

    line_items
    |> Enum.with_index()
    |> Enum.each(fn {item, index} ->
      price_id = Map.get(item, :price) || Map.get(item, "price")
      price_object = fetch_price_object(price_id)
      quantity = Map.get(item, :quantity) || Map.get(item, "quantity") || 1

      subscription_item = %{
        created: now + index,
        id: generate_id("si"),
        metadata: %{},
        object: "subscription_item",
        price: price_object,
        quantity: quantity,
        subscription: subscription_id
      }

      SubscriptionItems.insert(subscription_item)
    end)

    :ok
  end

  defp create_subscription_items_from_line_items(_subscription_id, _), do: :ok

  defp fetch_price_object(price_id) when is_binary(price_id) do
    case Prices.get(price_id) do
      {:ok, price} -> price
      {:error, :not_found} -> build_minimal_price_object(price_id)
    end
  end

  defp fetch_price_object(_), do: nil

  defp build_minimal_price_object(price_id) do
    %{
      active: true,
      currency: "usd",
      id: price_id,
      livemode: false,
      object: "price",
      type: "recurring"
    }
  end

  defp create_payment_intent_from_session(session, payment_method) do
    now = PaperTiger.now()

    # Calculate amount from line items
    amount = calculate_amount_from_line_items(session.line_items)

    payment_intent = %{
      amount: amount,
      amount_details: nil,
      application: nil,
      application_fee_amount: nil,
      cancellation_reason: nil,
      capture_method: "automatic",
      client_secret: generate_client_secret(),
      confirmation_method: "automatic",
      created: now,
      currency: session.currency || "usd",
      customer: session.customer,
      description: nil,
      id: generate_id("pi"),
      invoice: nil,
      last_payment_error: nil,
      livemode: false,
      mandate: nil,
      metadata: session.metadata || %{},
      next_action: nil,
      object: "payment_intent",
      off_session: nil,
      on_behalf_of: nil,
      payment_method: payment_method.id,
      processing: nil,
      receipt_email: nil,
      review: nil,
      setup_future_usage: nil,
      shipping: nil,
      source: nil,
      statement_descriptor: nil,
      status: "succeeded"
    }

    {:ok, payment_intent} = PaymentIntents.insert(payment_intent)
    payment_intent
  end

  defp calculate_amount_from_line_items(line_items) when is_list(line_items) do
    Enum.reduce(line_items, 0, fn item, acc ->
      amount = Map.get(item, :amount) || Map.get(item, "amount") || 0
      quantity = Map.get(item, :quantity) || Map.get(item, "quantity") || 1
      # Ensure both values are integers for arithmetic
      amount_int = if is_binary(amount), do: String.to_integer(amount), else: amount
      quantity_int = if is_binary(quantity), do: String.to_integer(quantity), else: quantity
      acc + amount_int * quantity_int
    end)
  end

  defp calculate_amount_from_line_items(_), do: 0

  defp create_setup_intent_from_session(session, payment_method) do
    now = PaperTiger.now()

    setup_intent = %{
      application: nil,
      client_secret: generate_client_secret(),
      created: now,
      customer: session.customer,
      description: nil,
      id: generate_id("seti"),
      last_setup_error: nil,
      livemode: false,
      mandate: nil,
      metadata: session.metadata || %{},
      next_action: nil,
      object: "setup_intent",
      on_behalf_of: nil,
      payment_method: payment_method.id,
      payment_method_types: session.payment_method_types || ["card"],
      single_use_mandate: nil,
      status: "succeeded",
      usage: "off_session"
    }

    {:ok, setup_intent} = SetupIntents.insert(setup_intent)
    setup_intent
  end

  defp generate_client_secret do
    random_part =
      :crypto.strong_rand_bytes(24)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "secret_#{random_part}"
  end

  # When a setup session completes (customer adds payment method), check if they have
  # an incomplete subscription and automatically pay its first invoice.
  # This simulates Stripe's behavior of automatically charging the invoice when
  # a payment method is added to a subscription with status "incomplete".
  defp maybe_pay_incomplete_subscription_invoice(nil, _payment_method), do: :ok

  defp maybe_pay_incomplete_subscription_invoice(customer_id, payment_method) do
    Logger.debug("Checking for incomplete subscriptions for customer: #{customer_id}")

    # Find incomplete subscriptions for this customer
    subscriptions = Subscriptions.find_by_customer(customer_id)
    Logger.debug("Found #{length(subscriptions)} subscriptions for customer #{customer_id}")

    incomplete_sub =
      Enum.find(subscriptions, fn sub ->
        Logger.debug("Subscription #{sub.id} status: #{sub.status}")
        sub.status == "incomplete"
      end)

    if incomplete_sub do
      Logger.debug("Found incomplete subscription: #{incomplete_sub.id}, creating invoice...")
      create_and_pay_subscription_invoice(incomplete_sub, customer_id, payment_method)
    else
      Logger.debug("No incomplete subscriptions found")
      :ok
    end
  end

  defp create_and_pay_subscription_invoice(subscription, customer_id, payment_method) do
    now = PaperTiger.now()

    # Get subscription items to build invoice line items
    {:ok, subscription_with_items} = Subscriptions.get(subscription.id)
    items = Map.get(subscription_with_items, :items, %{}) |> Map.get(:data, [])

    # Calculate total from subscription items
    {total, lines} = build_invoice_lines_from_subscription_items(items, now)

    # Create invoice
    invoice = %{
      amount_due: total,
      amount_paid: total,
      amount_remaining: 0,
      attempt_count: 1,
      attempted: true,
      billing_reason: "subscription_create",
      collection_method: "charge_automatically",
      created: now,
      currency: "usd",
      customer: customer_id,
      default_payment_method: payment_method.id,
      due_date: nil,
      ending_balance: 0,
      id: generate_id("in"),
      lines: %{
        data: lines,
        has_more: false,
        object: "list",
        url: "/v1/invoices/#{generate_id("in")}/lines"
      },
      livemode: false,
      metadata: %{},
      number: "#{:rand.uniform(999_999)}",
      object: "invoice",
      paid: true,
      payment_intent: nil,
      period_end: subscription.current_period_end,
      period_start: subscription.current_period_start,
      starting_balance: 0,
      status: "paid",
      subscription: subscription.id,
      subtotal: total,
      total: total
    }

    {:ok, paid_invoice} = Invoices.insert(invoice)

    # Fire invoice events
    :telemetry.execute([:paper_tiger, :invoice, :created], %{}, %{object: paid_invoice})
    :telemetry.execute([:paper_tiger, :invoice, :finalized], %{}, %{object: paid_invoice})
    :telemetry.execute([:paper_tiger, :invoice, :paid], %{}, %{object: paid_invoice})
    :telemetry.execute([:paper_tiger, :invoice, :payment_succeeded], %{}, %{object: paid_invoice})

    # Update subscription to active
    active_subscription = %{subscription | latest_invoice: paid_invoice.id, status: "active"}
    {:ok, _updated} = Subscriptions.update(active_subscription)

    Logger.debug("Auto-paid invoice for incomplete subscription: #{subscription.id}")

    :ok
  end

  defp build_invoice_lines_from_subscription_items(items, now) when is_list(items) do
    lines =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, _index} ->
        # Get price ID from item (handles both :price as string and as map)
        price_id =
          case Map.get(item, :price) do
            price_id when is_binary(price_id) -> price_id
            %{id: price_id} -> price_id
            _ -> nil
          end

        # Fetch full price object from store to ensure all fields are present
        {:ok, full_price} = Prices.get(price_id)

        amount = Map.get(full_price, :unit_amount, 0)
        quantity = Map.get(item, :quantity, 1)

        %{
          amount: amount * quantity,
          currency: Map.get(full_price, :currency, "usd"),
          description: Map.get(full_price, :nickname) || "Subscription",
          id: generate_id("il"),
          object: "line_item",
          period: %{
            end: now + 30 * 86_400,
            start: now
          },
          price: full_price,
          proration: false,
          quantity: quantity,
          subscription: Map.get(item, :subscription),
          subscription_item: item.id,
          type: "subscription"
        }
      end)

    total = Enum.reduce(lines, 0, fn line, acc -> acc + line.amount end)
    {total, lines}
  end

  defp build_invoice_lines_from_subscription_items(_, _now), do: {0, []}

  defp build_session(params) do
    session_id = generate_id("cs")

    %{
      id: session_id,
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
      # URL field - matches Stripe's hosted checkout URL format
      url: generate_checkout_url(session_id),
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
      payment_intent: Map.get(params, :payment_intent),
      setup_intent: Map.get(params, :setup_intent),
      completed_at: nil,
      total_details: Map.get(params, :total_details),
      ui_mode: Map.get(params, :ui_mode, "hosted")
    }
  end

  # Generates a checkout URL pointing to PaperTiger's auto-complete endpoint.
  #
  # Unlike real Stripe which hosts a checkout page, PaperTiger auto-completes
  # the session when this URL is visited. This makes checkout flows work
  # transparently in tests without any special handling in application code.
  defp generate_checkout_url(session_id) do
    port = Application.get_env(:paper_tiger, :port, 4001)
    "http://localhost:#{port}/checkout/#{session_id}/complete"
  end

  defp maybe_expand(session, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(session, expand_params)
  end

end
