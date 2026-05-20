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

  @forced_mode_key {__MODULE__, :forced_mode}
  @subscription_schedule_api_version "2025-11-17.clover"

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
    case Process.get(@forced_mode_key) do
      nil ->
        env_mode()

      mode when mode in [:paper_tiger, :real_stripe] ->
        mode
    end
  end

  @doc """
  Runs a function with `TestClient` forced to the given backend.

  This is primarily for drift tests that need to call both PaperTiger and real
  Stripe from the same ExUnit process. Forcing `:real_stripe` still validates the
  API key before any Stripe call is allowed.
  """
  def with_mode(mode, fun) when mode in [:paper_tiger, :real_stripe] and is_function(fun, 0) do
    if mode == :real_stripe do
      validate_test_mode_key!()
    end

    previous_mode = Process.get(@forced_mode_key, :unset)
    Process.put(@forced_mode_key, mode)

    try do
      fun.()
    after
      restore_forced_mode(previous_mode)
    end
  end

  defp env_mode do
    if System.get_env("VALIDATE_AGAINST_STRIPE") == "true" do
      validate_test_mode_key!()
      :real_stripe
    else
      :paper_tiger
    end
  end

  defp restore_forced_mode(:unset), do: Process.delete(@forced_mode_key)
  defp restore_forced_mode(previous_mode), do: Process.put(@forced_mode_key, previous_mode)

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

  @doc """
  Returns test card data for creating PaymentMethods against real Stripe API.

  Real Stripe API requires actual card number, exp, and cvc.
  This provides Stripe's standard test card number (4242...).
  """
  def test_card do
    %{
      "cvc" => "123",
      "exp_month" => 12,
      "exp_year" => 2030,
      "number" => "4242424242424242"
    }
  end

  @doc """
  Returns test card data in PaperTiger format (brand/last4 style).

  PaperTiger accepts a simplified card format for unit tests.
  """
  def test_card_simple do
    %{
      "brand" => "visa",
      "exp_month" => 12,
      "exp_year" => 2030,
      "last4" => "4242"
    }
  end

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

  @doc """
  Searches customers.
  """
  def search_customers(params \\ %{}) do
    case mode() do
      :real_stripe ->
        search_customers_real(params)

      :paper_tiger ->
        search_customers_mock(params)
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

  @doc """
  Lists products.
  """
  def list_products(params \\ %{}) do
    case mode() do
      :real_stripe ->
        list_products_real(params)

      :paper_tiger ->
        list_products_mock(params)
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

  @doc """
  Lists prices.
  """
  def list_prices(params \\ %{}) do
    case mode() do
      :real_stripe ->
        list_prices_real(params)

      :paper_tiger ->
        list_prices_mock(params)
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

  ## SubscriptionSchedule Operations

  @doc """
  Creates a subscription schedule.
  """
  def create_subscription_schedule(params) do
    case mode() do
      :real_stripe ->
        create_subscription_schedule_real(params)

      :paper_tiger ->
        create_subscription_schedule_mock(params)
    end
  end

  @doc """
  Retrieves a subscription schedule by ID.
  """
  def get_subscription_schedule(schedule_id) do
    case mode() do
      :real_stripe ->
        get_subscription_schedule_real(schedule_id)

      :paper_tiger ->
        get_subscription_schedule_mock(schedule_id)
    end
  end

  @doc """
  Updates a subscription schedule.
  """
  def update_subscription_schedule(schedule_id, params) do
    case mode() do
      :real_stripe ->
        update_subscription_schedule_real(schedule_id, params)

      :paper_tiger ->
        update_subscription_schedule_mock(schedule_id, params)
    end
  end

  @doc """
  Cancels a subscription schedule.
  """
  def cancel_subscription_schedule(schedule_id, params \\ %{}) do
    case mode() do
      :real_stripe ->
        cancel_subscription_schedule_real(schedule_id, params)

      :paper_tiger ->
        cancel_subscription_schedule_mock(schedule_id, params)
    end
  end

  @doc """
  Releases a subscription schedule.
  """
  def release_subscription_schedule(schedule_id, params \\ %{}) do
    case mode() do
      :real_stripe ->
        release_subscription_schedule_real(schedule_id, params)

      :paper_tiger ->
        release_subscription_schedule_mock(schedule_id, params)
    end
  end

  @doc """
  Lists subscription schedules.
  """
  def list_subscription_schedules(params \\ %{}) do
    case mode() do
      :real_stripe ->
        list_subscription_schedules_real(params)

      :paper_tiger ->
        list_subscription_schedules_mock(params)
    end
  end

  @doc """
  Searches subscriptions.
  """
  def search_subscriptions(params \\ %{}) do
    case mode() do
      :real_stripe ->
        search_subscriptions_real(params)

      :paper_tiger ->
        search_subscriptions_mock(params)
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

  @doc """
  Lists payment methods for a customer.

  Requires a customer parameter.
  """
  def list_payment_methods(params) do
    case mode() do
      :real_stripe ->
        list_payment_methods_real(params)

      :paper_tiger ->
        list_payment_methods_mock(params)
    end
  end

  @doc """
  Attaches a payment method to a customer.
  """
  def attach_payment_method(payment_method_id, params) do
    case mode() do
      :real_stripe ->
        attach_payment_method_real(payment_method_id, params)

      :paper_tiger ->
        attach_payment_method_mock(payment_method_id, params)
    end
  end

  @doc """
  Creates a test ConfirmationToken.
  """
  def create_confirmation_token(params \\ %{}) do
    case mode() do
      :real_stripe ->
        create_confirmation_token_real(params)

      :paper_tiger ->
        create_confirmation_token_mock(params)
    end
  end

  @doc """
  Retrieves a ConfirmationToken by ID.
  """
  def get_confirmation_token(confirmation_token_id) do
    case mode() do
      :real_stripe ->
        get_confirmation_token_real(confirmation_token_id)

      :paper_tiger ->
        get_confirmation_token_mock(confirmation_token_id)
    end
  end

  @doc """
  Creates a Customer Session.
  """
  def create_customer_session(params) do
    case mode() do
      :real_stripe ->
        create_customer_session_real(params)

      :paper_tiger ->
        create_customer_session_mock(params)
    end
  end

  @doc """
  Creates a payment method domain.
  """
  def create_payment_method_domain(params) do
    case mode() do
      :real_stripe ->
        create_payment_method_domain_real(params)

      :paper_tiger ->
        create_payment_method_domain_mock(params)
    end
  end

  @doc """
  Retrieves a payment method domain by ID.
  """
  def get_payment_method_domain(payment_method_domain_id) do
    case mode() do
      :real_stripe ->
        get_payment_method_domain_real(payment_method_domain_id)

      :paper_tiger ->
        get_payment_method_domain_mock(payment_method_domain_id)
    end
  end

  @doc """
  Updates a payment method domain.
  """
  def update_payment_method_domain(payment_method_domain_id, params) do
    case mode() do
      :real_stripe ->
        update_payment_method_domain_real(payment_method_domain_id, params)

      :paper_tiger ->
        update_payment_method_domain_mock(payment_method_domain_id, params)
    end
  end

  @doc """
  Lists payment method domains.
  """
  def list_payment_method_domains(params \\ %{}) do
    case mode() do
      :real_stripe ->
        list_payment_method_domains_real(params)

      :paper_tiger ->
        list_payment_method_domains_mock(params)
    end
  end

  @doc """
  Creates a payment method configuration.
  """
  def create_payment_method_configuration(params) do
    case mode() do
      :real_stripe ->
        create_payment_method_configuration_real(params)

      :paper_tiger ->
        create_payment_method_configuration_mock(params)
    end
  end

  @doc """
  Retrieves a payment method configuration by ID.
  """
  def get_payment_method_configuration(payment_method_configuration_id) do
    case mode() do
      :real_stripe ->
        get_payment_method_configuration_real(payment_method_configuration_id)

      :paper_tiger ->
        get_payment_method_configuration_mock(payment_method_configuration_id)
    end
  end

  @doc """
  Updates a payment method configuration.
  """
  def update_payment_method_configuration(payment_method_configuration_id, params) do
    case mode() do
      :real_stripe ->
        update_payment_method_configuration_real(payment_method_configuration_id, params)

      :paper_tiger ->
        update_payment_method_configuration_mock(payment_method_configuration_id, params)
    end
  end

  @doc """
  Lists payment method configurations.
  """
  def list_payment_method_configurations(params \\ %{}) do
    case mode() do
      :real_stripe ->
        list_payment_method_configurations_real(params)

      :paper_tiger ->
        list_payment_method_configurations_mock(params)
    end
  end

  @doc """
  Retrieves a mandate by ID.
  """
  def get_mandate(mandate_id) do
    case mode() do
      :real_stripe ->
        get_mandate_real(mandate_id)

      :paper_tiger ->
        get_mandate_mock(mandate_id)
    end
  end

  ## SetupIntent Operations

  @doc """
  Creates a setup intent.
  """
  def create_setup_intent(params \\ %{}) do
    case mode() do
      :real_stripe ->
        create_setup_intent_real(params)

      :paper_tiger ->
        create_setup_intent_mock(params)
    end
  end

  @doc """
  Retrieves a setup intent by ID.
  """
  def get_setup_intent(setup_intent_id) do
    case mode() do
      :real_stripe ->
        get_setup_intent_real(setup_intent_id)

      :paper_tiger ->
        get_setup_intent_mock(setup_intent_id)
    end
  end

  @doc """
  Confirms a setup intent.
  """
  def confirm_setup_intent(setup_intent_id, params \\ %{}) do
    case mode() do
      :real_stripe ->
        confirm_setup_intent_real(setup_intent_id, params)

      :paper_tiger ->
        confirm_setup_intent_mock(setup_intent_id, params)
    end
  end

  @doc """
  Cancels a setup intent.
  """
  def cancel_setup_intent(setup_intent_id, params \\ %{}) do
    case mode() do
      :real_stripe ->
        cancel_setup_intent_real(setup_intent_id, params)

      :paper_tiger ->
        cancel_setup_intent_mock(setup_intent_id, params)
    end
  end

  @doc """
  Verifies setup intent microdeposits.
  """
  def verify_setup_intent_microdeposits(setup_intent_id, params \\ %{}) do
    case mode() do
      :real_stripe ->
        verify_setup_intent_microdeposits_real(setup_intent_id, params)

      :paper_tiger ->
        verify_setup_intent_microdeposits_mock(setup_intent_id, params)
    end
  end

  @doc """
  Lists setup attempts.
  """
  def list_setup_attempts(params \\ %{}) do
    case mode() do
      :real_stripe ->
        list_setup_attempts_real(params)

      :paper_tiger ->
        list_setup_attempts_mock(params)
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

  @doc """
  Searches charges.
  """
  def search_charges(params \\ %{}) do
    case mode() do
      :real_stripe ->
        search_charges_real(params)

      :paper_tiger ->
        search_charges_mock(params)
    end
  end

  ## BalanceTransaction Operations

  @doc """
  Retrieves a balance transaction by ID.
  """
  def get_balance_transaction(txn_id) do
    case mode() do
      :real_stripe ->
        get_balance_transaction_real(txn_id)

      :paper_tiger ->
        get_balance_transaction_mock(txn_id)
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

  @doc """
  Confirms a payment intent.
  """
  def confirm_payment_intent(payment_intent_id, params \\ %{}) do
    case mode() do
      :real_stripe ->
        confirm_payment_intent_real(payment_intent_id, params)

      :paper_tiger ->
        confirm_payment_intent_mock(payment_intent_id, params)
    end
  end

  @doc """
  Cancels a payment intent.
  """
  def cancel_payment_intent(payment_intent_id, params \\ %{}) do
    case mode() do
      :real_stripe ->
        cancel_payment_intent_real(payment_intent_id, params)

      :paper_tiger ->
        cancel_payment_intent_mock(payment_intent_id, params)
    end
  end

  @doc """
  Captures a manual-capture payment intent.
  """
  def capture_payment_intent(payment_intent_id, params \\ %{}) do
    case mode() do
      :real_stripe ->
        capture_payment_intent_real(payment_intent_id, params)

      :paper_tiger ->
        capture_payment_intent_mock(payment_intent_id, params)
    end
  end

  @doc """
  Searches payment intents.
  """
  def search_payment_intents(params \\ %{}) do
    case mode() do
      :real_stripe ->
        search_payment_intents_real(params)

      :paper_tiger ->
        search_payment_intents_mock(params)
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

  @doc """
  Lists refunds.
  """
  def list_refunds(params \\ %{}) do
    case mode() do
      :real_stripe ->
        list_refunds_real(params)

      :paper_tiger ->
        list_refunds_mock(params)
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
  Updates a checkout session.
  """
  def update_checkout_session(session_id, params) do
    case mode() do
      :real_stripe ->
        update_checkout_session_real(session_id, params)

      :paper_tiger ->
        update_checkout_session_mock(session_id, params)
    end
  end

  @doc """
  Lists checkout session line items.
  """
  def list_checkout_session_line_items(session_id, params \\ %{}) do
    case mode() do
      :real_stripe ->
        list_checkout_session_line_items_real(session_id, params)

      :paper_tiger ->
        list_checkout_session_line_items_mock(session_id, params)
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

  ## Payment Link Operations

  @doc """
  Creates a Payment Link.
  """
  def create_payment_link(params) do
    case mode() do
      :real_stripe ->
        create_payment_link_real(params)

      :paper_tiger ->
        create_payment_link_mock(params)
    end
  end

  @doc """
  Retrieves a Payment Link.
  """
  def get_payment_link(payment_link_id) do
    case mode() do
      :real_stripe ->
        get_payment_link_real(payment_link_id)

      :paper_tiger ->
        get_payment_link_mock(payment_link_id)
    end
  end

  @doc """
  Updates a Payment Link.
  """
  def update_payment_link(payment_link_id, params) do
    case mode() do
      :real_stripe ->
        update_payment_link_real(payment_link_id, params)

      :paper_tiger ->
        update_payment_link_mock(payment_link_id, params)
    end
  end

  @doc """
  Lists Payment Links.
  """
  def list_payment_links(params \\ %{}) do
    case mode() do
      :real_stripe ->
        list_payment_links_real(params)

      :paper_tiger ->
        list_payment_links_mock(params)
    end
  end

  @doc """
  Lists Payment Link line items.
  """
  def list_payment_link_line_items(payment_link_id, params \\ %{}) do
    case mode() do
      :real_stripe ->
        list_payment_link_line_items_real(payment_link_id, params)

      :paper_tiger ->
        list_payment_link_line_items_mock(payment_link_id, params)
    end
  end

  ## Coupon and Promotion Code Operations

  @doc """
  Creates a coupon.
  """
  def create_coupon(params) do
    case mode() do
      :real_stripe ->
        create_coupon_real(params)

      :paper_tiger ->
        create_coupon_mock(params)
    end
  end

  @doc """
  Creates a Promotion Code.
  """
  def create_promotion_code(params) do
    case mode() do
      :real_stripe ->
        create_promotion_code_real(params)

      :paper_tiger ->
        create_promotion_code_mock(params)
    end
  end

  @doc """
  Retrieves a Promotion Code.
  """
  def get_promotion_code(promotion_code_id) do
    case mode() do
      :real_stripe ->
        get_promotion_code_real(promotion_code_id)

      :paper_tiger ->
        get_promotion_code_mock(promotion_code_id)
    end
  end

  @doc """
  Updates a Promotion Code.
  """
  def update_promotion_code(promotion_code_id, params) do
    case mode() do
      :real_stripe ->
        update_promotion_code_real(promotion_code_id, params)

      :paper_tiger ->
        update_promotion_code_mock(promotion_code_id, params)
    end
  end

  @doc """
  Lists Promotion Codes.
  """
  def list_promotion_codes(params \\ %{}) do
    case mode() do
      :real_stripe ->
        list_promotion_codes_real(params)

      :paper_tiger ->
        list_promotion_codes_mock(params)
    end
  end

  ## Billing Portal Operations

  @doc """
  Creates a Billing Portal Configuration.
  """
  def create_billing_portal_configuration(params \\ %{}) do
    case mode() do
      :real_stripe ->
        create_billing_portal_configuration_real(params)

      :paper_tiger ->
        create_billing_portal_configuration_mock(params)
    end
  end

  @doc """
  Retrieves a Billing Portal Configuration.
  """
  def get_billing_portal_configuration(configuration_id) do
    case mode() do
      :real_stripe ->
        get_billing_portal_configuration_real(configuration_id)

      :paper_tiger ->
        get_billing_portal_configuration_mock(configuration_id)
    end
  end

  @doc """
  Updates a Billing Portal Configuration.
  """
  def update_billing_portal_configuration(configuration_id, params) do
    case mode() do
      :real_stripe ->
        update_billing_portal_configuration_real(configuration_id, params)

      :paper_tiger ->
        update_billing_portal_configuration_mock(configuration_id, params)
    end
  end

  @doc """
  Lists Billing Portal Configurations.
  """
  def list_billing_portal_configurations(params \\ %{}) do
    case mode() do
      :real_stripe ->
        list_billing_portal_configurations_real(params)

      :paper_tiger ->
        list_billing_portal_configurations_mock(params)
    end
  end

  @doc """
  Creates a Billing Portal Session.
  """
  def create_billing_portal_session(params) do
    case mode() do
      :real_stripe ->
        create_billing_portal_session_real(params)

      :paper_tiger ->
        create_billing_portal_session_mock(params)
    end
  end

  ## Customer Balance and Credit Operations

  @doc """
  Creates a customer balance transaction.
  """
  def create_customer_balance_transaction(customer_id, params) do
    case mode() do
      :real_stripe ->
        create_customer_balance_transaction_real(customer_id, params)

      :paper_tiger ->
        create_customer_balance_transaction_mock(customer_id, params)
    end
  end

  @doc """
  Retrieves a customer balance transaction.
  """
  def get_customer_balance_transaction(customer_id, transaction_id) do
    case mode() do
      :real_stripe ->
        get_customer_balance_transaction_real(customer_id, transaction_id)

      :paper_tiger ->
        get_customer_balance_transaction_mock(customer_id, transaction_id)
    end
  end

  @doc """
  Lists customer balance transactions.
  """
  def list_customer_balance_transactions(customer_id, params \\ %{}) do
    case mode() do
      :real_stripe ->
        list_customer_balance_transactions_real(customer_id, params)

      :paper_tiger ->
        list_customer_balance_transactions_mock(customer_id, params)
    end
  end

  @doc """
  Retrieves a customer's cash balance.
  """
  def get_cash_balance(customer_id) do
    case mode() do
      :real_stripe ->
        get_cash_balance_real(customer_id)

      :paper_tiger ->
        get_cash_balance_mock(customer_id)
    end
  end

  @doc """
  Updates a customer's cash balance settings.
  """
  def update_cash_balance(customer_id, params) do
    case mode() do
      :real_stripe ->
        update_cash_balance_real(customer_id, params)

      :paper_tiger ->
        update_cash_balance_mock(customer_id, params)
    end
  end

  @doc """
  Creates a credit note.
  """
  def create_credit_note(params) do
    case mode() do
      :real_stripe ->
        create_credit_note_real(params)

      :paper_tiger ->
        create_credit_note_mock(params)
    end
  end

  ## Connect Operations

  def create_account(params) do
    case mode() do
      :real_stripe -> create_account_real(params)
      :paper_tiger -> create_account_mock(params)
    end
  end

  def get_account(account_id) do
    case mode() do
      :real_stripe -> get_account_real(account_id)
      :paper_tiger -> get_account_mock(account_id)
    end
  end

  def update_account(account_id, params) do
    case mode() do
      :real_stripe -> update_account_real(account_id, params)
      :paper_tiger -> update_account_mock(account_id, params)
    end
  end

  def delete_account(account_id) do
    case mode() do
      :real_stripe -> delete_account_real(account_id)
      :paper_tiger -> delete_account_mock(account_id)
    end
  end

  def list_accounts(params \\ %{}) do
    case mode() do
      :real_stripe -> list_accounts_real(params)
      :paper_tiger -> list_accounts_mock(params)
    end
  end

  def create_account_link(params) do
    case mode() do
      :real_stripe -> create_account_link_real(params)
      :paper_tiger -> create_account_link_mock(params)
    end
  end

  def create_transfer(params) do
    case mode() do
      :real_stripe -> create_transfer_real(params)
      :paper_tiger -> create_transfer_mock(params)
    end
  end

  def get_transfer(transfer_id) do
    case mode() do
      :real_stripe -> get_transfer_real(transfer_id)
      :paper_tiger -> get_transfer_mock(transfer_id)
    end
  end

  def create_transfer_reversal(transfer_id, params \\ %{}) do
    case mode() do
      :real_stripe -> create_transfer_reversal_real(transfer_id, params)
      :paper_tiger -> create_transfer_reversal_mock(transfer_id, params)
    end
  end

  def list_transfer_reversals(transfer_id, params \\ %{}) do
    case mode() do
      :real_stripe -> list_transfer_reversals_real(transfer_id, params)
      :paper_tiger -> list_transfer_reversals_mock(transfer_id, params)
    end
  end

  def get_application_fee(fee_id) do
    case mode() do
      :real_stripe -> get_application_fee_real(fee_id)
      :paper_tiger -> get_application_fee_mock(fee_id)
    end
  end

  def create_application_fee_refund(fee_id, params \\ %{}) do
    case mode() do
      :real_stripe -> create_application_fee_refund_real(fee_id, params)
      :paper_tiger -> create_application_fee_refund_mock(fee_id, params)
    end
  end

  def list_application_fee_refunds(fee_id, params \\ %{}) do
    case mode() do
      :real_stripe -> list_application_fee_refunds_real(fee_id, params)
      :paper_tiger -> list_application_fee_refunds_mock(fee_id, params)
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
  Sends an invoice to the customer.
  """
  def send_invoice(invoice_id) do
    case mode() do
      :real_stripe ->
        send_invoice_real(invoice_id)

      :paper_tiger ->
        send_invoice_mock(invoice_id)
    end
  end

  @doc """
  Marks an invoice as uncollectible.
  """
  def mark_invoice_uncollectible(invoice_id) do
    case mode() do
      :real_stripe ->
        mark_invoice_uncollectible_real(invoice_id)

      :paper_tiger ->
        mark_invoice_uncollectible_mock(invoice_id)
    end
  end

  @doc """
  Attaches a payment to an invoice.
  """
  def attach_invoice_payment(invoice_id, params) do
    case mode() do
      :real_stripe ->
        attach_invoice_payment_real(invoice_id, params)

      :paper_tiger ->
        attach_invoice_payment_mock(invoice_id, params)
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

  @doc """
  Searches invoices.
  """
  def search_invoices(params \\ %{}) do
    case mode() do
      :real_stripe ->
        search_invoices_real(params)

      :paper_tiger ->
        search_invoices_mock(params)
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

  defp stripe_request(method, path, params \\ %{}, opts \\ []) do
    url = stripe_request_url(method, path, params)

    headers =
      [
        {"authorization", "Bearer #{System.get_env("STRIPE_API_KEY")}"},
        {"content-type", "application/x-www-form-urlencoded"}
      ]
      |> maybe_put_stripe_version(Keyword.get(opts, :api_version))

    req_opts =
      case method do
        :get ->
          [headers: headers]

        :delete ->
          [headers: headers]

        :post ->
          [
            body: params_to_form_data(params),
            headers: headers
          ]
      end

    case apply(Req, method, [url, req_opts]) do
      {:ok, %{body: body, status: status}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{body: body}} ->
        {:error, body}

      {:error, reason} ->
        {:error,
         %{
           "error" => %{
             "message" => "An error occurred while making the network request. Reason: #{inspect(reason)}",
             "type" => "network_error"
           }
         }}
    end
  end

  defp stripe_request_url(method, path, params) when method in [:get, :delete] do
    url = "https://api.stripe.com#{path}"

    if params && map_size(params) > 0 do
      "#{url}?#{params_to_form_data(params)}"
    else
      url
    end
  end

  defp stripe_request_url(_method, path, _params), do: "https://api.stripe.com#{path}"

  defp maybe_put_stripe_version(headers, nil), do: headers
  defp maybe_put_stripe_version(headers, api_version), do: [{"stripe-version", api_version} | headers]

  defp create_customer_real(params) do
    stripe_request(:post, "/v1/customers", params)
  end

  defp get_customer_real(customer_id) do
    stripe_request(:get, "/v1/customers/#{customer_id}")
  end

  defp update_customer_real(customer_id, params) do
    stripe_request(:post, "/v1/customers/#{customer_id}", params)
  end

  defp delete_customer_real(customer_id) do
    stripe_request(:delete, "/v1/customers/#{customer_id}")
  end

  defp list_customers_real(params) do
    stripe_request(:get, "/v1/customers", params)
  end

  defp search_customers_real(params) do
    stripe_request(:get, "/v1/customers/search", params)
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

  defp search_subscriptions_real(params) do
    stripe_request(:get, "/v1/subscriptions/search", params)
  end

  defp create_subscription_schedule_real(params) do
    stripe_request(:post, "/v1/subscription_schedules", params, api_version: @subscription_schedule_api_version)
  end

  defp get_subscription_schedule_real(schedule_id) do
    stripe_request(:get, "/v1/subscription_schedules/#{schedule_id}", %{},
      api_version: @subscription_schedule_api_version
    )
  end

  defp update_subscription_schedule_real(schedule_id, params) do
    stripe_request(:post, "/v1/subscription_schedules/#{schedule_id}", params,
      api_version: @subscription_schedule_api_version
    )
  end

  defp cancel_subscription_schedule_real(schedule_id, params) do
    stripe_request(:post, "/v1/subscription_schedules/#{schedule_id}/cancel", params,
      api_version: @subscription_schedule_api_version
    )
  end

  defp release_subscription_schedule_real(schedule_id, params) do
    stripe_request(:post, "/v1/subscription_schedules/#{schedule_id}/release", params,
      api_version: @subscription_schedule_api_version
    )
  end

  defp list_subscription_schedules_real(params) do
    stripe_request(:get, "/v1/subscription_schedules", params, api_version: @subscription_schedule_api_version)
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

  defp list_payment_methods_real(params) do
    case Stripe.PaymentMethod.list(normalize_params(params), stripe_opts()) do
      {:ok, %{data: payment_methods, has_more: has_more}} ->
        {:ok, %{"data" => Enum.map(payment_methods, &stripe_to_map/1), "has_more" => has_more, "object" => "list"}}

      {:error, error} ->
        {:error, stripe_error_to_map(error)}
    end
  end

  defp attach_payment_method_real(payment_method_id, params) do
    case Stripe.PaymentMethod.attach(payment_method_id, normalize_params(params), stripe_opts()) do
      {:ok, payment_method} -> {:ok, stripe_to_map(payment_method)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp create_confirmation_token_real(params) do
    stripe_request(:post, "/v1/test_helpers/confirmation_tokens", params)
  end

  defp get_confirmation_token_real(confirmation_token_id) do
    stripe_request(:get, "/v1/confirmation_tokens/#{confirmation_token_id}")
  end

  defp create_customer_session_real(params) do
    stripe_request(:post, "/v1/customer_sessions", params)
  end

  defp create_payment_method_domain_real(params) do
    stripe_request(:post, "/v1/payment_method_domains", params)
  end

  defp get_payment_method_domain_real(payment_method_domain_id) do
    stripe_request(:get, "/v1/payment_method_domains/#{payment_method_domain_id}")
  end

  defp update_payment_method_domain_real(payment_method_domain_id, params) do
    stripe_request(:post, "/v1/payment_method_domains/#{payment_method_domain_id}", params)
  end

  defp list_payment_method_domains_real(params) do
    stripe_request(:get, "/v1/payment_method_domains", params)
  end

  defp create_payment_method_configuration_real(params) do
    stripe_request(:post, "/v1/payment_method_configurations", params)
  end

  defp get_payment_method_configuration_real(payment_method_configuration_id) do
    stripe_request(:get, "/v1/payment_method_configurations/#{payment_method_configuration_id}")
  end

  defp update_payment_method_configuration_real(payment_method_configuration_id, params) do
    stripe_request(:post, "/v1/payment_method_configurations/#{payment_method_configuration_id}", params)
  end

  defp list_payment_method_configurations_real(params) do
    stripe_request(:get, "/v1/payment_method_configurations", params)
  end

  defp get_mandate_real(mandate_id) do
    stripe_request(:get, "/v1/mandates/#{mandate_id}")
  end

  defp create_invoice_real(params) do
    stripe_request(:post, "/v1/invoices", params)
  end

  defp get_invoice_real(invoice_id) do
    stripe_request(:get, "/v1/invoices/#{invoice_id}")
  end

  defp update_invoice_real(invoice_id, params) do
    stripe_request(:post, "/v1/invoices/#{invoice_id}", params)
  end

  defp finalize_invoice_real(invoice_id) do
    stripe_request(:post, "/v1/invoices/#{invoice_id}/finalize")
  end

  defp pay_invoice_real(invoice_id) do
    stripe_request(:post, "/v1/invoices/#{invoice_id}/pay")
  end

  defp send_invoice_real(invoice_id) do
    stripe_request(:post, "/v1/invoices/#{invoice_id}/send")
  end

  defp mark_invoice_uncollectible_real(invoice_id) do
    stripe_request(:post, "/v1/invoices/#{invoice_id}/mark_uncollectible")
  end

  defp attach_invoice_payment_real(invoice_id, params) do
    stripe_request(:post, "/v1/invoices/#{invoice_id}/attach_payment", params)
  end

  defp list_invoices_real(params) do
    stripe_request(:get, "/v1/invoices", params)
  end

  defp search_invoices_real(params) do
    stripe_request(:get, "/v1/invoices/search", params)
  end

  defp create_invoice_item_real(params) do
    stripe_request(:post, "/v1/invoiceitems", params)
  end

  defp get_invoice_item_real(invoice_item_id) do
    stripe_request(:get, "/v1/invoiceitems/#{invoice_item_id}")
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

  defp list_products_real(params) do
    stripe_request(:get, "/v1/products", params)
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

  defp list_prices_real(params) do
    stripe_request(:get, "/v1/prices", params)
  end

  defp create_charge_real(params) do
    case Stripe.Charge.create(normalize_params(params), stripe_opts()) do
      {:ok, charge} -> {:ok, stripe_to_map(charge)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp get_charge_real(charge_id) do
    stripe_request(:get, "/v1/charges/#{charge_id}")
  end

  defp search_charges_real(params) do
    stripe_request(:get, "/v1/charges/search", params)
  end

  defp create_payment_intent_real(params) do
    stripe_request(:post, "/v1/payment_intents", params)
  end

  defp get_payment_intent_real(payment_intent_id) do
    stripe_request(:get, "/v1/payment_intents/#{payment_intent_id}")
  end

  defp confirm_payment_intent_real(payment_intent_id, params) do
    stripe_request(:post, "/v1/payment_intents/#{payment_intent_id}/confirm", params)
  end

  defp cancel_payment_intent_real(payment_intent_id, params) do
    stripe_request(:post, "/v1/payment_intents/#{payment_intent_id}/cancel", params)
  end

  defp capture_payment_intent_real(payment_intent_id, params) do
    stripe_request(:post, "/v1/payment_intents/#{payment_intent_id}/capture", params)
  end

  defp search_payment_intents_real(params) do
    stripe_request(:get, "/v1/payment_intents/search", params)
  end

  defp create_setup_intent_real(params) do
    stripe_request(:post, "/v1/setup_intents", params)
  end

  defp get_setup_intent_real(setup_intent_id) do
    stripe_request(:get, "/v1/setup_intents/#{setup_intent_id}")
  end

  defp confirm_setup_intent_real(setup_intent_id, params) do
    stripe_request(:post, "/v1/setup_intents/#{setup_intent_id}/confirm", params)
  end

  defp cancel_setup_intent_real(setup_intent_id, params) do
    stripe_request(:post, "/v1/setup_intents/#{setup_intent_id}/cancel", params)
  end

  defp verify_setup_intent_microdeposits_real(setup_intent_id, params) do
    stripe_request(:post, "/v1/setup_intents/#{setup_intent_id}/verify_microdeposits", params)
  end

  defp list_setup_attempts_real(params) do
    stripe_request(:get, "/v1/setup_attempts", params)
  end

  defp get_balance_transaction_real(txn_id) do
    stripe_request(:get, "/v1/balance_transactions/#{txn_id}")
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

  defp list_refunds_real(params) do
    stripe_request(:get, "/v1/refunds", params)
  end

  defp create_checkout_session_real(params) do
    stripe_request(:post, "/v1/checkout/sessions", params)
  end

  defp get_checkout_session_real(session_id) do
    stripe_request(:get, "/v1/checkout/sessions/#{session_id}")
  end

  defp update_checkout_session_real(session_id, params) do
    stripe_request(:post, "/v1/checkout/sessions/#{session_id}", params)
  end

  defp list_checkout_session_line_items_real(session_id, params) do
    stripe_request(:get, "/v1/checkout/sessions/#{session_id}/line_items", params)
  end

  defp expire_checkout_session_real(session_id) do
    stripe_request(:post, "/v1/checkout/sessions/#{session_id}/expire")
  end

  defp create_payment_link_real(params) do
    stripe_request(:post, "/v1/payment_links", params)
  end

  defp get_payment_link_real(payment_link_id) do
    stripe_request(:get, "/v1/payment_links/#{payment_link_id}")
  end

  defp update_payment_link_real(payment_link_id, params) do
    stripe_request(:post, "/v1/payment_links/#{payment_link_id}", params)
  end

  defp list_payment_links_real(params) do
    stripe_request(:get, "/v1/payment_links", params)
  end

  defp list_payment_link_line_items_real(payment_link_id, params) do
    stripe_request(:get, "/v1/payment_links/#{payment_link_id}/line_items", params)
  end

  defp create_coupon_real(params) do
    stripe_request(:post, "/v1/coupons", params)
  end

  defp create_promotion_code_real(params) do
    stripe_request(:post, "/v1/promotion_codes", params)
  end

  defp get_promotion_code_real(promotion_code_id) do
    stripe_request(:get, "/v1/promotion_codes/#{promotion_code_id}")
  end

  defp update_promotion_code_real(promotion_code_id, params) do
    stripe_request(:post, "/v1/promotion_codes/#{promotion_code_id}", params)
  end

  defp list_promotion_codes_real(params) do
    stripe_request(:get, "/v1/promotion_codes", params)
  end

  defp create_billing_portal_configuration_real(params) do
    stripe_request(:post, "/v1/billing_portal/configurations", params)
  end

  defp get_billing_portal_configuration_real(configuration_id) do
    stripe_request(:get, "/v1/billing_portal/configurations/#{configuration_id}")
  end

  defp update_billing_portal_configuration_real(configuration_id, params) do
    stripe_request(:post, "/v1/billing_portal/configurations/#{configuration_id}", params)
  end

  defp list_billing_portal_configurations_real(params) do
    stripe_request(:get, "/v1/billing_portal/configurations", params)
  end

  defp create_billing_portal_session_real(params) do
    stripe_request(:post, "/v1/billing_portal/sessions", params)
  end

  defp create_customer_balance_transaction_real(customer_id, params) do
    stripe_request(:post, "/v1/customers/#{customer_id}/balance_transactions", params)
  end

  defp get_customer_balance_transaction_real(customer_id, transaction_id) do
    stripe_request(:get, "/v1/customers/#{customer_id}/balance_transactions/#{transaction_id}")
  end

  defp list_customer_balance_transactions_real(customer_id, params) do
    stripe_request(:get, "/v1/customers/#{customer_id}/balance_transactions", params)
  end

  defp get_cash_balance_real(customer_id) do
    stripe_request(:get, "/v1/customers/#{customer_id}/cash_balance")
  end

  defp update_cash_balance_real(customer_id, params) do
    stripe_request(:post, "/v1/customers/#{customer_id}/cash_balance", params)
  end

  defp create_credit_note_real(params) do
    stripe_request(:post, "/v1/credit_notes", params)
  end

  defp create_account_real(params) do
    stripe_request(:post, "/v1/accounts", params)
  end

  defp get_account_real(account_id) do
    stripe_request(:get, "/v1/accounts/#{account_id}")
  end

  defp update_account_real(account_id, params) do
    stripe_request(:post, "/v1/accounts/#{account_id}", params)
  end

  defp delete_account_real(account_id) do
    stripe_request(:delete, "/v1/accounts/#{account_id}")
  end

  defp list_accounts_real(params) do
    stripe_request(:get, "/v1/accounts", params)
  end

  defp create_account_link_real(params) do
    stripe_request(:post, "/v1/account_links", params)
  end

  defp create_transfer_real(params) do
    stripe_request(:post, "/v1/transfers", params)
  end

  defp get_transfer_real(transfer_id) do
    stripe_request(:get, "/v1/transfers/#{transfer_id}")
  end

  defp create_transfer_reversal_real(transfer_id, params) do
    stripe_request(:post, "/v1/transfers/#{transfer_id}/reversals", params)
  end

  defp list_transfer_reversals_real(transfer_id, params) do
    stripe_request(:get, "/v1/transfers/#{transfer_id}/reversals", params)
  end

  defp get_application_fee_real(fee_id) do
    stripe_request(:get, "/v1/application_fees/#{fee_id}")
  end

  defp create_application_fee_refund_real(fee_id, params) do
    stripe_request(:post, "/v1/application_fees/#{fee_id}/refunds", params)
  end

  defp list_application_fee_refunds_real(fee_id, params) do
    stripe_request(:get, "/v1/application_fees/#{fee_id}/refunds", params)
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

  defp search_customers_mock(params) do
    conn = request(:get, "/v1/customers/search", params)
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

  defp search_subscriptions_mock(params) do
    conn = request(:get, "/v1/subscriptions/search", params)
    handle_response(conn)
  end

  defp create_subscription_schedule_mock(params) do
    conn = request(:post, "/v1/subscription_schedules", params)
    handle_response(conn)
  end

  defp get_subscription_schedule_mock(schedule_id) do
    conn = request(:get, "/v1/subscription_schedules/#{schedule_id}", %{})
    handle_response(conn)
  end

  defp update_subscription_schedule_mock(schedule_id, params) do
    conn = request(:post, "/v1/subscription_schedules/#{schedule_id}", params)
    handle_response(conn)
  end

  defp cancel_subscription_schedule_mock(schedule_id, params) do
    conn = request(:post, "/v1/subscription_schedules/#{schedule_id}/cancel", params)
    handle_response(conn)
  end

  defp release_subscription_schedule_mock(schedule_id, params) do
    conn = request(:post, "/v1/subscription_schedules/#{schedule_id}/release", params)
    handle_response(conn)
  end

  defp list_subscription_schedules_mock(params) do
    conn = request(:get, "/v1/subscription_schedules", params)
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

  defp list_payment_methods_mock(params) do
    conn = request(:get, "/v1/payment_methods", params)
    handle_response(conn)
  end

  defp attach_payment_method_mock(payment_method_id, params) do
    conn = request(:post, "/v1/payment_methods/#{payment_method_id}/attach", params)
    handle_response(conn)
  end

  defp create_confirmation_token_mock(params) do
    conn = request(:post, "/v1/test_helpers/confirmation_tokens", params)
    handle_response(conn)
  end

  defp get_confirmation_token_mock(confirmation_token_id) do
    conn = request(:get, "/v1/confirmation_tokens/#{confirmation_token_id}", %{})
    handle_response(conn)
  end

  defp create_customer_session_mock(params) do
    conn = request(:post, "/v1/customer_sessions", params)
    handle_response(conn)
  end

  defp create_payment_method_domain_mock(params) do
    conn = request(:post, "/v1/payment_method_domains", params)
    handle_response(conn)
  end

  defp get_payment_method_domain_mock(payment_method_domain_id) do
    conn = request(:get, "/v1/payment_method_domains/#{payment_method_domain_id}", %{})
    handle_response(conn)
  end

  defp update_payment_method_domain_mock(payment_method_domain_id, params) do
    conn = request(:post, "/v1/payment_method_domains/#{payment_method_domain_id}", params)
    handle_response(conn)
  end

  defp list_payment_method_domains_mock(params) do
    conn = request(:get, "/v1/payment_method_domains", params)
    handle_response(conn)
  end

  defp create_payment_method_configuration_mock(params) do
    conn = request(:post, "/v1/payment_method_configurations", params)
    handle_response(conn)
  end

  defp get_payment_method_configuration_mock(payment_method_configuration_id) do
    conn = request(:get, "/v1/payment_method_configurations/#{payment_method_configuration_id}", %{})
    handle_response(conn)
  end

  defp update_payment_method_configuration_mock(payment_method_configuration_id, params) do
    conn = request(:post, "/v1/payment_method_configurations/#{payment_method_configuration_id}", params)
    handle_response(conn)
  end

  defp list_payment_method_configurations_mock(params) do
    conn = request(:get, "/v1/payment_method_configurations", params)
    handle_response(conn)
  end

  defp get_mandate_mock(mandate_id) do
    conn = request(:get, "/v1/mandates/#{mandate_id}", %{})
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

  defp send_invoice_mock(invoice_id) do
    conn = request(:post, "/v1/invoices/#{invoice_id}/send", %{})
    handle_response(conn)
  end

  defp mark_invoice_uncollectible_mock(invoice_id) do
    conn = request(:post, "/v1/invoices/#{invoice_id}/mark_uncollectible", %{})
    handle_response(conn)
  end

  defp attach_invoice_payment_mock(invoice_id, params) do
    conn = request(:post, "/v1/invoices/#{invoice_id}/attach_payment", params)
    handle_response(conn)
  end

  defp list_invoices_mock(params) do
    conn = request(:get, "/v1/invoices", params)
    handle_response(conn)
  end

  defp search_invoices_mock(params) do
    conn = request(:get, "/v1/invoices/search", params)
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

  defp list_products_mock(params) do
    conn = request(:get, "/v1/products", params)
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

  defp list_prices_mock(params) do
    conn = request(:get, "/v1/prices", params)
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

  defp search_charges_mock(params) do
    conn = request(:get, "/v1/charges/search", params)
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

  defp confirm_payment_intent_mock(payment_intent_id, params) do
    conn = request(:post, "/v1/payment_intents/#{payment_intent_id}/confirm", params)
    handle_response(conn)
  end

  defp cancel_payment_intent_mock(payment_intent_id, params) do
    conn = request(:post, "/v1/payment_intents/#{payment_intent_id}/cancel", params)
    handle_response(conn)
  end

  defp capture_payment_intent_mock(payment_intent_id, params) do
    conn = request(:post, "/v1/payment_intents/#{payment_intent_id}/capture", params)
    handle_response(conn)
  end

  defp search_payment_intents_mock(params) do
    conn = request(:get, "/v1/payment_intents/search", params)
    handle_response(conn)
  end

  defp create_setup_intent_mock(params) do
    conn = request(:post, "/v1/setup_intents", params)
    handle_response(conn)
  end

  defp get_setup_intent_mock(setup_intent_id) do
    conn = request(:get, "/v1/setup_intents/#{setup_intent_id}", %{})
    handle_response(conn)
  end

  defp confirm_setup_intent_mock(setup_intent_id, params) do
    conn = request(:post, "/v1/setup_intents/#{setup_intent_id}/confirm", params)
    handle_response(conn)
  end

  defp cancel_setup_intent_mock(setup_intent_id, params) do
    conn = request(:post, "/v1/setup_intents/#{setup_intent_id}/cancel", params)
    handle_response(conn)
  end

  defp verify_setup_intent_microdeposits_mock(setup_intent_id, params) do
    conn = request(:post, "/v1/setup_intents/#{setup_intent_id}/verify_microdeposits", params)
    handle_response(conn)
  end

  defp list_setup_attempts_mock(params) do
    conn = request(:get, "/v1/setup_attempts", params)
    handle_response(conn)
  end

  defp get_balance_transaction_mock(txn_id) do
    conn = request(:get, "/v1/balance_transactions/#{txn_id}", %{})
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

  defp list_refunds_mock(params) do
    conn = request(:get, "/v1/refunds", params)
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

  defp update_checkout_session_mock(session_id, params) do
    conn = request(:post, "/v1/checkout/sessions/#{session_id}", params)
    handle_response(conn)
  end

  defp list_checkout_session_line_items_mock(session_id, params) do
    conn = request(:get, "/v1/checkout/sessions/#{session_id}/line_items", params)
    handle_response(conn)
  end

  defp expire_checkout_session_mock(session_id) do
    conn = request(:post, "/v1/checkout/sessions/#{session_id}/expire", %{})
    handle_response(conn)
  end

  defp create_payment_link_mock(params) do
    conn = request(:post, "/v1/payment_links", params)
    handle_response(conn)
  end

  defp get_payment_link_mock(payment_link_id) do
    conn = request(:get, "/v1/payment_links/#{payment_link_id}", %{})
    handle_response(conn)
  end

  defp update_payment_link_mock(payment_link_id, params) do
    conn = request(:post, "/v1/payment_links/#{payment_link_id}", params)
    handle_response(conn)
  end

  defp list_payment_links_mock(params) do
    conn = request(:get, "/v1/payment_links", params)
    handle_response(conn)
  end

  defp list_payment_link_line_items_mock(payment_link_id, params) do
    conn = request(:get, "/v1/payment_links/#{payment_link_id}/line_items", params)
    handle_response(conn)
  end

  defp create_coupon_mock(params) do
    conn = request(:post, "/v1/coupons", params)
    handle_response(conn)
  end

  defp create_promotion_code_mock(params) do
    conn = request(:post, "/v1/promotion_codes", params)
    handle_response(conn)
  end

  defp get_promotion_code_mock(promotion_code_id) do
    conn = request(:get, "/v1/promotion_codes/#{promotion_code_id}", %{})
    handle_response(conn)
  end

  defp update_promotion_code_mock(promotion_code_id, params) do
    conn = request(:post, "/v1/promotion_codes/#{promotion_code_id}", params)
    handle_response(conn)
  end

  defp list_promotion_codes_mock(params) do
    conn = request(:get, "/v1/promotion_codes", params)
    handle_response(conn)
  end

  defp create_billing_portal_configuration_mock(params) do
    conn = request(:post, "/v1/billing_portal/configurations", params)
    handle_response(conn)
  end

  defp get_billing_portal_configuration_mock(configuration_id) do
    conn = request(:get, "/v1/billing_portal/configurations/#{configuration_id}", %{})
    handle_response(conn)
  end

  defp update_billing_portal_configuration_mock(configuration_id, params) do
    conn = request(:post, "/v1/billing_portal/configurations/#{configuration_id}", params)
    handle_response(conn)
  end

  defp list_billing_portal_configurations_mock(params) do
    conn = request(:get, "/v1/billing_portal/configurations", params)
    handle_response(conn)
  end

  defp create_billing_portal_session_mock(params) do
    conn = request(:post, "/v1/billing_portal/sessions", params)
    handle_response(conn)
  end

  defp create_customer_balance_transaction_mock(customer_id, params) do
    conn = request(:post, "/v1/customers/#{customer_id}/balance_transactions", params)
    handle_response(conn)
  end

  defp get_customer_balance_transaction_mock(customer_id, transaction_id) do
    conn = request(:get, "/v1/customers/#{customer_id}/balance_transactions/#{transaction_id}", %{})
    handle_response(conn)
  end

  defp list_customer_balance_transactions_mock(customer_id, params) do
    conn = request(:get, "/v1/customers/#{customer_id}/balance_transactions", params)
    handle_response(conn)
  end

  defp get_cash_balance_mock(customer_id) do
    conn = request(:get, "/v1/customers/#{customer_id}/cash_balance", %{})
    handle_response(conn)
  end

  defp update_cash_balance_mock(customer_id, params) do
    conn = request(:post, "/v1/customers/#{customer_id}/cash_balance", params)
    handle_response(conn)
  end

  defp create_credit_note_mock(params) do
    conn = request(:post, "/v1/credit_notes", params)
    handle_response(conn)
  end

  defp create_account_mock(params) do
    conn = request(:post, "/v1/accounts", params)
    handle_response(conn)
  end

  defp get_account_mock(account_id) do
    conn = request(:get, "/v1/accounts/#{account_id}", %{})
    handle_response(conn)
  end

  defp update_account_mock(account_id, params) do
    conn = request(:post, "/v1/accounts/#{account_id}", params)
    handle_response(conn)
  end

  defp delete_account_mock(account_id) do
    conn = request(:delete, "/v1/accounts/#{account_id}", %{})
    handle_response(conn)
  end

  defp list_accounts_mock(params) do
    conn = request(:get, "/v1/accounts", params)
    handle_response(conn)
  end

  defp create_account_link_mock(params) do
    conn = request(:post, "/v1/account_links", params)
    handle_response(conn)
  end

  defp create_transfer_mock(params) do
    conn = request(:post, "/v1/transfers", params)
    handle_response(conn)
  end

  defp get_transfer_mock(transfer_id) do
    conn = request(:get, "/v1/transfers/#{transfer_id}", %{})
    handle_response(conn)
  end

  defp create_transfer_reversal_mock(transfer_id, params) do
    conn = request(:post, "/v1/transfers/#{transfer_id}/reversals", params)
    handle_response(conn)
  end

  defp list_transfer_reversals_mock(transfer_id, params) do
    conn = request(:get, "/v1/transfers/#{transfer_id}/reversals", params)
    handle_response(conn)
  end

  defp get_application_fee_mock(fee_id) do
    conn = request(:get, "/v1/application_fees/#{fee_id}", %{})
    handle_response(conn)
  end

  defp create_application_fee_refund_mock(fee_id, params) do
    conn = request(:post, "/v1/application_fees/#{fee_id}/refunds", params)
    handle_response(conn)
  end

  defp list_application_fee_refunds_mock(fee_id, params) do
    conn = request(:get, "/v1/application_fees/#{fee_id}/refunds", params)
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
