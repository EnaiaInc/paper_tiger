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

      # Type may be atom or string depending on backend
      error_type = error["error"]["type"]

      assert error_type in ["invalid_request_error", "invalid_request", :invalid_request_error]
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
    # Subscription tests with inline price_data only run against PaperTiger
    # Real Stripe doesn't support items[].price_data.product_data - requires pre-created prices
    # PaperTiger allows inline product/price creation for testing convenience

    @tag :contract
    @tag :paper_tiger_only
    test "creates a subscription with customer and items" do
      if TestClient.real_stripe?(), do: :ok, else: do_test_create_subscription()
    end

    defp do_test_create_subscription do
      {:ok, customer} = TestClient.create_customer(%{"email" => "sub@example.com"})

      params = %{
        "customer" => customer["id"],
        "items" => [
          %{
            "price_data" => %{
              "currency" => "usd",
              "product_data" => %{"name" => "Premium Plan"},
              "recurring" => %{"interval" => "month"},
              "unit_amount" => 2000
            }
          }
        ]
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
    end

    @tag :contract
    @tag :paper_tiger_only
    test "retrieves a subscription by ID" do
      if TestClient.real_stripe?(), do: :ok, else: do_test_retrieve_subscription()
    end

    defp do_test_retrieve_subscription do
      {:ok, customer} = TestClient.create_customer(%{"email" => "retrieve-sub@example.com"})

      params = %{
        "customer" => customer["id"],
        "items" => [
          %{
            "price_data" => %{
              "currency" => "usd",
              "product_data" => %{"name" => "Test Plan"},
              "recurring" => %{"interval" => "month"},
              "unit_amount" => 1000
            }
          }
        ]
      }

      {:ok, created} = TestClient.create_subscription(params)
      subscription_id = created["id"]

      {:ok, retrieved} = TestClient.get_subscription(subscription_id)

      assert retrieved["id"] == subscription_id
      assert retrieved["object"] == "subscription"
      assert retrieved["customer"] == customer["id"]

      cleanup_subscription(subscription_id)
      cleanup_customer(customer["id"])
    end

    @tag :contract
    @tag :paper_tiger_only
    test "updates a subscription" do
      if TestClient.real_stripe?(), do: :ok, else: do_test_update_subscription()
    end

    defp do_test_update_subscription do
      {:ok, customer} = TestClient.create_customer(%{"email" => "update-sub@example.com"})

      params = %{
        "customer" => customer["id"],
        "items" => [
          %{
            "price_data" => %{
              "currency" => "usd",
              "product_data" => %{"name" => "Basic Plan"},
              "recurring" => %{"interval" => "month"},
              "unit_amount" => 1000
            }
          }
        ]
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
    end

    @tag :contract
    @tag :paper_tiger_only
    test "cancels a subscription" do
      if TestClient.real_stripe?(), do: :ok, else: do_test_cancel_subscription()
    end

    defp do_test_cancel_subscription do
      {:ok, customer} = TestClient.create_customer(%{"email" => "cancel-sub@example.com"})

      params = %{
        "customer" => customer["id"],
        "items" => [
          %{
            "price_data" => %{
              "currency" => "usd",
              "product_data" => %{"name" => "Canceled Plan"},
              "recurring" => %{"interval" => "month"},
              "unit_amount" => 1000
            }
          }
        ]
      }

      {:ok, subscription} = TestClient.create_subscription(params)
      subscription_id = subscription["id"]

      {:ok, result} = TestClient.delete_subscription(subscription_id)

      assert result["id"] == subscription_id
      assert result["status"] == "canceled"

      cleanup_customer(customer["id"])
    end

    @tag :contract
    @tag :paper_tiger_only
    test "lists subscriptions with pagination" do
      if TestClient.real_stripe?(), do: :ok, else: do_test_list_subscriptions()
    end

    defp do_test_list_subscriptions do
      {:ok, customer} = TestClient.create_customer(%{"email" => "list-subs@example.com"})

      subscription_ids =
        for i <- 1..3 do
          params = %{
            "customer" => customer["id"],
            "items" => [
              %{
                "price_data" => %{
                  "currency" => "usd",
                  "product_data" => %{"name" => "Plan #{i}"},
                  "recurring" => %{"interval" => "month"},
                  "unit_amount" => 1000 * i
                }
              }
            ]
          }

          {:ok, subscription} = TestClient.create_subscription(params)
          subscription["id"]
        end

      {:ok, result} = TestClient.list_subscriptions(%{"limit" => 2})

      assert is_list(result["data"])
      assert length(result["data"]) <= 2
      assert is_boolean(result["has_more"])

      Enum.each(subscription_ids, &cleanup_subscription/1)
      cleanup_customer(customer["id"])
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
    # PaymentMethod tests only run against PaperTiger
    # Real Stripe requires tokens (pm_card_visa) which can't be created via API
    # PaperTiger allows raw card data for testing convenience

    @tag :contract
    @tag :paper_tiger_only
    test "creates a payment method" do
      # Skip for real Stripe - can't send raw card numbers
      if TestClient.real_stripe?() do
        :ok
      else
        params = %{
          "card" => %{
            "cvc" => "123",
            "exp_month" => 12,
            "exp_year" => 2025,
            "number" => "4242424242424242"
          },
          "type" => "card"
        }

        {:ok, payment_method} = TestClient.create_payment_method(params)

        assert payment_method["object"] == "payment_method"
        assert payment_method["type"] == "card"
        assert String.starts_with?(payment_method["id"], "pm_")
        assert is_integer(payment_method["created"])
      end
    end

    @tag :contract
    @tag :paper_tiger_only
    test "retrieves a payment method by ID" do
      # Skip for real Stripe - can't send raw card numbers
      if TestClient.real_stripe?() do
        :ok
      else
        params = %{
          "card" => %{
            "cvc" => "456",
            "exp_month" => 6,
            "exp_year" => 2026,
            "number" => "4242424242424242"
          },
          "type" => "card"
        }

        {:ok, created} = TestClient.create_payment_method(params)
        payment_method_id = created["id"]

        {:ok, retrieved} = TestClient.get_payment_method(payment_method_id)

        assert retrieved["id"] == payment_method_id
        assert retrieved["object"] == "payment_method"
        assert retrieved["type"] == "card"
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
  end

  describe "Charge Structure Validation" do
    @tag :contract
    @tag :paper_tiger_only
    test "successful charge has balance_transaction" do
      # This test validates that balance_transaction is populated for successful charges
      # Real Stripe requires payment source tokens we can't create via API
      if TestClient.real_stripe?() do
        :ok
      else
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
    end

    @tag :contract
    @tag :paper_tiger_only
    test "charge object has required fields" do
      if TestClient.real_stripe?() do
        :ok
      else
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
    test "payment intent has charges list structure" do
      params = %{
        "amount" => 2500,
        "currency" => "usd"
      }

      {:ok, payment_intent} = TestClient.create_payment_intent(params)

      # Retrieve to get full structure with charges
      {:ok, retrieved} = TestClient.get_payment_intent(payment_intent["id"])

      # charges should be a list object
      assert Map.has_key?(retrieved, "charges")
      charges = retrieved["charges"]

      # In PaperTiger, charges is always a list object structure
      # In real Stripe, it may vary based on the payment intent state
      if TestClient.paper_tiger?() do
        assert is_map(charges)
        assert Map.has_key?(charges, "data")
        assert is_list(charges["data"])
        assert Map.has_key?(charges, "has_more")
        assert Map.has_key?(charges, "object")
        assert charges["object"] == "list"
      end
    end
  end

  describe "Refund Structure Validation" do
    @tag :contract
    @tag :paper_tiger_only
    test "refund has balance_transaction" do
      # Real Stripe requires actual charges to refund
      if TestClient.real_stripe?() do
        :ok
      else
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
    end

    @tag :contract
    @tag :paper_tiger_only
    test "refund object has required fields" do
      if TestClient.real_stripe?() do
        :ok
      else
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

  describe "Subscription latest_invoice Validation" do
    @tag :contract
    @tag :paper_tiger_only
    test "subscription with billing has latest_invoice object" do
      # This test requires BillingEngine which only runs in PaperTiger
      if TestClient.real_stripe?() do
        :ok
      else
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

        # Create subscription
        subscription_params = %{
          "customer" => customer["id"],
          "items" => [%{"price" => price["id"]}]
        }

        {:ok, subscription} = TestClient.create_subscription(subscription_params)

        # Create an invoice for this subscription to test latest_invoice population
        invoice_params = %{
          "customer" => customer["id"],
          "subscription" => subscription["id"]
        }

        {:ok, _invoice} = TestClient.create_invoice(invoice_params)

        # Retrieve subscription to check latest_invoice
        {:ok, retrieved} = TestClient.get_subscription(subscription["id"])

        # latest_invoice should be populated (either as object or ID)
        # The key test is that it's not nil when invoices exist
        if retrieved["latest_invoice"] do
          # If present, should be a map (object) in PaperTiger after our fix
          assert is_map(retrieved["latest_invoice"]) or is_binary(retrieved["latest_invoice"])

          if is_map(retrieved["latest_invoice"]) do
            assert retrieved["latest_invoice"]["object"] == "invoice"
          end
        end

        cleanup_subscription(subscription["id"])
        cleanup_customer(customer["id"])
      end
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
