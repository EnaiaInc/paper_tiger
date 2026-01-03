defmodule PaperTiger.TestClient do
  @moduledoc """
  Dual-mode Stripe client for contract testing.

  Allows running the same tests against either:
  1. **PaperTiger** (default) - Fast, offline, no setup required
  2. **Real Stripe API** (optional) - Validates PaperTiger matches production

  ## Usage

  ### Default Mode (PaperTiger)

      # Just run tests - no setup needed
      mix test

  ### Validation Mode (Real Stripe)

      # Set env vars and run tests
      export STRIPE_API_KEY=sk_test_your_key_here
      export VALIDATE_AGAINST_STRIPE=true
      mix test

  ## Architecture

  This module wraps Stripity Stripe client calls and routes them to the
  appropriate backend based on environment variables:

  - If `VALIDATE_AGAINST_STRIPE=true` → Uses Stripe.Customer.create/1 against stripe.com
  - Otherwise → Uses PaperTiger test helpers against mock server

  Same tests, switchable backend, confidence that PaperTiger matches reality.
  """

  alias PaperTiger.Router
  alias Stripe.Checkout.Session

  @doc """
  Returns the current test mode.

  Validates that only test-mode API keys are used when running against real Stripe.
  Raises if a live-mode key (sk_live_*) is detected to prevent accidental production usage.

  ## Examples

      iex> System.put_env("VALIDATE_AGAINST_STRIPE", "true")
      iex> PaperTiger.TestClient.mode()
      :real_stripe

      iex> System.delete_env("VALIDATE_AGAINST_STRIPE")
      iex> PaperTiger.TestClient.mode()
      :paper_tiger
  """
  def mode do
    if System.get_env("VALIDATE_AGAINST_STRIPE") == "true" do
      validate_test_mode_key!()
      :real_stripe
    else
      :paper_tiger
    end
  end

  @doc """
  Validates that the STRIPE_API_KEY is a test-mode key (sk_test_*).

  Performs two-layer validation:
  1. Checks the key prefix (sk_test_*, rk_test_*)
  2. Makes a live API call to /v1/balance and verifies `livemode: false`

  Raises an error if:
  - A live-mode key (sk_live_*) is detected
  - No API key is configured
  - The API returns `livemode: true`

  This prevents accidentally running contract tests against production Stripe.
  """
  def validate_test_mode_key! do
    api_key = System.get_env("STRIPE_API_KEY") || Application.get_env(:stripity_stripe, :api_key)

    # First layer: check key prefix
    validate_key_prefix!(api_key)

    # Second layer: verify with live API call
    verify_test_mode_via_api!(api_key)
  end

  defp validate_key_prefix!(api_key) do
    cond do
      is_nil(api_key) or api_key == "" ->
        raise """
        STRIPE_API_KEY not configured!

        Contract tests require a Stripe test-mode API key when VALIDATE_AGAINST_STRIPE=true.

        Set the environment variable:
            export STRIPE_API_KEY=sk_test_your_key_here

        Get your test key from: https://dashboard.stripe.com/test/apikeys
        """

      String.starts_with?(api_key, "sk_live_") ->
        raise """
        🚨 LIVE MODE API KEY DETECTED! 🚨

        You are attempting to run contract tests with a LIVE Stripe API key.
        This would create real charges and affect real customers!

        Current key: #{String.slice(api_key, 0, 12)}...

        Please use a TEST mode key instead:
            export STRIPE_API_KEY=sk_test_your_key_here

        Get your test key from: https://dashboard.stripe.com/test/apikeys
        """

      String.starts_with?(api_key, "rk_live_") ->
        raise """
        🚨 LIVE MODE RESTRICTED KEY DETECTED! 🚨

        You are attempting to run contract tests with a LIVE Stripe restricted key.
        This could affect real customers!

        Please use a TEST mode key instead:
            export STRIPE_API_KEY=sk_test_your_key_here
        """

      String.starts_with?(api_key, "sk_test_") ->
        :ok

      String.starts_with?(api_key, "rk_test_") ->
        :ok

      true ->
        raise """
        Invalid Stripe API key format!

        Expected a test-mode key starting with 'sk_test_' or 'rk_test_'.
        Got: #{String.slice(api_key, 0, 12)}...

        Get your test key from: https://dashboard.stripe.com/test/apikeys
        """
    end
  end

  defp verify_test_mode_via_api!(api_key) do
    # Make a simple API call to verify we're actually in test mode
    # The /v1/balance endpoint is read-only and returns livemode field
    url = "https://api.stripe.com/v1/balance"

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/x-www-form-urlencoded"}
    ]

    case Req.get(url, headers: headers) do
      {:ok, %{body: body, status: 200}} ->
        case body do
          %{"livemode" => false} ->
            :ok

          %{"livemode" => true} ->
            raise """
            🚨 LIVE MODE CONFIRMED BY STRIPE API! 🚨

            The Stripe API confirmed this key is in LIVE mode.
            This would create real charges and affect real customers!

            Current key: #{String.slice(api_key, 0, 12)}...

            Please use a TEST mode key instead:
                export STRIPE_API_KEY=sk_test_your_key_here

            Get your test key from: https://dashboard.stripe.com/test/apikeys
            """

          _ ->
            # Couldn't parse response, but key prefix check passed
            :ok
        end

      {:ok, %{status: 401}} ->
        raise """
        Invalid Stripe API key!

        The key was rejected by Stripe. Please verify your API key.

        Current key: #{String.slice(api_key, 0, 12)}...

        Get your test key from: https://dashboard.stripe.com/test/apikeys
        """

      {:error, reason} ->
        # Network error - log warning but allow to proceed if key prefix was valid
        IO.warn("""
        Could not verify test mode via Stripe API: #{inspect(reason)}
        Proceeding based on key prefix validation only.
        """)

        :ok
    end
  end

  @doc """
  Returns true if running against real Stripe API.
  """
  def real_stripe?, do: mode() == :real_stripe

  @doc """
  Returns true if running against PaperTiger mock.
  """
  def paper_tiger?, do: mode() == :paper_tiger

  ## Customer Operations

  @doc """
  Creates a customer.

  Routes to real Stripe or PaperTiger based on mode.
  """
  def create_customer(params) do
    case mode() do
      :real_stripe ->
        create_customer_real(params)

      :paper_tiger ->
        create_customer_mock(params)
    end
  end

  @doc """
  Retrieves a customer by ID.
  """
  def get_customer(customer_id) do
    case mode() do
      :real_stripe ->
        get_customer_real(customer_id)

      :paper_tiger ->
        get_customer_mock(customer_id)
    end
  end

  @doc """
  Updates a customer.
  """
  def update_customer(customer_id, params) do
    case mode() do
      :real_stripe ->
        update_customer_real(customer_id, params)

      :paper_tiger ->
        update_customer_mock(customer_id, params)
    end
  end

  @doc """
  Deletes a customer.
  """
  def delete_customer(customer_id) do
    case mode() do
      :real_stripe ->
        delete_customer_real(customer_id)

      :paper_tiger ->
        delete_customer_mock(customer_id)
    end
  end

  @doc """
  Lists customers.
  """
  def list_customers(params \\ %{}) do
    case mode() do
      :real_stripe ->
        list_customers_real(params)

      :paper_tiger ->
        list_customers_mock(params)
    end
  end

  ## Product Operations

  @doc """
  Creates a product.
  """
  def create_product(params) do
    case mode() do
      :real_stripe ->
        create_product_real(params)

      :paper_tiger ->
        create_product_mock(params)
    end
  end

  @doc """
  Retrieves a product by ID.
  """
  def get_product(product_id) do
    case mode() do
      :real_stripe ->
        get_product_real(product_id)

      :paper_tiger ->
        get_product_mock(product_id)
    end
  end

  ## Price Operations

  @doc """
  Creates a price.
  """
  def create_price(params) do
    case mode() do
      :real_stripe ->
        create_price_real(params)

      :paper_tiger ->
        create_price_mock(params)
    end
  end

  @doc """
  Retrieves a price by ID.
  """
  def get_price(price_id) do
    case mode() do
      :real_stripe ->
        get_price_real(price_id)

      :paper_tiger ->
        get_price_mock(price_id)
    end
  end

  ## Subscription Operations

  @doc """
  Creates a subscription.
  """
  def create_subscription(params) do
    case mode() do
      :real_stripe ->
        create_subscription_real(params)

      :paper_tiger ->
        create_subscription_mock(params)
    end
  end

  @doc """
  Retrieves a subscription by ID.
  """
  def get_subscription(subscription_id) do
    case mode() do
      :real_stripe ->
        get_subscription_real(subscription_id)

      :paper_tiger ->
        get_subscription_mock(subscription_id)
    end
  end

  @doc """
  Updates a subscription.
  """
  def update_subscription(subscription_id, params) do
    case mode() do
      :real_stripe ->
        update_subscription_real(subscription_id, params)

      :paper_tiger ->
        update_subscription_mock(subscription_id, params)
    end
  end

  @doc """
  Cancels a subscription.
  """
  def delete_subscription(subscription_id) do
    case mode() do
      :real_stripe ->
        delete_subscription_real(subscription_id)

      :paper_tiger ->
        delete_subscription_mock(subscription_id)
    end
  end

  @doc """
  Lists subscriptions.
  """
  def list_subscriptions(params \\ %{}) do
    case mode() do
      :real_stripe ->
        list_subscriptions_real(params)

      :paper_tiger ->
        list_subscriptions_mock(params)
    end
  end

  ## PaymentMethod Operations

  @doc """
  Creates a payment method.
  """
  def create_payment_method(params) do
    case mode() do
      :real_stripe ->
        create_payment_method_real(params)

      :paper_tiger ->
        create_payment_method_mock(params)
    end
  end

  @doc """
  Retrieves a payment method by ID.
  """
  def get_payment_method(payment_method_id) do
    case mode() do
      :real_stripe ->
        get_payment_method_real(payment_method_id)

      :paper_tiger ->
        get_payment_method_mock(payment_method_id)
    end
  end

  ## Charge Operations

  @doc """
  Creates a charge.
  """
  def create_charge(params) do
    case mode() do
      :real_stripe ->
        create_charge_real(params)

      :paper_tiger ->
        create_charge_mock(params)
    end
  end

  @doc """
  Retrieves a charge by ID.
  """
  def get_charge(charge_id) do
    case mode() do
      :real_stripe ->
        get_charge_real(charge_id)

      :paper_tiger ->
        get_charge_mock(charge_id)
    end
  end

  ## PaymentIntent Operations

  @doc """
  Creates a payment intent.
  """
  def create_payment_intent(params) do
    case mode() do
      :real_stripe ->
        create_payment_intent_real(params)

      :paper_tiger ->
        create_payment_intent_mock(params)
    end
  end

  @doc """
  Retrieves a payment intent by ID.
  """
  def get_payment_intent(payment_intent_id) do
    case mode() do
      :real_stripe ->
        get_payment_intent_real(payment_intent_id)

      :paper_tiger ->
        get_payment_intent_mock(payment_intent_id)
    end
  end

  ## Refund Operations

  @doc """
  Creates a refund.
  """
  def create_refund(params) do
    case mode() do
      :real_stripe ->
        create_refund_real(params)

      :paper_tiger ->
        create_refund_mock(params)
    end
  end

  @doc """
  Retrieves a refund by ID.
  """
  def get_refund(refund_id) do
    case mode() do
      :real_stripe ->
        get_refund_real(refund_id)

      :paper_tiger ->
        get_refund_mock(refund_id)
    end
  end

  ## Checkout Session Operations

  @doc """
  Creates a checkout session.
  """
  def create_checkout_session(params) do
    case mode() do
      :real_stripe ->
        create_checkout_session_real(params)

      :paper_tiger ->
        create_checkout_session_mock(params)
    end
  end

  @doc """
  Retrieves a checkout session by ID.
  """
  def get_checkout_session(session_id) do
    case mode() do
      :real_stripe ->
        get_checkout_session_real(session_id)

      :paper_tiger ->
        get_checkout_session_mock(session_id)
    end
  end

  @doc """
  Expires a checkout session.
  """
  def expire_checkout_session(session_id) do
    case mode() do
      :real_stripe ->
        expire_checkout_session_real(session_id)

      :paper_tiger ->
        expire_checkout_session_mock(session_id)
    end
  end

  ## Invoice Operations

  @doc """
  Creates an invoice.
  """
  def create_invoice(params) do
    case mode() do
      :real_stripe ->
        create_invoice_real(params)

      :paper_tiger ->
        create_invoice_mock(params)
    end
  end

  @doc """
  Retrieves an invoice by ID.
  """
  def get_invoice(invoice_id) do
    case mode() do
      :real_stripe ->
        get_invoice_real(invoice_id)

      :paper_tiger ->
        get_invoice_mock(invoice_id)
    end
  end

  @doc """
  Updates an invoice.
  """
  def update_invoice(invoice_id, params) do
    case mode() do
      :real_stripe ->
        update_invoice_real(invoice_id, params)

      :paper_tiger ->
        update_invoice_mock(invoice_id, params)
    end
  end

  @doc """
  Finalizes an invoice.
  """
  def finalize_invoice(invoice_id) do
    case mode() do
      :real_stripe ->
        finalize_invoice_real(invoice_id)

      :paper_tiger ->
        finalize_invoice_mock(invoice_id)
    end
  end

  @doc """
  Pays an invoice.
  """
  def pay_invoice(invoice_id) do
    case mode() do
      :real_stripe ->
        pay_invoice_real(invoice_id)

      :paper_tiger ->
        pay_invoice_mock(invoice_id)
    end
  end

  @doc """
  Lists invoices with optional filters.

  Supports:
  - customer: Filter by customer ID
  - status: Filter by status (draft, open, paid, uncollectible, void)
  """
  def list_invoices(params \\ %{}) do
    case mode() do
      :real_stripe ->
        list_invoices_real(params)

      :paper_tiger ->
        list_invoices_mock(params)
    end
  end

  ## InvoiceItem Operations

  @doc """
  Creates an invoice item.
  """
  def create_invoice_item(params) do
    case mode() do
      :real_stripe ->
        create_invoice_item_real(params)

      :paper_tiger ->
        create_invoice_item_mock(params)
    end
  end

  @doc """
  Retrieves an invoice item by ID.
  """
  def get_invoice_item(invoice_item_id) do
    case mode() do
      :real_stripe ->
        get_invoice_item_real(invoice_item_id)

      :paper_tiger ->
        get_invoice_item_mock(invoice_item_id)
    end
  end

  ## Private - Real Stripe API

  defp stripe_opts do
    [api_key: System.get_env("STRIPE_API_KEY")]
  end

  defp create_customer_real(params) do
    case Stripe.Customer.create(normalize_params(params), stripe_opts()) do
      {:ok, customer} -> {:ok, stripe_to_map(customer)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp get_customer_real(customer_id) do
    case Stripe.Customer.retrieve(customer_id, %{}, stripe_opts()) do
      {:ok, customer} -> {:ok, stripe_to_map(customer)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp update_customer_real(customer_id, params) do
    case Stripe.Customer.update(customer_id, normalize_params(params), stripe_opts()) do
      {:ok, customer} -> {:ok, stripe_to_map(customer)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp delete_customer_real(customer_id) do
    case Stripe.Customer.delete(customer_id, stripe_opts()) do
      {:ok, result} ->
        # stripity_stripe loses the "deleted" field when converting to struct
        # Add it back since a successful delete means deleted=true
        map = stripe_to_map(result)
        {:ok, Map.put(map, "deleted", true)}

      {:error, error} ->
        {:error, stripe_error_to_map(error)}
    end
  end

  defp list_customers_real(params) do
    case Stripe.Customer.list(normalize_params(params), stripe_opts()) do
      {:ok, %{data: customers, has_more: has_more}} ->
        {:ok, %{"data" => Enum.map(customers, &stripe_to_map/1), "has_more" => has_more}}

      {:error, error} ->
        {:error, stripe_error_to_map(error)}
    end
  end

  defp create_subscription_real(params) do
    case Stripe.Subscription.create(normalize_params(params), stripe_opts()) do
      {:ok, subscription} -> {:ok, stripe_to_map(subscription)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp get_subscription_real(subscription_id) do
    case Stripe.Subscription.retrieve(subscription_id, %{}, stripe_opts()) do
      {:ok, subscription} -> {:ok, stripe_to_map(subscription)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp update_subscription_real(subscription_id, params) do
    case Stripe.Subscription.update(subscription_id, normalize_params(params), stripe_opts()) do
      {:ok, subscription} -> {:ok, stripe_to_map(subscription)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp delete_subscription_real(subscription_id) do
    case Stripe.Subscription.cancel(subscription_id, %{}, stripe_opts()) do
      {:ok, result} -> {:ok, stripe_to_map(result)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp list_subscriptions_real(params) do
    case Stripe.Subscription.list(normalize_params(params), stripe_opts()) do
      {:ok, %{data: subscriptions, has_more: has_more}} ->
        {:ok, %{"data" => Enum.map(subscriptions, &stripe_to_map/1), "has_more" => has_more}}

      {:error, error} ->
        {:error, stripe_error_to_map(error)}
    end
  end

  defp create_payment_method_real(params) do
    case Stripe.PaymentMethod.create(normalize_params(params), stripe_opts()) do
      {:ok, payment_method} -> {:ok, stripe_to_map(payment_method)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp get_payment_method_real(payment_method_id) do
    case Stripe.PaymentMethod.retrieve(payment_method_id, %{}, stripe_opts()) do
      {:ok, payment_method} -> {:ok, stripe_to_map(payment_method)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp create_invoice_real(params) do
    case Stripe.Invoice.create(normalize_params(params), stripe_opts()) do
      {:ok, invoice} -> {:ok, stripe_to_map(invoice)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp get_invoice_real(invoice_id) do
    case Stripe.Invoice.retrieve(invoice_id, %{}, stripe_opts()) do
      {:ok, invoice} -> {:ok, stripe_to_map(invoice)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp update_invoice_real(invoice_id, params) do
    case Stripe.Invoice.update(invoice_id, normalize_params(params), stripe_opts()) do
      {:ok, invoice} -> {:ok, stripe_to_map(invoice)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp finalize_invoice_real(invoice_id) do
    case Stripe.Invoice.finalize_invoice(invoice_id, %{}, stripe_opts()) do
      {:ok, invoice} -> {:ok, stripe_to_map(invoice)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp pay_invoice_real(invoice_id) do
    case Stripe.Invoice.pay(invoice_id, %{}, stripe_opts()) do
      {:ok, invoice} -> {:ok, stripe_to_map(invoice)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp list_invoices_real(params) do
    case Stripe.Invoice.list(normalize_params(params), stripe_opts()) do
      {:ok, %{data: invoices, has_more: has_more}} ->
        {:ok, %{"object" => "list", "data" => Enum.map(invoices, &stripe_to_map/1), "has_more" => has_more}}

      {:error, error} ->
        {:error, stripe_error_to_map(error)}
    end
  end

  defp create_invoice_item_real(params) do
    case Stripe.Invoiceitem.create(normalize_params(params), stripe_opts()) do
      {:ok, item} -> {:ok, stripe_to_map(item)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp get_invoice_item_real(invoice_item_id) do
    case Stripe.Invoiceitem.retrieve(invoice_item_id, %{}, stripe_opts()) do
      {:ok, item} -> {:ok, stripe_to_map(item)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp create_product_real(params) do
    case Stripe.Product.create(normalize_params(params), stripe_opts()) do
      {:ok, product} -> {:ok, stripe_to_map(product)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp get_product_real(product_id) do
    case Stripe.Product.retrieve(product_id, %{}, stripe_opts()) do
      {:ok, product} -> {:ok, stripe_to_map(product)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp create_price_real(params) do
    case Stripe.Price.create(normalize_params(params), stripe_opts()) do
      {:ok, price} -> {:ok, stripe_to_map(price)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp get_price_real(price_id) do
    case Stripe.Price.retrieve(price_id, %{}, stripe_opts()) do
      {:ok, price} -> {:ok, stripe_to_map(price)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp create_charge_real(params) do
    case Stripe.Charge.create(normalize_params(params), stripe_opts()) do
      {:ok, charge} -> {:ok, stripe_to_map(charge)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp get_charge_real(charge_id) do
    case Stripe.Charge.retrieve(charge_id, %{}, stripe_opts()) do
      {:ok, charge} -> {:ok, stripe_to_map(charge)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp create_payment_intent_real(params) do
    case Stripe.PaymentIntent.create(normalize_params(params), stripe_opts()) do
      {:ok, payment_intent} -> {:ok, stripe_to_map(payment_intent)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp get_payment_intent_real(payment_intent_id) do
    case Stripe.PaymentIntent.retrieve(payment_intent_id, %{}, stripe_opts()) do
      {:ok, payment_intent} -> {:ok, stripe_to_map(payment_intent)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp create_refund_real(params) do
    case Stripe.Refund.create(normalize_params(params), stripe_opts()) do
      {:ok, refund} -> {:ok, stripe_to_map(refund)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp get_refund_real(refund_id) do
    case Stripe.Refund.retrieve(refund_id, %{}, stripe_opts()) do
      {:ok, refund} -> {:ok, stripe_to_map(refund)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp create_checkout_session_real(params) do
    case Session.create(normalize_params(params), stripe_opts()) do
      {:ok, session} -> {:ok, stripe_to_map(session)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp get_checkout_session_real(session_id) do
    case Session.retrieve(session_id, %{}, stripe_opts()) do
      {:ok, session} -> {:ok, stripe_to_map(session)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp expire_checkout_session_real(session_id) do
    case Session.expire(session_id, %{}, stripe_opts()) do
      {:ok, session} -> {:ok, stripe_to_map(session)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  ## Private - PaperTiger Mock

  defp create_customer_mock(params) do
    conn = request(:post, "/v1/customers", params)
    handle_response(conn)
  end

  defp get_customer_mock(customer_id) do
    conn = request(:get, "/v1/customers/#{customer_id}", %{})
    handle_response(conn)
  end

  defp update_customer_mock(customer_id, params) do
    conn = request(:post, "/v1/customers/#{customer_id}", params)
    handle_response(conn)
  end

  defp delete_customer_mock(customer_id) do
    conn = request(:delete, "/v1/customers/#{customer_id}", %{})
    handle_response(conn)
  end

  defp list_customers_mock(params) do
    conn = request(:get, "/v1/customers", params)
    handle_response(conn)
  end

  defp create_subscription_mock(params) do
    conn = request(:post, "/v1/subscriptions", params)
    handle_response(conn)
  end

  defp get_subscription_mock(subscription_id) do
    conn = request(:get, "/v1/subscriptions/#{subscription_id}", %{})
    handle_response(conn)
  end

  defp update_subscription_mock(subscription_id, params) do
    conn = request(:post, "/v1/subscriptions/#{subscription_id}", params)
    handle_response(conn)
  end

  defp delete_subscription_mock(subscription_id) do
    conn = request(:delete, "/v1/subscriptions/#{subscription_id}", %{})
    handle_response(conn)
  end

  defp list_subscriptions_mock(params) do
    conn = request(:get, "/v1/subscriptions", params)
    handle_response(conn)
  end

  defp create_payment_method_mock(params) do
    conn = request(:post, "/v1/payment_methods", params)
    handle_response(conn)
  end

  defp get_payment_method_mock(payment_method_id) do
    conn = request(:get, "/v1/payment_methods/#{payment_method_id}", %{})
    handle_response(conn)
  end

  defp create_invoice_mock(params) do
    conn = request(:post, "/v1/invoices", params)
    handle_response(conn)
  end

  defp get_invoice_mock(invoice_id) do
    conn = request(:get, "/v1/invoices/#{invoice_id}", %{})
    handle_response(conn)
  end

  defp update_invoice_mock(invoice_id, params) do
    conn = request(:post, "/v1/invoices/#{invoice_id}", params)
    handle_response(conn)
  end

  defp finalize_invoice_mock(invoice_id) do
    conn = request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})
    handle_response(conn)
  end

  defp pay_invoice_mock(invoice_id) do
    conn = request(:post, "/v1/invoices/#{invoice_id}/pay", %{})
    handle_response(conn)
  end

  defp list_invoices_mock(params) do
    conn = request(:get, "/v1/invoices", params)
    handle_response(conn)
  end

  defp create_invoice_item_mock(params) do
    conn = request(:post, "/v1/invoiceitems", params)
    handle_response(conn)
  end

  defp get_invoice_item_mock(invoice_item_id) do
    conn = request(:get, "/v1/invoiceitems/#{invoice_item_id}", %{})
    handle_response(conn)
  end

  defp create_product_mock(params) do
    conn = request(:post, "/v1/products", params)
    handle_response(conn)
  end

  defp get_product_mock(product_id) do
    conn = request(:get, "/v1/products/#{product_id}", %{})
    handle_response(conn)
  end

  defp create_price_mock(params) do
    conn = request(:post, "/v1/prices", params)
    handle_response(conn)
  end

  defp get_price_mock(price_id) do
    conn = request(:get, "/v1/prices/#{price_id}", %{})
    handle_response(conn)
  end

  defp create_charge_mock(params) do
    conn = request(:post, "/v1/charges", params)
    handle_response(conn)
  end

  defp get_charge_mock(charge_id) do
    conn = request(:get, "/v1/charges/#{charge_id}", %{})
    handle_response(conn)
  end

  defp create_payment_intent_mock(params) do
    conn = request(:post, "/v1/payment_intents", params)
    handle_response(conn)
  end

  defp get_payment_intent_mock(payment_intent_id) do
    conn = request(:get, "/v1/payment_intents/#{payment_intent_id}", %{})
    handle_response(conn)
  end

  defp create_refund_mock(params) do
    conn = request(:post, "/v1/refunds", params)
    handle_response(conn)
  end

  defp get_refund_mock(refund_id) do
    conn = request(:get, "/v1/refunds/#{refund_id}", %{})
    handle_response(conn)
  end

  defp create_checkout_session_mock(params) do
    conn = request(:post, "/v1/checkout/sessions", params)
    handle_response(conn)
  end

  defp get_checkout_session_mock(session_id) do
    conn = request(:get, "/v1/checkout/sessions/#{session_id}", %{})
    handle_response(conn)
  end

  defp expire_checkout_session_mock(session_id) do
    conn = request(:post, "/v1/checkout/sessions/#{session_id}/expire", %{})
    handle_response(conn)
  end

  ## Helpers

  defp request(method, path, params) do
    conn = build_conn(method, path, params)
    Router.call(conn, [])
  end

  defp build_conn(method, path, params) do
    {final_path, body} =
      case method do
        m when m in [:get, :delete] ->
          if params && map_size(params) > 0 do
            query_string = params_to_form_data(params)
            {"#{path}?#{query_string}", ""}
          else
            {path, ""}
          end

        _ ->
          body = if params && map_size(params) > 0, do: params_to_form_data(params), else: ""
          {path, body}
      end

    conn = Plug.Test.conn(method, final_path, body)

    conn
    |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Plug.Conn.put_req_header("authorization", "Bearer sk_test_mock")
  end

  # Convert params to form data with bracket notation for nested structures
  defp params_to_form_data(params) do
    params
    |> flatten_params()
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{URI.encode_www_form(to_string(v))}" end)
  end

  # Flatten nested maps into bracket notation
  defp flatten_params(params, parent_key \\ "") do
    Enum.flat_map(params, fn
      {key, value} when is_map(value) ->
        new_key = if parent_key == "", do: key, else: "#{parent_key}[#{key}]"
        flatten_params(value, new_key)

      {key, value} when is_list(value) ->
        new_key = if parent_key == "", do: key, else: "#{parent_key}[#{key}]"
        flatten_list_params(value, new_key)

      {key, value} ->
        new_key = if parent_key == "", do: key, else: "#{parent_key}[#{key}]"
        [{new_key, value}]
    end)
  end

  defp flatten_list_params(list, parent_key) do
    list
    |> Enum.with_index(fn item, idx ->
      flatten_list_item(item, parent_key, idx)
    end)
    |> List.flatten()
  end

  defp flatten_list_item(item, parent_key, idx) when is_map(item) do
    flatten_params(item, "#{parent_key}[#{idx}]")
  end

  defp flatten_list_item(item, parent_key, _idx) do
    {"#{parent_key}[]", item}
  end

  defp handle_response(conn) do
    case conn.status do
      status when status in 200..299 ->
        {:ok, Jason.decode!(conn.resp_body)}

      _ ->
        {:error, Jason.decode!(conn.resp_body)}
    end
  end

  # Convert Stripe struct to plain map for consistency
  # Filter out nil values to match PaperTiger's leaner responses
  defp stripe_to_map(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Enum.reject(fn {_k, v} -> v == nil end)
    |> Map.new(fn {k, v} -> {to_string(k), normalize_value(v)} end)
  end

  defp stripe_to_map(map) when is_map(map), do: map
  defp stripe_to_map(other), do: other

  defp normalize_value(%_{} = struct), do: stripe_to_map(struct)
  defp normalize_value(list) when is_list(list), do: Enum.map(list, &normalize_value/1)
  defp normalize_value(map) when is_map(map), do: stripe_to_map(map)
  defp normalize_value(other), do: other

  defp stripe_error_to_map(%Stripe.Error{extra: extra} = error) when is_map(extra) do
    raw_error = Map.get(extra, :raw_error, %{})

    error_body = %{
      "message" => error.message,
      "type" => raw_error["type"] || to_string(Map.get(extra, :type, error.code))
    }

    code = raw_error["code"] || Map.get(extra, :card_code)
    error_body = if code, do: Map.put(error_body, "code", to_string(code)), else: error_body

    param = raw_error["param"] || Map.get(extra, :param)
    error_body = if param, do: Map.put(error_body, "param", to_string(param)), else: error_body

    %{"error" => error_body}
  end

  defp stripe_error_to_map(%Stripe.Error{} = error) do
    %{
      "error" => %{
        "code" => to_string(error.code),
        "message" => error.message,
        "type" => to_string(error.code)
      }
    }
  end

  defp stripe_error_to_map(other), do: other

  # Convert string keys to atoms for Stripity Stripe
  defp normalize_params(params) when is_map(params) do
    params
    |> Map.new(fn {k, v} -> {ensure_atom(k), normalize_param_value(v)} end)
  end

  defp normalize_param_value(map) when is_map(map), do: normalize_params(map)

  defp normalize_param_value(list) when is_list(list), do: Enum.map(list, &normalize_param_value/1)

  defp normalize_param_value(other), do: other

  defp ensure_atom(key) when is_atom(key), do: key
  defp ensure_atom(key) when is_binary(key), do: String.to_atom(key)
end
