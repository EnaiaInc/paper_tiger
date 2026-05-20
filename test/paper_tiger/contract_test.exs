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

      assert result["deleted"] == true
      assert result["id"] == customer_id
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

  describe "Search Operations" do
    @tag :contract
    test "searches customers by email and metadata" do
      marker = "pt_search_#{System.unique_integer([:positive])}"
      email = "#{marker}@example.com"

      {:ok, customer} =
        TestClient.create_customer(%{
          "email" => email,
          "metadata" => %{"paper_tiger_search" => marker},
          "name" => "PaperTiger Search Contract"
        })

      query = "email:'#{email}' AND metadata['paper_tiger_search']:'#{marker}'"
      result = eventually_search_customer(query, customer["id"])

      assert result["object"] == "search_result"
      assert is_list(result["data"])
      assert is_boolean(result["has_more"])
      assert Enum.any?(result["data"], fn item -> item["id"] == customer["id"] end)

      cleanup_customer(customer["id"])
    end

    @tag :contract
    test "search returns an invalid request error for mixed connectors" do
      {:error, error} =
        TestClient.search_customers(%{
          "query" => "email:'one@example.com' AND email:'two@example.com' OR email:'three@example.com'"
        })

      assert error["error"]["type"] == "invalid_request_error"
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

  describe "PaymentMethod Operations" do
    @tag :contract
    test "lists payment methods for a customer filters correctly" do
      # Create a customer
      {:ok, customer} = TestClient.create_customer(%{"email" => "pm-list@example.com"})

      # Create and attach payment methods to this customer
      # Use pm_card_visa token for real Stripe compatibility
      {:ok, pm1} = TestClient.attach_payment_method("pm_card_visa", %{"customer" => customer["id"]})

      {:ok, pm2} = TestClient.attach_payment_method("pm_card_mastercard", %{"customer" => customer["id"]})

      # Create another customer with their own payment method
      {:ok, other_customer} = TestClient.create_customer(%{"email" => "other-pm@example.com"})
      {:ok, other_pm} = TestClient.attach_payment_method("pm_card_amex", %{"customer" => other_customer["id"]})

      # List payment methods for first customer - should only get their 2 PMs
      {:ok, result} = TestClient.list_payment_methods(%{"customer" => customer["id"]})

      assert result["object"] == "list"
      assert length(result["data"]) == 2

      pm_ids = Enum.map(result["data"], & &1["id"])
      assert pm1["id"] in pm_ids
      assert pm2["id"] in pm_ids
      refute other_pm["id"] in pm_ids

      # Cleanup
      cleanup_customer(customer["id"])
      cleanup_customer(other_customer["id"])
    end
  end

  describe "Payment Method Adjunct Operations" do
    @tag :contract
    test "creates and retrieves a confirmation token" do
      {:ok, token} = TestClient.create_confirmation_token(%{"payment_method" => "pm_card_visa"})

      assert token["object"] == "confirmation_token"
      assert String.starts_with?(token["id"], "ctoken_")
      assert token["payment_method_preview"]["type"] == "card"
      assert is_integer(token["created"])
      assert is_integer(token["expires_at"])

      {:ok, retrieved} = TestClient.get_confirmation_token(token["id"])

      assert retrieved["id"] == token["id"]
      assert retrieved["object"] == "confirmation_token"
    end

    @tag :contract
    test "creates a customer session for the payment element" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "customer-session@example.com"})

      {:ok, customer_session} =
        TestClient.create_customer_session(%{
          "components" => %{
            "payment_element" => %{
              "enabled" => true,
              "features" => %{"payment_method_redisplay" => "enabled"}
            }
          },
          "customer" => customer["id"]
        })

      assert customer_session["object"] == "customer_session"
      assert customer_session["customer"] == customer["id"]
      assert is_binary(customer_session["client_secret"])
      assert is_map(customer_session["components"])
      assert is_integer(customer_session["expires_at"])

      cleanup_customer(customer["id"])
    end

    @tag :contract
    @tag :skip_real_stripe
    test "creates and updates payment method domains" do
      if TestClient.real_stripe?() do
        :ok
      else
        {:ok, domain} =
          TestClient.create_payment_method_domain(%{
            "domain_name" => "contract.example.com"
          })

        assert domain["object"] == "payment_method_domain"
        assert String.starts_with?(domain["id"], "pmd_")
        assert domain["domain_name"] == "contract.example.com"
        assert domain["enabled"] == true

        {:ok, updated} = TestClient.update_payment_method_domain(domain["id"], %{"enabled" => false})

        assert updated["enabled"] == false
        assert updated["apple_pay"]["status"] == "inactive"

        {:ok, retrieved} = TestClient.get_payment_method_domain(domain["id"])
        assert retrieved["id"] == domain["id"]

        {:ok, list} = TestClient.list_payment_method_domains()
        assert Enum.any?(list["data"], &(&1["id"] == domain["id"]))
      end
    end

    @tag :contract
    @tag :skip_real_stripe
    test "creates and updates payment method configurations" do
      if TestClient.real_stripe?() do
        :ok
      else
        {:ok, configuration} =
          TestClient.create_payment_method_configuration(%{
            "card" => %{"display_preference" => %{"preference" => "off"}},
            "name" => "Contract checkout"
          })

        assert configuration["object"] == "payment_method_configuration"
        assert String.starts_with?(configuration["id"], "pmc_")
        assert configuration["card"]["available"] == false
        assert configuration["link"]["available"] == true

        {:ok, updated} =
          TestClient.update_payment_method_configuration(configuration["id"], %{
            "card" => %{"display_preference" => %{"preference" => "on"}},
            "name" => "Updated contract checkout"
          })

        assert updated["name"] == "Updated contract checkout"
        assert updated["card"]["available"] == true

        {:ok, retrieved} = TestClient.get_payment_method_configuration(configuration["id"])
        assert retrieved["id"] == configuration["id"]

        {:ok, list} = TestClient.list_payment_method_configurations()
        assert Enum.any?(list["data"], &(&1["id"] == configuration["id"]))
      end
    end

    @tag :contract
    @tag :skip_real_stripe
    test "retrieves a mandate generated by a successful bank setup intent" do
      if TestClient.real_stripe?() do
        :ok
      else
        {:ok, payment_method} =
          TestClient.create_payment_method(%{
            "type" => "us_bank_account",
            "us_bank_account" => %{"routing_number" => "110000000"}
          })

        {:ok, setup_intent} =
          TestClient.create_setup_intent(%{
            "payment_method" => payment_method["id"],
            "payment_method_types" => ["us_bank_account"]
          })

        {:ok, _requires_action} = TestClient.confirm_setup_intent(setup_intent["id"])

        {:ok, verified} =
          TestClient.verify_setup_intent_microdeposits(setup_intent["id"], %{
            "amounts" => [32, 45]
          })

        assert String.starts_with?(verified["mandate"], "mandate_")

        {:ok, mandate} = TestClient.get_mandate(verified["mandate"])

        assert mandate["object"] == "mandate"
        assert mandate["payment_method"] == payment_method["id"]
        assert mandate["status"] == "active"
      end
    end
  end

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

    @tag :contract
    test "lists invoices filtered by status" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "list-invoice@example.com"})

      # Create a draft invoice with auto_advance=false to prevent auto-finalization
      {:ok, draft_invoice} =
        TestClient.create_invoice(%{"auto_advance" => false, "customer" => customer["id"]})

      assert draft_invoice["status"] == "draft"

      # Add a line item so it's not a $0 invoice (which auto-pays)
      {:ok, _item} =
        TestClient.create_invoice_item(%{
          "amount" => 1000,
          "currency" => "usd",
          "customer" => customer["id"],
          "invoice" => draft_invoice["id"]
        })

      # Create another draft invoice
      {:ok, another_draft} =
        TestClient.create_invoice(%{"auto_advance" => false, "customer" => customer["id"]})

      assert another_draft["status"] == "draft"

      # List only draft invoices - should return 2
      {:ok, draft_list} = TestClient.list_invoices(%{"customer" => customer["id"], "status" => "draft"})
      assert draft_list["object"] == "list"
      assert length(draft_list["data"]) == 2
      assert Enum.all?(draft_list["data"], fn inv -> inv["status"] == "draft" end)

      # Finalize the first one to make it "open"
      # Use collection_method=send_invoice to prevent auto-payment
      {:ok, _} =
        TestClient.update_invoice(draft_invoice["id"], %{"collection_method" => "send_invoice", "days_until_due" => 30})

      {:ok, open_invoice} = TestClient.finalize_invoice(draft_invoice["id"])
      assert open_invoice["status"] == "open"

      # List only open invoices - should return 1
      {:ok, open_list} = TestClient.list_invoices(%{"customer" => customer["id"], "status" => "open"})
      assert open_list["object"] == "list"
      assert length(open_list["data"]) == 1
      assert Enum.all?(open_list["data"], fn inv -> inv["status"] == "open" end)

      # List draft invoices - now should return 1
      {:ok, draft_list2} = TestClient.list_invoices(%{"customer" => customer["id"], "status" => "draft"})
      assert draft_list2["object"] == "list"
      assert length(draft_list2["data"]) == 1
      assert Enum.all?(draft_list2["data"], fn inv -> inv["status"] == "draft" end)

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

  describe "Product and Price List Filter Validation" do
    @tag :contract
    test "lists products with documented filters" do
      suffix = unique_suffix()
      url = "https://example.com/paper-tiger-product-filter-#{suffix}"

      {:ok, target} =
        TestClient.create_product(%{
          "name" => "PT Product Filter Target #{suffix}",
          "shippable" => true,
          "url" => url
        })

      {:ok, inactive} =
        TestClient.create_product(%{
          "active" => false,
          "name" => "PT Product Filter Inactive #{suffix}",
          "shippable" => false
        })

      {:ok, active_list} =
        TestClient.list_products(%{
          "active" => true,
          "ids" => [target["id"], inactive["id"]],
          "limit" => 10
        })

      assert active_list["object"] == "list"
      assert Enum.map(active_list["data"], & &1["id"]) == [target["id"]]

      {:ok, url_list} = TestClient.list_products(%{"limit" => 10, "url" => url})

      assert Enum.map(url_list["data"], & &1["id"]) == [target["id"]]
    end

    @tag :contract
    test "lists prices with documented filters and product expansion" do
      suffix = unique_suffix()
      lookup_key = "pt_filter_#{suffix}"

      {:ok, product} = TestClient.create_product(%{"name" => "PT Price Filter Product #{suffix}"})

      {:ok, target} =
        TestClient.create_price(%{
          "currency" => "usd",
          "lookup_key" => lookup_key,
          "product" => product["id"],
          "recurring" => %{"interval" => "month", "usage_type" => "licensed"},
          "unit_amount" => 1_200
        })

      {:ok, inactive_once} =
        TestClient.create_price(%{
          "active" => false,
          "currency" => "eur",
          "product" => product["id"],
          "unit_amount" => 500
        })

      {:ok, recurring_list} =
        TestClient.list_prices(%{
          "active" => true,
          "currency" => "usd",
          "limit" => 10,
          "lookup_keys" => [lookup_key],
          "product" => product["id"],
          "recurring" => %{"interval" => "month", "usage_type" => "licensed"},
          "type" => "recurring"
        })

      assert Enum.map(recurring_list["data"], & &1["id"]) == [target["id"]]

      {:ok, inactive_list} =
        TestClient.list_prices(%{
          "active" => false,
          "limit" => 10,
          "product" => product["id"],
          "type" => "one_time"
        })

      assert Enum.map(inactive_list["data"], & &1["id"]) == [inactive_once["id"]]

      {:ok, expanded_list} =
        TestClient.list_prices(%{
          "expand" => ["data.product"],
          "limit" => 10,
          "product" => product["id"]
        })

      expanded_target = Enum.find(expanded_list["data"], &(&1["id"] == target["id"]))
      assert expanded_target["product"]["id"] == product["id"]
      assert expanded_target["product"]["object"] == "product"
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

  describe "SetupIntent Lifecycle Validation" do
    @tag :contract
    test "confirms a card setup intent and records a setup attempt" do
      {:ok, setup_intent} =
        TestClient.create_setup_intent(%{
          "payment_method" => "pm_card_visa"
        })

      {:ok, confirmed} = TestClient.confirm_setup_intent(setup_intent["id"])

      assert confirmed["object"] == "setup_intent"
      assert confirmed["status"] == "succeeded"
      assert is_binary(confirmed["payment_method"])
      assert String.starts_with?(confirmed["payment_method"], "pm_")
      assert is_binary(confirmed["latest_attempt"])
      assert String.starts_with?(confirmed["latest_attempt"], "setatt_")

      {:ok, attempts} = TestClient.list_setup_attempts(%{"setup_intent" => confirmed["id"]})

      assert attempts["object"] == "list"
      assert length(attempts["data"]) == 1

      [attempt] = attempts["data"]
      assert attempt["object"] == "setup_attempt"
      assert attempt["setup_intent"] == confirmed["id"]
      assert attempt["status"] == "succeeded"
      assert is_binary(attempt["payment_method"])
    end

    @tag :contract
    test "cancels a setup intent with a cancellation reason" do
      {:ok, setup_intent} = TestClient.create_setup_intent()

      {:ok, canceled} =
        TestClient.cancel_setup_intent(setup_intent["id"], %{
          "cancellation_reason" => "duplicate"
        })

      assert canceled["object"] == "setup_intent"
      assert canceled["status"] == "canceled"
      assert canceled["cancellation_reason"] == "duplicate"
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
      assert refund["amount"] == charge["amount"]
    end

    @tag :contract
    test "lists refunds filtered by charge" do
      charge_params = %{
        "amount" => 2400,
        "currency" => "usd",
        "source" => "tok_visa"
      }

      {:ok, charge} = TestClient.create_charge(charge_params)
      {:ok, refund} = TestClient.create_refund(%{"amount" => 600, "charge" => charge["id"]})

      {:ok, refunds} = TestClient.list_refunds(%{"charge" => charge["id"], "limit" => 10})

      assert refunds["object"] == "list"
      assert Enum.map(refunds["data"], & &1["id"]) == [refund["id"]]
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

    @tag :contract
    test "invoice status_transitions contains timestamp fields" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "transitions@example.com"})

      params = %{"customer" => customer["id"]}
      {:ok, invoice} = TestClient.create_invoice(params)

      # status_transitions should exist and be a map
      assert Map.has_key?(invoice, "status_transitions")
      transitions = invoice["status_transitions"]
      assert is_map(transitions)

      # Stripe returns status_transitions with atom keys inside the map value
      # Check for both atom and string keys to handle JSON parsing differences
      assert Map.has_key?(transitions, :finalized_at) or Map.has_key?(transitions, "finalized_at")
      assert Map.has_key?(transitions, :paid_at) or Map.has_key?(transitions, "paid_at")

      cleanup_invoice(invoice["id"])
      cleanup_customer(customer["id"])
    end

    @tag :contract
    test "invoice charge field is not present for draft invoices" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "no-charge@example.com"})

      params = %{"customer" => customer["id"]}
      {:ok, invoice} = TestClient.create_invoice(params)

      # Real Stripe doesn't include charge key at all for draft invoices (no payment yet)
      refute Map.has_key?(invoice, "charge")

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
    test "updates checkout session metadata" do
      params = %{
        "cancel_url" => "https://example.com/cancel",
        "line_items" => [
          %{
            "price_data" => %{"currency" => "usd", "product_data" => %{"name" => "Test Product"}, "unit_amount" => 2000},
            "quantity" => 1
          }
        ],
        "metadata" => %{"existing" => "yes"},
        "mode" => "payment",
        "success_url" => "https://example.com/success"
      }

      {:ok, created} = TestClient.create_checkout_session(params)

      {:ok, updated} =
        TestClient.update_checkout_session(created["id"], %{
          "metadata" => %{"existing" => "", "order_id" => "6735"}
        })

      assert updated["id"] == created["id"]
      assert updated["metadata"] == %{"order_id" => "6735"}
    end

    @tag :contract
    test "lists checkout session line items" do
      params = %{
        "cancel_url" => "https://example.com/cancel",
        "line_items" => [
          %{
            "price_data" => %{
              "currency" => "usd",
              "product_data" => %{"name" => "First Product"},
              "unit_amount" => 1200
            },
            "quantity" => 1
          },
          %{
            "price_data" => %{
              "currency" => "usd",
              "product_data" => %{"name" => "Second Product"},
              "unit_amount" => 800
            },
            "quantity" => 2
          }
        ],
        "mode" => "payment",
        "success_url" => "https://example.com/success"
      }

      {:ok, created} = TestClient.create_checkout_session(params)
      {:ok, line_items} = TestClient.list_checkout_session_line_items(created["id"], %{"limit" => 1})

      assert line_items["object"] == "list"
      assert length(line_items["data"]) == 1
      assert line_items["has_more"] == true

      [line_item] = line_items["data"]
      assert line_item["object"] == "item"
      assert line_item["amount_total"] == 1200
      assert line_item["quantity"] == 1
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

  describe "Hosted Product APIs" do
    @tag :contract
    test "creates and updates payment links with line items" do
      {:ok, payment_link} =
        TestClient.create_payment_link(%{
          "line_items" => [
            %{
              "price_data" => %{
                "currency" => "usd",
                "product_data" => %{"name" => "Payment Link Contract"},
                "unit_amount" => 1800
              },
              "quantity" => 2
            }
          ],
          "metadata" => %{"contract" => "payment_link"}
        })

      assert payment_link["object"] == "payment_link"
      assert String.starts_with?(payment_link["id"], "plink_")
      assert payment_link["active"] == true
      assert is_binary(payment_link["url"])

      {:ok, retrieved} = TestClient.get_payment_link(payment_link["id"])
      assert retrieved["id"] == payment_link["id"]
      assert retrieved["object"] == "payment_link"

      {:ok, line_items} = TestClient.list_payment_link_line_items(payment_link["id"], %{"limit" => 1})
      assert line_items["object"] == "list"
      assert length(line_items["data"]) == 1

      [line_item] = line_items["data"]
      assert line_item["object"] == "item"
      assert line_item["quantity"] == 2

      {:ok, updated} =
        TestClient.update_payment_link(payment_link["id"], %{
          "active" => false,
          "metadata" => %{"contract" => ""}
        })

      assert updated["id"] == payment_link["id"]
      assert updated["active"] == false
    end

    @tag :contract
    test "creates billing portal configurations and sessions" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "portal-contract@example.com"})

      {:ok, configuration} =
        TestClient.create_billing_portal_configuration(%{
          "default_return_url" => "https://example.com/account",
          "features" => %{
            "customer_update" => %{
              "allowed_updates" => ["email"],
              "enabled" => true
            },
            "invoice_history" => %{"enabled" => true}
          }
        })

      assert configuration["object"] == "billing_portal.configuration"
      assert String.starts_with?(configuration["id"], "bpc_")
      assert configuration["active"] == true

      {:ok, retrieved} = TestClient.get_billing_portal_configuration(configuration["id"])
      assert retrieved["id"] == configuration["id"]

      {:ok, session} =
        TestClient.create_billing_portal_session(%{
          "configuration" => configuration["id"],
          "customer" => customer["id"],
          "return_url" => "https://example.com/account"
        })

      assert session["object"] == "billing_portal.session"
      assert String.starts_with?(session["id"], "bps_")
      assert session["configuration"] == configuration["id"]
      assert session["customer"] == customer["id"]
      assert session["return_url"] == "https://example.com/account"
      assert is_binary(session["url"])

      {:ok, updated} =
        TestClient.update_billing_portal_configuration(configuration["id"], %{
          "metadata" => %{"contract" => "billing_portal"}
        })

      assert updated["metadata"]["contract"] == "billing_portal"

      cleanup_customer(customer["id"])
    end
  end

  describe "Billing Discount and Credit APIs" do
    @tag :contract
    test "creates promotion codes for coupons" do
      coupon_id = "pt_coupon_#{System.unique_integer([:positive])}"
      code = "PT-#{System.unique_integer([:positive])}"

      {:ok, coupon} =
        TestClient.create_coupon(%{
          "duration" => "forever",
          "id" => coupon_id,
          "percent_off" => 25
        })

      {:ok, promotion_code} =
        TestClient.create_promotion_code(%{
          "code" => code,
          "promotion" => %{"coupon" => coupon["id"], "type" => "coupon"}
        })

      assert promotion_code["object"] == "promotion_code"
      assert String.starts_with?(promotion_code["id"], "promo_")
      assert promotion_code["active"] == true
      assert promotion_code["code"] == code
      assert promotion_code["coupon"]["id"] == coupon["id"]

      {:ok, retrieved} = TestClient.get_promotion_code(promotion_code["id"])
      assert retrieved["id"] == promotion_code["id"]

      {:ok, updated} =
        TestClient.update_promotion_code(promotion_code["id"], %{
          "metadata" => %{"contract" => "promotion_code"}
        })

      assert updated["metadata"]["contract"] == "promotion_code"

      {:ok, list} = TestClient.list_promotion_codes(%{"code" => code, "limit" => 1})
      assert Enum.any?(list["data"], fn item -> item["id"] == promotion_code["id"] end)
    end

    @tag :contract
    test "creates customer balance transactions and retrieves cash balance" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "balance-contract@example.com"})

      {:ok, transaction} =
        TestClient.create_customer_balance_transaction(customer["id"], %{
          "amount" => -500,
          "currency" => "usd",
          "description" => "Contract credit"
        })

      assert transaction["object"] == "customer_balance_transaction"
      assert String.starts_with?(transaction["id"], "cbtxn_")
      assert transaction["amount"] == -500
      assert transaction["currency"] == "usd"
      assert transaction["customer"] == customer["id"]

      {:ok, retrieved} = TestClient.get_customer_balance_transaction(customer["id"], transaction["id"])
      assert retrieved["id"] == transaction["id"]

      {:ok, list} = TestClient.list_customer_balance_transactions(customer["id"], %{"limit" => 1})
      assert Enum.any?(list["data"], fn item -> item["id"] == transaction["id"] end)

      cash_balance_result = TestClient.get_cash_balance(customer["id"])

      case cash_balance_result do
        {:ok, cash_balance} ->
          assert cash_balance["object"] == "cash_balance"
          assert cash_balance["customer"] == customer["id"]

        {:error, error} ->
          assert error["error"]["type"] == "invalid_request_error"
      end

      cleanup_customer(customer["id"])
    end
  end

  describe "Connect Platform APIs" do
    @tag :contract
    test "creates connected accounts and account links" do
      result =
        TestClient.create_account(%{
          "capabilities" => %{"transfers" => %{"requested" => true}},
          "country" => "US",
          "email" => "connect-account-#{System.unique_integer([:positive])}@example.com",
          "type" => "express"
        })

      case result do
        {:ok, account} ->
          assert account["object"] == "account"
          assert String.starts_with?(account["id"], "acct_")
          assert Map.has_key?(account, "capabilities")

          {:ok, retrieved} = TestClient.get_account(account["id"])
          assert retrieved["id"] == account["id"]

          {:ok, link} =
            TestClient.create_account_link(%{
              "account" => account["id"],
              "refresh_url" => "https://example.test/reauth",
              "return_url" => "https://example.test/return",
              "type" => "account_onboarding"
            })

          assert link["object"] == "account_link"
          assert is_binary(link["url"])

          cleanup_account(account["id"])

        {:error, error} ->
          assert_connect_environment_error(error)
      end
    end

    @tag :contract
    test "creates transfers and reversals for connected accounts" do
      with {:ok, account} <-
             TestClient.create_account(%{
               "capabilities" => %{"transfers" => %{"requested" => true}},
               "country" => "US",
               "type" => "express"
             }),
           {:ok, transfer} <-
             TestClient.create_transfer(%{
               "amount" => 400,
               "currency" => "usd",
               "destination" => account["id"],
               "transfer_group" => "pt_contract_#{System.unique_integer([:positive])}"
             }) do
        assert transfer["object"] == "transfer"
        assert String.starts_with?(transfer["id"], "tr_")
        assert transfer["amount"] == 400
        assert transfer["destination"] == account["id"]
        assert Map.has_key?(transfer, "reversals")

        {:ok, reversal} = TestClient.create_transfer_reversal(transfer["id"], %{"amount" => 100})
        assert reversal["object"] == "transfer_reversal"
        assert reversal["amount"] == 100
        assert reversal["transfer"] == transfer["id"]

        {:ok, reversals} = TestClient.list_transfer_reversals(transfer["id"], %{"limit" => 1})
        assert is_list(reversals["data"])

        cleanup_account(account["id"])
      else
        {:error, error} ->
          assert_connect_environment_error(error)
      end
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
    test "sends a finalized send_invoice invoice" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "send-invoice@example.com"})

      if TestClient.real_stripe?() do
        {:ok, _item} =
          TestClient.create_invoice_item(%{
            "amount" => 1500,
            "currency" => "usd",
            "customer" => customer["id"]
          })
      end

      {:ok, invoice} =
        TestClient.create_invoice(%{
          "auto_advance" => false,
          "collection_method" => "send_invoice",
          "customer" => customer["id"],
          "days_until_due" => 30
        })

      if !TestClient.real_stripe?() do
        {:ok, _item} =
          TestClient.create_invoice_item(%{
            "amount" => 1500,
            "currency" => "usd",
            "customer" => customer["id"],
            "invoice" => invoice["id"]
          })
      end

      {:ok, finalized} = TestClient.finalize_invoice(invoice["id"])
      assert finalized["status"] == "open"

      {:ok, sent} = TestClient.send_invoice(invoice["id"])

      assert sent["id"] == invoice["id"]
      assert sent["status"] == "open"
      assert sent["collection_method"] == "send_invoice"
      assert is_binary(sent["hosted_invoice_url"])
      assert is_binary(sent["invoice_pdf"])

      cleanup_invoice(invoice["id"])
      cleanup_customer(customer["id"])
    end

    @tag :contract
    test "marks a finalized invoice uncollectible" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "mark-uncollectible@example.com"})

      if TestClient.real_stripe?() do
        {:ok, _item} =
          TestClient.create_invoice_item(%{
            "amount" => 2200,
            "currency" => "usd",
            "customer" => customer["id"]
          })
      end

      {:ok, invoice} =
        TestClient.create_invoice(%{
          "auto_advance" => false,
          "collection_method" => "send_invoice",
          "customer" => customer["id"],
          "days_until_due" => 30
        })

      if !TestClient.real_stripe?() do
        {:ok, _item} =
          TestClient.create_invoice_item(%{
            "amount" => 2200,
            "currency" => "usd",
            "customer" => customer["id"],
            "invoice" => invoice["id"]
          })
      end

      {:ok, finalized} = TestClient.finalize_invoice(invoice["id"])
      assert finalized["status"] == "open"

      {:ok, uncollectible} = TestClient.mark_invoice_uncollectible(invoice["id"])

      assert uncollectible["id"] == invoice["id"]
      assert uncollectible["status"] == "uncollectible"
      assert uncollectible["amount_remaining"] == uncollectible["amount_due"]

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

  defp cleanup_account(account_id) do
    if TestClient.real_stripe?() do
      TestClient.delete_account(account_id)
    end
  end

  defp assert_connect_environment_error(error) do
    if TestClient.real_stripe?() do
      assert error["error"]["type"] in ["invalid_request_error", "api_error"]
    else
      flunk("Unexpected PaperTiger Connect error: #{inspect(error)}")
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

  defp unique_suffix do
    "#{System.system_time(:nanosecond)}_#{System.unique_integer([:positive])}"
  end

  defp eventually_search_customer(query, customer_id) do
    attempts = if TestClient.real_stripe?(), do: 20, else: 1

    1..attempts
    |> Enum.find_value(fn attempt ->
      query
      |> search_customer_once(customer_id)
      |> handle_search_attempt(attempt, attempts)
    end)
    |> case do
      nil -> flunk("Customer #{customer_id} did not appear in search results for #{inspect(query)}")
      result -> result
    end
  end

  defp search_customer_once(query, customer_id) do
    case TestClient.search_customers(%{"limit" => 10, "query" => query}) do
      {:ok, result} -> maybe_found_customer(result, customer_id)
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_found_customer(result, customer_id) do
    if Enum.any?(result["data"], fn item -> item["id"] == customer_id end) do
      {:found, result}
    else
      :missing
    end
  end

  defp handle_search_attempt({:found, result}, _attempt, _attempts), do: result

  defp handle_search_attempt(:missing, attempt, attempts) do
    maybe_wait_for_search_index(attempt, attempts)
    nil
  end

  defp handle_search_attempt({:error, error}, _attempt, _attempts) do
    flunk("Customer search failed: #{inspect(error)}")
  end

  defp maybe_wait_for_search_index(attempt, attempts) when attempt < attempts and attempts > 1 do
    Process.sleep(3_000)
  end

  defp maybe_wait_for_search_index(_attempt, _attempts), do: :ok
end
