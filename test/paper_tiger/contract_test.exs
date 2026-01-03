defmodule PaperTiger.ContractTest do
  @moduledoc """
  Contract tests that run against both PaperTiger and real Stripe API.

  ## Running Tests

  ### Default Mode (PaperTiger Mock)
      mix test test/paper_tiger/contract_test.exs

  ### Validation Mode (Real Stripe API)
      export STRIPE_API_KEY=sk_test_your_key_here
      export VALIDATE_AGAINST_STRIPE=true
      mix test test/paper_tiger/contract_test.exs

  ## Purpose

  These tests ensure that PaperTiger accurately mimics Stripe's behavior by:
  1. Running the same test code against both backends
  2. Validating responses have the same structure
  3. Verifying error handling matches

  This gives us confidence that apps tested against PaperTiger will work
  with real Stripe in production.
  """

  use ExUnit.Case, async: false

  alias PaperTiger.TestClient

  setup_all do
    mode = TestClient.mode()

    IO.puts("\n")
    "=" |> String.duplicate(70) |> IO.puts()

    case mode do
      :real_stripe ->
        IO.puts("⚠️  RUNNING AGAINST REAL STRIPE TEST API")
        IO.puts("API key validated as TEST MODE (not live)")
        IO.puts("This will create test data in your Stripe test account")

      :paper_tiger ->
        IO.puts("✓ Running against PaperTiger mock (default)")
        IO.puts("No external API calls - fully self-contained")
    end

    "=" |> String.duplicate(70) |> IO.puts()
    IO.puts("\n")

    %{mode: mode}
  end

  setup do
    # Clear PaperTiger state before each test (no-op for real Stripe)
    if TestClient.paper_tiger?() do
      PaperTiger.flush()
    end

    :ok
  end

  describe "Customer CRUD Operations" do
    @tag :contract
    test "creates a customer with email" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "test@example.com"})

      assert customer["object"] == "customer"
      assert customer["email"] == "test@example.com"
      assert is_binary(customer["id"])
      assert String.starts_with?(customer["id"], "cus_")
      assert is_integer(customer["created"])

      # Cleanup for real Stripe
      cleanup_customer(customer["id"])
    end

    @tag :contract
    test "creates a customer with name and metadata" do
      params = %{
        "email" => "john@example.com",
        "metadata" => %{"plan" => "premium", "user_id" => "12345"},
        "name" => "John Doe"
      }

      {:ok, customer} = TestClient.create_customer(params)

      assert customer["email"] == "john@example.com"
      assert customer["name"] == "John Doe"
      assert customer["metadata"]["user_id"] == "12345"
      assert customer["metadata"]["plan"] == "premium"

      cleanup_customer(customer["id"])
    end

    @tag :contract
    test "retrieves a customer by ID" do
      {:ok, created} = TestClient.create_customer(%{"email" => "retrieve@example.com"})
      customer_id = created["id"]

      {:ok, retrieved} = TestClient.get_customer(customer_id)

      assert retrieved["id"] == customer_id
      assert retrieved["email"] == "retrieve@example.com"
      assert retrieved["object"] == "customer"

      cleanup_customer(customer_id)
    end

    @tag :contract
    test "updates a customer's email and name" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "old@example.com"})
      customer_id = customer["id"]

      {:ok, updated} =
        TestClient.update_customer(customer_id, %{
          "email" => "new@example.com",
          "name" => "Updated Name"
        })

      assert updated["id"] == customer_id
      assert updated["email"] == "new@example.com"
      assert updated["name"] == "Updated Name"

      cleanup_customer(customer_id)
    end

    @tag :contract
    test "deletes a customer" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "delete@example.com"})
      customer_id = customer["id"]

      {:ok, result} = TestClient.delete_customer(customer_id)

      # PaperTiger returns {"deleted": true, "id": "..."}
      # Real Stripe via stripity_stripe has inconsistent struct mapping
      if TestClient.paper_tiger?() do
        assert result["deleted"] == true
        assert result["id"] == customer_id
      else
        # For real Stripe, just verify the call succeeded and ID matches
        id = result["id"] || result[:id]
        assert id == customer_id
      end
    end

    @tag :contract
    test "returns 404 for non-existent customer" do
      {:error, error} = TestClient.get_customer("cus_nonexistent")

      assert error["error"]["type"] == "invalid_request_error"
      assert error["error"]["code"] == "resource_missing"
    end

    @tag :contract
    test "lists customers with pagination" do
      # Create multiple customers
      customer_ids =
        for i <- 1..5 do
          {:ok, customer} = TestClient.create_customer(%{"email" => "list#{i}@example.com"})
          customer["id"]
        end

      # List with limit
      {:ok, result} = TestClient.list_customers(%{"limit" => 3})

      assert is_list(result["data"])
      assert length(result["data"]) <= 3
      assert is_boolean(result["has_more"])

      # Cleanup
      Enum.each(customer_ids, &cleanup_customer/1)
    end
  end

  describe "Response Structure Validation" do
    @tag :contract
    test "customer objects have required fields" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "fields@example.com"})

      # Core fields that must exist
      assert Map.has_key?(customer, "id")
      assert Map.has_key?(customer, "object")
      assert Map.has_key?(customer, "created")
      assert Map.has_key?(customer, "email")
      assert Map.has_key?(customer, "metadata")
      assert Map.has_key?(customer, "livemode")

      cleanup_customer(customer["id"])
    end

    @tag :contract
    test "list responses have correct structure" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "list@example.com"})
      {:ok, result} = TestClient.list_customers(%{})

      assert Map.has_key?(result, "data")
      assert Map.has_key?(result, "has_more")
      assert is_list(result["data"])
      assert is_boolean(result["has_more"])

      cleanup_customer(customer["id"])
    end
  end

  describe "Subscription CRUD Operations" do
    # Helper to create a product and price for subscription tests
    defp create_test_price(name, amount \\ 2000) do
      {:ok, product} = TestClient.create_product(%{"name" => name})

      price_params = %{
        "currency" => "usd",
        "product" => product["id"],
        "recurring" => %{"interval" => "month"},
        "unit_amount" => amount
      }

      {:ok, price} = TestClient.create_price(price_params)
      {product, price}
    end

    @tag :contract
    test "creates a subscription with customer and items" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "sub@example.com"})
      {product, price} = create_test_price("Premium Plan")

      params = %{
        "customer" => customer["id"],
        "items" => [%{"price" => price["id"]}],
        "payment_behavior" => "default_incomplete"
      }

      {:ok, subscription} = TestClient.create_subscription(params)

      assert subscription["object"] == "subscription"
      assert subscription["customer"] == customer["id"]
      assert String.starts_with?(subscription["id"], "sub_")
      assert is_integer(subscription["created"])
      assert is_list(subscription["items"]["data"])
      assert not Enum.empty?(subscription["items"]["data"])

      cleanup_subscription(subscription["id"])
      cleanup_customer(customer["id"])
      cleanup_product(product["id"])
    end

    @tag :contract
    test "retrieves a subscription by ID" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "retrieve-sub@example.com"})
      {product, price} = create_test_price("Test Plan", 1000)

      params = %{
        "customer" => customer["id"],
        "items" => [%{"price" => price["id"]}],
        "payment_behavior" => "default_incomplete"
      }

      {:ok, created} = TestClient.create_subscription(params)
      subscription_id = created["id"]

      {:ok, retrieved} = TestClient.get_subscription(subscription_id)

      assert retrieved["id"] == subscription_id
      assert retrieved["object"] == "subscription"
      assert retrieved["customer"] == customer["id"]

      cleanup_subscription(subscription_id)
      cleanup_customer(customer["id"])
      cleanup_product(product["id"])
    end

    @tag :contract
    test "updates a subscription" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "update-sub@example.com"})
      {product, price} = create_test_price("Basic Plan", 1000)

      params = %{
        "customer" => customer["id"],
        "items" => [%{"price" => price["id"]}],
        "payment_behavior" => "default_incomplete"
      }

      {:ok, subscription} = TestClient.create_subscription(params)
      subscription_id = subscription["id"]

      {:ok, updated} =
        TestClient.update_subscription(subscription_id, %{
          "metadata" => %{"tier" => "premium", "updated" => "true"}
        })

      assert updated["id"] == subscription_id
      assert updated["metadata"]["updated"] == "true"
      assert updated["metadata"]["tier"] == "premium"

      cleanup_subscription(subscription_id)
      cleanup_customer(customer["id"])
      cleanup_product(product["id"])
    end

    @tag :contract
    test "cancels a subscription" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "cancel-sub@example.com"})
      {product, price} = create_test_price("Canceled Plan", 1000)

      params = %{
        "customer" => customer["id"],
        "items" => [%{"price" => price["id"]}],
        "payment_behavior" => "default_incomplete"
      }

      {:ok, subscription} = TestClient.create_subscription(params)
      subscription_id = subscription["id"]

      {:ok, result} = TestClient.delete_subscription(subscription_id)

      assert result["id"] == subscription_id
      assert result["status"] == "incomplete_expired"

      cleanup_customer(customer["id"])
      cleanup_product(product["id"])
    end

    @tag :contract
    test "lists subscriptions with pagination" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "list-subs@example.com"})

      # Create 3 subscriptions with different prices
      products_and_subscriptions =
        for i <- 1..3 do
          {product, price} = create_test_price("Plan #{i}", 1000 * i)

          params = %{
            "customer" => customer["id"],
            "items" => [%{"price" => price["id"]}],
            "payment_behavior" => "default_incomplete"
          }

          {:ok, subscription} = TestClient.create_subscription(params)
          {product, subscription}
        end

      subscription_ids = Enum.map(products_and_subscriptions, fn {_, sub} -> sub["id"] end)
      products = Enum.map(products_and_subscriptions, fn {prod, _} -> prod end)

      {:ok, result} = TestClient.list_subscriptions(%{"limit" => 2})

      assert is_list(result["data"])
      assert length(result["data"]) <= 2
      assert is_boolean(result["has_more"])

      Enum.each(subscription_ids, &cleanup_subscription/1)
      cleanup_customer(customer["id"])
      Enum.each(products, fn prod -> cleanup_product(prod["id"]) end)
    end

    @tag :contract
    test "subscription items contain full price object (not just ID)" do
      # This test validates that items[].price is a full object, not just a string ID
      # This is critical for compatibility with real Stripe API behavior

      # Create product first
      {:ok, product} = TestClient.create_product(%{"name" => "Contract Test Plan"})

      # Create price
      price_params = %{
        "currency" => "usd",
        "product" => product["id"],
        "recurring" => %{"interval" => "month"},
        "unit_amount" => 1500
      }

      {:ok, price} = TestClient.create_price(price_params)

      # Create customer
      {:ok, customer} = TestClient.create_customer(%{"email" => "price-object-test@example.com"})

      # Create subscription with pre-created price
      # For real Stripe, we need payment_behavior to skip payment method requirement
      subscription_params = %{
        "customer" => customer["id"],
        "items" => [%{"price" => price["id"]}],
        "payment_behavior" => "default_incomplete"
      }

      {:ok, subscription} = TestClient.create_subscription(subscription_params)

      # Validate subscription was created
      assert subscription["object"] == "subscription"
      assert is_list(subscription["items"]["data"])
      assert subscription["items"]["data"] != []

      # THE KEY ASSERTION: price should be a full object, not a string ID
      item = Enum.at(subscription["items"]["data"], 0)
      assert is_map(item["price"]), "Expected price to be a map/object, got: #{inspect(item["price"])}"
      assert item["price"]["id"] == price["id"]
      assert item["price"]["object"] == "price"
      assert item["price"]["currency"] == "usd"
      assert item["price"]["unit_amount"] == 1500

      # Cleanup
      cleanup_subscription(subscription["id"])
      cleanup_customer(customer["id"])
      cleanup_product(product["id"])
    end
  end

  # NOTE: PaymentMethod tests removed because they use raw card numbers
  # which don't work with real Stripe API. PaperTiger should accept
  # test tokens (pm_card_visa) like real Stripe does instead of raw cards.

  describe "Invoice Operations" do
    @tag :contract
    test "creates an invoice for a customer" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "invoice@example.com"})

      params = %{
        "customer" => customer["id"]
      }

      {:ok, invoice} = TestClient.create_invoice(params)

      assert invoice["object"] == "invoice"
      assert invoice["customer"] == customer["id"]
      assert String.starts_with?(invoice["id"], "in_")
      assert is_integer(invoice["created"])

      cleanup_invoice(invoice["id"])
      cleanup_customer(customer["id"])
    end

    @tag :contract
    test "retrieves an invoice by ID" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "retrieve-invoice@example.com"})

      params = %{
        "customer" => customer["id"]
      }

      {:ok, created} = TestClient.create_invoice(params)
      invoice_id = created["id"]

      {:ok, retrieved} = TestClient.get_invoice(invoice_id)

      assert retrieved["id"] == invoice_id
      assert retrieved["object"] == "invoice"
      assert retrieved["customer"] == customer["id"]

      cleanup_invoice(invoice_id)
      cleanup_customer(customer["id"])
    end
  end

  describe "Charge Structure Validation" do
    @tag :contract
    test "successful charge has balance_transaction" do
      params = %{
        "amount" => 2000,
        "currency" => "usd",
        "source" => "tok_visa"
      }

      {:ok, charge} = TestClient.create_charge(params)

      assert charge["object"] == "charge"
      assert charge["status"] == "succeeded"
      assert is_binary(charge["balance_transaction"])
      assert String.starts_with?(charge["balance_transaction"], "txn_")
    end

    @tag :contract
    test "charge object has required fields" do
      params = %{
        "amount" => 1500,
        "currency" => "usd",
        "source" => "tok_visa"
      }

      {:ok, charge} = TestClient.create_charge(params)

      # Core required fields
      assert Map.has_key?(charge, "id")
      assert Map.has_key?(charge, "object")
      assert Map.has_key?(charge, "amount")
      assert Map.has_key?(charge, "currency")
      assert Map.has_key?(charge, "status")
      assert Map.has_key?(charge, "created")
      assert Map.has_key?(charge, "livemode")

      assert charge["object"] == "charge"
      assert charge["amount"] == 1500
      assert charge["currency"] == "usd"
    end
  end

  describe "PaymentIntent Structure Validation" do
    @tag :contract
    test "creates payment intent with required fields" do
      params = %{
        "amount" => 3000,
        "currency" => "usd"
      }

      {:ok, payment_intent} = TestClient.create_payment_intent(params)

      # Core required fields
      assert payment_intent["object"] == "payment_intent"
      assert payment_intent["amount"] == 3000
      assert payment_intent["currency"] == "usd"
      assert is_binary(payment_intent["id"])
      assert String.starts_with?(payment_intent["id"], "pi_")
      assert is_binary(payment_intent["client_secret"])
      assert Map.has_key?(payment_intent, "status")
    end

    @tag :contract
    test "payment intent does NOT have charges field" do
      # Stripe API no longer includes charges as a top-level field on PaymentIntent
      # Charges are accessed via separate endpoint: GET /v1/charges?payment_intent=pi_xxx
      params = %{
        "amount" => 2500,
        "currency" => "usd"
      }

      {:ok, payment_intent} = TestClient.create_payment_intent(params)
      {:ok, retrieved} = TestClient.get_payment_intent(payment_intent["id"])

      # charges should NOT be present on PaymentIntent
      refute Map.has_key?(retrieved, "charges")
    end
  end

  describe "Refund Structure Validation" do
    @tag :contract
    test "refund has balance_transaction" do
      # Create a charge first
      charge_params = %{
        "amount" => 2000,
        "currency" => "usd",
        "source" => "tok_visa"
      }

      {:ok, charge} = TestClient.create_charge(charge_params)

      # Create refund
      refund_params = %{
        "amount" => 1000,
        "charge" => charge["id"]
      }

      {:ok, refund} = TestClient.create_refund(refund_params)

      assert refund["object"] == "refund"
      assert refund["amount"] == 1000
      assert is_binary(refund["balance_transaction"])
      assert String.starts_with?(refund["balance_transaction"], "txn_")
    end

    @tag :contract
    test "refund object has required fields" do
      charge_params = %{
        "amount" => 3000,
        "currency" => "usd",
        "source" => "tok_visa"
      }

      {:ok, charge} = TestClient.create_charge(charge_params)

      refund_params = %{
        "charge" => charge["id"]
      }

      {:ok, refund} = TestClient.create_refund(refund_params)

      # Core required fields
      assert Map.has_key?(refund, "id")
      assert Map.has_key?(refund, "object")
      assert Map.has_key?(refund, "amount")
      assert Map.has_key?(refund, "currency")
      assert Map.has_key?(refund, "status")
      assert Map.has_key?(refund, "charge")
      assert Map.has_key?(refund, "created")

      assert refund["object"] == "refund"
      assert refund["charge"] == charge["id"]
    end
  end

  describe "Invoice Structure Validation" do
    @tag :contract
    test "invoice object has required fields" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "invoice-fields@example.com"})

      params = %{"customer" => customer["id"]}
      {:ok, invoice} = TestClient.create_invoice(params)

      # Core required fields
      assert Map.has_key?(invoice, "id")
      assert Map.has_key?(invoice, "object")
      assert Map.has_key?(invoice, "customer")
      assert Map.has_key?(invoice, "status")
      assert Map.has_key?(invoice, "created")
      assert Map.has_key?(invoice, "livemode")

      assert invoice["object"] == "invoice"
      assert invoice["customer"] == customer["id"]

      # Invoice should have lines list structure
      assert Map.has_key?(invoice, "lines")

      cleanup_invoice(invoice["id"])
      cleanup_customer(customer["id"])
    end

    @tag :contract
    test "invoice lines is a list object" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "invoice-lines@example.com"})

      params = %{"customer" => customer["id"]}
      {:ok, invoice} = TestClient.create_invoice(params)

      lines = invoice["lines"]

      # lines should be a list object structure
      assert is_map(lines), "Expected lines to be a map/object"
      assert Map.has_key?(lines, "data")
      assert is_list(lines["data"])
      assert Map.has_key?(lines, "has_more")

      cleanup_invoice(invoice["id"])
      cleanup_customer(customer["id"])
    end
  end

  describe "Checkout Session Operations" do
    @tag :contract
    test "creates a checkout session" do
      params = %{
        "cancel_url" => "https://example.com/cancel",
        "line_items" => [
          %{
            "price_data" => %{"currency" => "usd", "product_data" => %{"name" => "Test Product"}, "unit_amount" => 2000},
            "quantity" => 1
          }
        ],
        "mode" => "payment",
        "success_url" => "https://example.com/success"
      }

      {:ok, session} = TestClient.create_checkout_session(params)

      assert session["object"] == "checkout.session"
      assert is_binary(session["id"])
      assert String.starts_with?(session["id"], "cs_")
      assert session["mode"] == "payment"
      assert session["status"] == "open"
    end

    @tag :contract
    test "retrieves a checkout session" do
      params = %{
        "cancel_url" => "https://example.com/cancel",
        "line_items" => [
          %{
            "price_data" => %{"currency" => "usd", "product_data" => %{"name" => "Test Product"}, "unit_amount" => 2000},
            "quantity" => 1
          }
        ],
        "mode" => "payment",
        "success_url" => "https://example.com/success"
      }

      {:ok, created} = TestClient.create_checkout_session(params)
      {:ok, retrieved} = TestClient.get_checkout_session(created["id"])

      assert retrieved["id"] == created["id"]
      assert retrieved["object"] == "checkout.session"
      assert retrieved["mode"] == "payment"
    end

    @tag :contract
    test "expires a checkout session" do
      params = %{
        "cancel_url" => "https://example.com/cancel",
        "line_items" => [
          %{
            "price_data" => %{"currency" => "usd", "product_data" => %{"name" => "Test Product"}, "unit_amount" => 2000},
            "quantity" => 1
          }
        ],
        "mode" => "payment",
        "success_url" => "https://example.com/success"
      }

      {:ok, created} = TestClient.create_checkout_session(params)
      {:ok, expired} = TestClient.expire_checkout_session(created["id"])

      assert expired["id"] == created["id"]
      assert expired["status"] == "expired"
    end
  end

  describe "Error Response Format Validation" do
    @tag :contract
    test "non-existent customer returns resource_missing error" do
      {:error, error} = TestClient.get_customer("cus_nonexistent_test_123")

      assert error["error"]["type"] == "invalid_request_error"
      assert error["error"]["code"] == "resource_missing"
      assert error["error"]["message"] == "No such customer: 'cus_nonexistent_test_123'"
      assert error["error"]["param"] == "id"
    end

    @tag :contract
    test "non-existent product returns resource_missing error" do
      {:error, error} = TestClient.get_product("prod_nonexistent_test_123")

      assert error["error"]["type"] == "invalid_request_error"
      assert error["error"]["code"] == "resource_missing"
      assert error["error"]["message"] == "No such product: 'prod_nonexistent_test_123'"
      assert error["error"]["param"] == "id"
    end

    @tag :contract
    test "non-existent subscription returns resource_missing error" do
      {:error, error} = TestClient.get_subscription("sub_nonexistent_test_123")

      assert error["error"]["type"] == "invalid_request_error"
      assert error["error"]["code"] == "resource_missing"
      assert error["error"]["message"] == "No such subscription: 'sub_nonexistent_test_123'"
      assert error["error"]["param"] == "id"
    end

    @tag :contract
    test "non-existent price returns resource_missing error" do
      {:error, error} = TestClient.get_price("price_nonexistent_test_123")

      assert error["error"]["type"] == "invalid_request_error"
      assert error["error"]["code"] == "resource_missing"
      assert error["error"]["message"] == "No such price: 'price_nonexistent_test_123'"
      assert error["error"]["param"] == "price"
    end

    @tag :contract
    test "subscription with non-existent customer returns resource_missing error" do
      # First create a valid price
      {:ok, product} = TestClient.create_product(%{"name" => "Error Test Plan"})

      price_params = %{
        "currency" => "usd",
        "product" => product["id"],
        "recurring" => %{"interval" => "month"},
        "unit_amount" => 1000
      }

      {:ok, price} = TestClient.create_price(price_params)

      # Try to create subscription with non-existent customer
      subscription_params = %{
        "customer" => "cus_nonexistent_test_123",
        "items" => [%{"price" => price["id"]}]
      }

      {:error, error} = TestClient.create_subscription(subscription_params)

      assert error["error"]["type"] == "invalid_request_error"
      assert error["error"]["code"] == "resource_missing"
      assert error["error"]["message"] == "No such customer: 'cus_nonexistent_test_123'"

      cleanup_product(product["id"])
    end

    @tag :contract
    test "subscription with non-existent price returns resource_missing error" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "price-error@example.com"})

      # Try to create subscription with non-existent price
      subscription_params = %{
        "customer" => customer["id"],
        "items" => [%{"price" => "price_nonexistent_test_123"}]
      }

      {:error, error} = TestClient.create_subscription(subscription_params)

      assert error["error"]["type"] == "invalid_request_error"
      assert error["error"]["code"] == "resource_missing"
      assert error["error"]["message"] == "No such price: 'price_nonexistent_test_123'"
      assert error["error"]["param"] == "items[0][price]"

      cleanup_customer(customer["id"])
    end
  end

  describe "InvoiceItem Operations" do
    @tag :contract
    test "creates an invoice item with amount and currency" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "invoiceitem@example.com"})
      {:ok, invoice} = TestClient.create_invoice(%{"customer" => customer["id"]})

      params = %{
        "amount" => 4900,
        "currency" => "usd",
        "customer" => customer["id"],
        "description" => "Test charge for contract testing",
        "invoice" => invoice["id"]
      }

      {:ok, item} = TestClient.create_invoice_item(params)

      assert item["object"] == "invoiceitem"
      assert item["amount"] == 4900
      assert item["currency"] == "usd"
      assert item["customer"] == customer["id"]
      assert item["invoice"] == invoice["id"]
      assert String.starts_with?(item["id"], "ii_")

      cleanup_invoice(invoice["id"])
      cleanup_customer(customer["id"])
    end

    @tag :contract
    test "invoice item object has required fields" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "invoiceitem-fields@example.com"})
      {:ok, invoice} = TestClient.create_invoice(%{"customer" => customer["id"]})

      params = %{
        "amount" => 2500,
        "currency" => "usd",
        "customer" => customer["id"],
        "invoice" => invoice["id"]
      }

      {:ok, item} = TestClient.create_invoice_item(params)

      # Core required fields
      assert Map.has_key?(item, "id")
      assert Map.has_key?(item, "object")
      assert Map.has_key?(item, "amount")
      assert Map.has_key?(item, "currency")
      assert Map.has_key?(item, "customer")
      assert Map.has_key?(item, "date")

      cleanup_invoice(invoice["id"])
      cleanup_customer(customer["id"])
    end

    @tag :contract
    test "retrieves an invoice item by ID" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "get-invoiceitem@example.com"})
      {:ok, invoice} = TestClient.create_invoice(%{"customer" => customer["id"]})

      params = %{
        "amount" => 1500,
        "currency" => "usd",
        "customer" => customer["id"],
        "invoice" => invoice["id"]
      }

      {:ok, created} = TestClient.create_invoice_item(params)
      {:ok, retrieved} = TestClient.get_invoice_item(created["id"])

      assert retrieved["id"] == created["id"]
      assert retrieved["object"] == "invoiceitem"
      assert retrieved["amount"] == 1500

      cleanup_invoice(invoice["id"])
      cleanup_customer(customer["id"])
    end
  end

  describe "Invoice Finalize and Pay Operations" do
    @tag :contract
    test "finalizes a draft invoice" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "finalize@example.com"})
      {:ok, invoice} = TestClient.create_invoice(%{"customer" => customer["id"]})

      # Add an item so there's something to pay
      {:ok, _item} =
        TestClient.create_invoice_item(%{
          "amount" => 3000,
          "currency" => "usd",
          "customer" => customer["id"],
          "invoice" => invoice["id"]
        })

      # Invoice should be in draft status
      {:ok, retrieved} = TestClient.get_invoice(invoice["id"])
      assert retrieved["status"] == "draft"

      # Finalize the invoice
      {:ok, finalized} = TestClient.finalize_invoice(invoice["id"])

      assert finalized["id"] == invoice["id"]
      assert finalized["status"] == "open"

      cleanup_invoice(invoice["id"])
      cleanup_customer(customer["id"])
    end

    @tag :contract
    @tag :skip_real_stripe
    test "pays a finalized invoice" do
      # Skip for real Stripe - paying requires a valid payment method attached
      if TestClient.real_stripe?() do
        :ok
      else
        {:ok, customer} = TestClient.create_customer(%{"email" => "payinvoice@example.com"})
        {:ok, invoice} = TestClient.create_invoice(%{"customer" => customer["id"]})

        # Add an item
        {:ok, _item} =
          TestClient.create_invoice_item(%{
            "amount" => 5000,
            "currency" => "usd",
            "customer" => customer["id"],
            "invoice" => invoice["id"]
          })

        # Finalize first
        {:ok, _finalized} = TestClient.finalize_invoice(invoice["id"])

        # Pay the invoice
        {:ok, paid} = TestClient.pay_invoice(invoice["id"])

        assert paid["id"] == invoice["id"]
        assert paid["status"] == "paid"
        assert paid["amount_paid"] == paid["amount_due"]

        cleanup_invoice(invoice["id"])
        cleanup_customer(customer["id"])
      end
    end

    @tag :contract
    test "invoice status transitions correctly through lifecycle" do
      # Skip complex payment for real Stripe - focus on structure
      if TestClient.real_stripe?() do
        {:ok, customer} = TestClient.create_customer(%{"email" => "lifecycle@example.com"})
        {:ok, invoice} = TestClient.create_invoice(%{"customer" => customer["id"]})

        # Verify draft status
        assert invoice["status"] == "draft"

        # Add item and finalize
        {:ok, _item} =
          TestClient.create_invoice_item(%{
            "amount" => 1000,
            "currency" => "usd",
            "customer" => customer["id"],
            "invoice" => invoice["id"]
          })

        {:ok, finalized} = TestClient.finalize_invoice(invoice["id"])
        assert finalized["status"] == "open"

        cleanup_invoice(invoice["id"])
        cleanup_customer(customer["id"])
      else
        {:ok, customer} = TestClient.create_customer(%{"email" => "lifecycle@example.com"})
        {:ok, invoice} = TestClient.create_invoice(%{"customer" => customer["id"]})

        # Verify draft status
        assert invoice["status"] == "draft"

        # Add item
        {:ok, _item} =
          TestClient.create_invoice_item(%{
            "amount" => 1000,
            "currency" => "usd",
            "customer" => customer["id"],
            "invoice" => invoice["id"]
          })

        # Finalize
        {:ok, finalized} = TestClient.finalize_invoice(invoice["id"])
        assert finalized["status"] == "open"

        # Pay
        {:ok, paid} = TestClient.pay_invoice(invoice["id"])
        assert paid["status"] == "paid"

        cleanup_invoice(invoice["id"])
        cleanup_customer(customer["id"])
      end
    end
  end

  describe "Card Error Responses" do
    @tag :contract
    @tag :skip_real_stripe
    test "card decline returns card_error type with decline_code" do
      # This test only works with PaperTiger chaos simulation
      # Real Stripe would require actual card declines which we can't trigger reliably
      if TestClient.real_stripe?() do
        :ok
      else
        # Set up ChaosCoordinator to simulate a decline for this customer
        {:ok, customer} = TestClient.create_customer(%{"email" => "decline@example.com"})

        # Configure chaos to fail this customer
        PaperTiger.ChaosCoordinator.simulate_failure(customer["id"], :insufficient_funds)

        {:ok, invoice} = TestClient.create_invoice(%{"customer" => customer["id"]})

        {:ok, _item} =
          TestClient.create_invoice_item(%{
            "amount" => 5000,
            "currency" => "usd",
            "customer" => customer["id"],
            "invoice" => invoice["id"]
          })

        {:ok, _finalized} = TestClient.finalize_invoice(invoice["id"])

        # Pay should fail with card error
        {:error, error} = TestClient.pay_invoice(invoice["id"])

        assert error["error"]["type"] == "card_error"
        assert error["error"]["code"] == "card_declined"
        assert error["error"]["decline_code"] == "insufficient_funds"

        # Reset chaos
        PaperTiger.ChaosCoordinator.reset()

        cleanup_invoice(invoice["id"])
        cleanup_customer(customer["id"])
      end
    end

    @tag :contract
    @tag :skip_real_stripe
    test "various decline codes are returned correctly" do
      if TestClient.real_stripe?() do
        :ok
      else
        decline_codes = [
          :card_declined,
          :insufficient_funds,
          :expired_card,
          :incorrect_cvc,
          :fraudulent
        ]

        for decline_code <- decline_codes do
          {:ok, customer} = TestClient.create_customer(%{"email" => "decline-#{decline_code}@example.com"})
          PaperTiger.ChaosCoordinator.simulate_failure(customer["id"], decline_code)

          {:ok, invoice} = TestClient.create_invoice(%{"customer" => customer["id"]})

          {:ok, _item} =
            TestClient.create_invoice_item(%{
              "amount" => 1000,
              "currency" => "usd",
              "customer" => customer["id"],
              "invoice" => invoice["id"]
            })

          {:ok, _finalized} = TestClient.finalize_invoice(invoice["id"])
          {:error, error} = TestClient.pay_invoice(invoice["id"])

          assert error["error"]["type"] == "card_error",
                 "Expected card_error for #{decline_code}, got: #{inspect(error["error"]["type"])}"

          assert error["error"]["decline_code"] == to_string(decline_code),
                 "Expected decline_code #{decline_code}, got: #{inspect(error["error"]["decline_code"])}"

          PaperTiger.ChaosCoordinator.reset()
        end
      end
    end
  end

  describe "Subscription latest_invoice Validation" do
    @tag :contract
    test "subscription has latest_invoice field" do
      # Create product and price
      {:ok, product} = TestClient.create_product(%{"name" => "Invoice Test Plan"})

      price_params = %{
        "currency" => "usd",
        "product" => product["id"],
        "recurring" => %{"interval" => "month"},
        "unit_amount" => 2000
      }

      {:ok, price} = TestClient.create_price(price_params)

      # Create customer
      {:ok, customer} = TestClient.create_customer(%{"email" => "latest-invoice@example.com"})

      # Create subscription - Stripe automatically creates first invoice
      subscription_params = %{
        "customer" => customer["id"],
        "items" => [%{"price" => price["id"]}],
        "payment_behavior" => "default_incomplete"
      }

      {:ok, subscription} = TestClient.create_subscription(subscription_params)

      # Retrieve subscription to check latest_invoice
      {:ok, retrieved} = TestClient.get_subscription(subscription["id"])

      # latest_invoice should exist (as object or ID string)
      # Stripe returns an ID by default, expanded returns object
      assert Map.has_key?(retrieved, "latest_invoice")

      # If present, should be either a string ID or a map (object)
      if retrieved["latest_invoice"] do
        assert is_map(retrieved["latest_invoice"]) or is_binary(retrieved["latest_invoice"])

        if is_map(retrieved["latest_invoice"]) do
          assert retrieved["latest_invoice"]["object"] == "invoice"
        end
      end

      cleanup_subscription(subscription["id"])
      cleanup_customer(customer["id"])
      cleanup_product(product["id"])
    end
  end

  ## Helpers

  defp cleanup_customer(customer_id) do
    # Only cleanup for real Stripe (PaperTiger auto-flushes in setup)
    if TestClient.real_stripe?() do
      TestClient.delete_customer(customer_id)
    end
  end

  defp cleanup_subscription(subscription_id) do
    if TestClient.real_stripe?() do
      TestClient.delete_subscription(subscription_id)
    end
  end

  defp cleanup_invoice(_invoice_id) do
    # Invoices don't need explicit cleanup in Stripe
    # They're automatically managed with the customer
    :ok
  end

  defp cleanup_product(_product_id) do
    # Products can't be deleted in Stripe if they have prices
    # Just leave them - they're in test mode anyway
    :ok
  end
end
