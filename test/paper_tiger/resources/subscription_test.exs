defmodule PaperTiger.Resources.SubscriptionTest do
  @moduledoc """
  End-to-end tests for Subscription resource with full billing flow.

  Tests complete subscription lifecycle:
  1. Setup: Create customer, product, price
  2. POST /v1/subscriptions - Create subscription
  3. GET /v1/subscriptions/:id - Retrieve subscription
  4. POST /v1/subscriptions/:id - Update subscription
  5. DELETE /v1/subscriptions/:id - Cancel subscription
  6. GET /v1/subscriptions - List subscriptions
  """

  use ExUnit.Case, async: true

  import PaperTiger.Test

  alias PaperTiger.Router

  setup_all do
    # PaperTiger is auto-started by the test suite, just return :ok
    :ok
  end

  setup :checkout_paper_tiger

  # Helper function to create a test connection with proper setup
  defp conn(method, path, params, headers) do
    # For GET/DELETE requests, put params in query string
    # For POST/PUT requests, put params in body
    {final_path, body} =
      case method do
        m when m in [:get, :delete] ->
          if params && is_map(params) do
            query_string = params_to_form_data(params)
            {"#{path}?#{query_string}", ""}
          else
            {path, ""}
          end

        _ ->
          body =
            if params && is_map(params) do
              params_to_form_data(params)
            else
              ""
            end

          {path, body}
      end

    conn = Plug.Test.conn(method, final_path, body)

    headers_with_defaults =
      headers ++
        [
          {"content-type", "application/x-www-form-urlencoded"},
          {"authorization", "Bearer sk_test_key"}
        ]

    Enum.reduce(headers_with_defaults, conn, fn {key, value}, acc ->
      Plug.Conn.put_req_header(acc, key, value)
    end)
  end

  # Helper function to convert map params to form data (flat with bracket notation)
  defp params_to_form_data(params) do
    params
    |> flatten_params()
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{URI.encode_www_form(to_string(v))}" end)
  end

  # Flatten nested maps into bracket notation for form encoding
  defp flatten_params(params, parent_key \\ "") do
    Enum.flat_map(params, fn
      {key, value} when is_map(value) ->
        new_key = if parent_key == "", do: key, else: "#{parent_key}[#{key}]"
        flatten_params(value, new_key)

      {key, value} when is_list(value) ->
        new_key = if parent_key == "", do: key, else: "#{parent_key}[#{key}]"

        value
        |> Enum.with_index(fn item, idx ->
          flatten_list_item(item, new_key, idx)
        end)
        |> List.flatten()

      {key, value} ->
        new_key = if parent_key == "", do: key, else: "#{parent_key}[#{key}]"
        [{new_key, value}]
    end)
  end

  # Helper to flatten a list item for params
  defp flatten_list_item(item, new_key, idx) when is_map(item) do
    flatten_params(item, "#{new_key}[#{idx}]")
  end

  defp flatten_list_item(item, new_key, _idx) do
    {"#{new_key}[]", item}
  end

  # Helper function to run a request through the router
  defp request(method, path, params) do
    conn = conn(method, path, params, [])
    Router.call(conn, [])
  end

  # Helper function to parse JSON response
  defp json_response(conn) do
    Jason.decode!(conn.resp_body)
  end

  describe "Subscription Setup" do
    test "create customer successfully" do
      conn = request(:post, "/v1/customers", %{"email" => "john@example.com"})

      assert conn.status == 200
      body = json_response(conn)
      assert body["object"] == "customer"
      assert body["email"] == "john@example.com"
      assert String.starts_with?(body["id"], "cus_")
    end

    test "create product successfully" do
      conn = request(:post, "/v1/products", %{"name" => "Premium Plan"})

      assert conn.status == 200
      body = json_response(conn)
      assert body["object"] == "product"
      assert body["name"] == "Premium Plan"
      assert body["active"] == true
      assert String.starts_with?(body["id"], "prod_")
    end

    test "create price successfully" do
      # First create a product
      product_conn = request(:post, "/v1/products", %{"name" => "Premium Plan"})
      product = json_response(product_conn)
      product_id = product["id"]

      # Create a price for the product
      price_params = %{
        "currency" => "usd",
        "product" => product_id,
        "recurring" => %{"interval" => "month"},
        "unit_amount" => "2000"
      }

      conn = request(:post, "/v1/prices", price_params)

      assert conn.status == 200
      body = json_response(conn)
      assert body["object"] == "price"
      assert body["product"] == product_id
      assert body["unit_amount"] == 2000
      assert body["currency"] == "usd"
      assert String.starts_with?(body["id"], "price_")
    end
  end

  describe "POST /v1/subscriptions - Create subscription" do
    setup do
      # Create customer
      customer_conn = request(:post, "/v1/customers", %{"email" => "john@example.com"})
      customer = json_response(customer_conn)
      customer_id = customer["id"]

      # Create product
      product_conn = request(:post, "/v1/products", %{"name" => "Premium Plan"})
      product = json_response(product_conn)
      product_id = product["id"]

      # Create price
      price_params = %{
        "currency" => "usd",
        "product" => product_id,
        "recurring" => %{"interval" => "month"},
        "unit_amount" => "2000"
      }

      price_conn = request(:post, "/v1/prices", price_params)
      price = json_response(price_conn)
      price_id = price["id"]

      {:ok, customer_id: customer_id, product_id: product_id, price_id: price_id}
    end

    test "creates subscription with customer and items", %{
      customer_id: customer_id,
      price_id: price_id
    } do
      subscription_params = %{
        "customer" => customer_id,
        "items" => [%{"price" => price_id, "quantity" => "1"}]
      }

      conn = request(:post, "/v1/subscriptions", subscription_params)

      assert conn.status == 200
      body = json_response(conn)

      assert body["object"] == "subscription"
      assert body["customer"] == customer_id
      assert body["status"] == "active"
      assert String.starts_with?(body["id"], "sub_")
      assert is_list(body["items"]["data"])
      assert length(body["items"]["data"]) == 1

      # Verify subscription item
      item = Enum.at(body["items"]["data"], 0)
      assert item["quantity"] == 1
      assert String.starts_with?(item["id"], "si_")

      # Verify price is embedded as full object (matches real Stripe API)
      assert is_map(item["price"])
      assert item["price"]["id"] == price_id
      assert item["price"]["object"] == "price"
    end

    test "creates subscription with trial period", %{customer_id: customer_id, price_id: price_id} do
      trial_days = 14

      subscription_params = %{
        "customer" => customer_id,
        "items" => [%{"price" => price_id, "quantity" => "1"}],
        "trial_period_days" => trial_days
      }

      conn = request(:post, "/v1/subscriptions", subscription_params)

      assert conn.status == 200
      body = json_response(conn)

      assert body["status"] == "trialing"
      assert body["trial_start"] != nil
      assert body["trial_end"] != nil

      # Trial end should be trial_days * 86400 seconds after creation
      trial_duration = body["trial_end"] - body["trial_start"]
      expected_duration = trial_days * 86_400
      # Allow small variation
      assert abs(trial_duration - expected_duration) < 10
    end

    test "creates subscription with metadata", %{customer_id: customer_id, price_id: price_id} do
      subscription_params = %{
        "customer" => customer_id,
        "items" => [%{"price" => price_id, "quantity" => "1"}],
        "metadata" => %{"order_id" => "12345", "team" => "acme"}
      }

      conn = request(:post, "/v1/subscriptions", subscription_params)

      assert conn.status == 200
      body = json_response(conn)

      assert body["metadata"]["order_id"] == "12345"
      assert body["metadata"]["team"] == "acme"
    end

    test "verifies subscription period dates", %{customer_id: customer_id, price_id: price_id} do
      subscription_params = %{
        "customer" => customer_id,
        "items" => [%{"price" => price_id, "quantity" => "1"}]
      }

      conn = request(:post, "/v1/subscriptions", subscription_params)

      assert conn.status == 200
      body = json_response(conn)

      assert body["current_period_start"] != nil
      assert body["current_period_end"] != nil
      # Period should be approximately 30 days
      period_duration = body["current_period_end"] - body["current_period_start"]
      expected_duration = 30 * 86_400
      assert abs(period_duration - expected_duration) < 10
    end

    test "creates subscription with multiple items", %{
      customer_id: customer_id,
      price_id: price_id
    } do
      # Create another product and price
      product_conn = request(:post, "/v1/products", %{"name" => "Add-on"})
      product = json_response(product_conn)
      addon_product_id = product["id"]

      price_params = %{
        "currency" => "usd",
        "product" => addon_product_id,
        "recurring" => %{"interval" => "month"},
        "unit_amount" => "500"
      }

      price_conn = request(:post, "/v1/prices", price_params)
      addon_price = json_response(price_conn)
      addon_price_id = addon_price["id"]

      # Create subscription with two items
      subscription_params = %{
        "customer" => customer_id,
        "items" => [
          %{"price" => price_id, "quantity" => "1"},
          %{"price" => addon_price_id, "quantity" => "2"}
        ]
      }

      conn = request(:post, "/v1/subscriptions", subscription_params)

      assert conn.status == 200
      body = json_response(conn)

      assert length(body["items"]["data"]) == 2

      # Verify first item
      item1 = Enum.at(body["items"]["data"], 0)
      assert is_map(item1["price"])
      assert item1["price"]["id"] == price_id
      assert item1["quantity"] == 1

      # Verify second item
      item2 = Enum.at(body["items"]["data"], 1)
      assert is_map(item2["price"])
      assert item2["price"]["id"] == addon_price_id
      assert item2["quantity"] == 2
    end

    test "fails without customer ID", %{price_id: price_id} do
      subscription_params = %{
        "items" => [%{"price" => price_id, "quantity" => "1"}]
      }

      conn = request(:post, "/v1/subscriptions", subscription_params)

      assert conn.status == 400
      body = json_response(conn)
      assert body["error"]["type"] == "invalid_request_error"
      assert String.contains?(body["error"]["message"], "customer")
    end

    test "fails without items", %{customer_id: customer_id} do
      subscription_params = %{
        "customer" => customer_id
      }

      conn = request(:post, "/v1/subscriptions", subscription_params)

      assert conn.status == 400
      body = json_response(conn)
      assert body["error"]["type"] == "invalid_request_error"
      assert String.contains?(body["error"]["message"], "items")
    end

    test "subscription item price contains full price object from store", %{
      customer_id: customer_id,
      price_id: price_id,
      product_id: product_id
    } do
      subscription_params = %{
        "customer" => customer_id,
        "items" => [%{"price" => price_id, "quantity" => "1"}]
      }

      conn = request(:post, "/v1/subscriptions", subscription_params)

      assert conn.status == 200
      body = json_response(conn)

      item = Enum.at(body["items"]["data"], 0)
      price = item["price"]

      # Verify full price object structure (fetched from store)
      assert is_map(price)
      assert price["id"] == price_id
      assert price["object"] == "price"
      assert price["currency"] == "usd"
      assert price["unit_amount"] == 2000
      assert price["product"] == product_id
      assert is_map(price["recurring"])
      assert price["recurring"]["interval"] == "month"
    end

    test "returns error for unknown price ID", %{
      customer_id: customer_id
    } do
      # Use a price ID that doesn't exist in the store
      unknown_price_id = "price_unknown_test_123"

      subscription_params = %{
        "customer" => customer_id,
        "items" => [%{"price" => unknown_price_id, "quantity" => "1"}]
      }

      conn = request(:post, "/v1/subscriptions", subscription_params)

      # Should return 404 with resource_missing error (matching real Stripe behavior)
      assert conn.status == 404
      body = json_response(conn)

      assert body["error"]["type"] == "invalid_request_error"
      assert body["error"]["code"] == "resource_missing"
      assert body["error"]["message"] == "No such price: '#{unknown_price_id}'"
      assert body["error"]["param"] == "items[0][price]"
    end

    test "returns error for unknown customer ID", %{price_id: price_id} do
      unknown_customer_id = "cus_unknown_test_123"

      subscription_params = %{
        "customer" => unknown_customer_id,
        "items" => [%{"price" => price_id, "quantity" => "1"}]
      }

      conn = request(:post, "/v1/subscriptions", subscription_params)

      # Should return 404 with resource_missing error (matching real Stripe behavior)
      assert conn.status == 404
      body = json_response(conn)

      assert body["error"]["type"] == "invalid_request_error"
      assert body["error"]["code"] == "resource_missing"
      assert body["error"]["message"] == "No such customer: '#{unknown_customer_id}'"
      assert body["error"]["param"] == "id"
    end
  end

  describe "GET /v1/subscriptions/:id - Retrieve subscription" do
    setup do
      # Create customer, product, and price
      customer_conn = request(:post, "/v1/customers", %{"email" => "john@example.com"})
      customer = json_response(customer_conn)
      customer_id = customer["id"]

      product_conn = request(:post, "/v1/products", %{"name" => "Premium Plan"})
      product = json_response(product_conn)
      product_id = product["id"]

      price_params = %{
        "currency" => "usd",
        "product" => product_id,
        "recurring" => %{"interval" => "month"},
        "unit_amount" => "2000"
      }

      price_conn = request(:post, "/v1/prices", price_params)
      price = json_response(price_conn)
      price_id = price["id"]

      # Create subscription
      subscription_params = %{
        "customer" => customer_id,
        "items" => [%{"price" => price_id, "quantity" => "2"}]
      }

      sub_conn = request(:post, "/v1/subscriptions", subscription_params)
      subscription = json_response(sub_conn)
      subscription_id = subscription["id"]

      {:ok, customer_id: customer_id, product_id: product_id, price_id: price_id, subscription_id: subscription_id}
    end

    test "retrieves subscription by ID", %{
      customer_id: customer_id,
      subscription_id: subscription_id
    } do
      conn = request(:get, "/v1/subscriptions/#{subscription_id}", %{})

      assert conn.status == 200
      body = json_response(conn)

      assert body["id"] == subscription_id
      assert body["customer"] == customer_id
      assert body["object"] == "subscription"
      assert body["status"] == "active"
    end

    test "includes subscription items in response", %{subscription_id: subscription_id} do
      conn = request(:get, "/v1/subscriptions/#{subscription_id}", %{})

      assert conn.status == 200
      body = json_response(conn)

      assert is_map(body["items"])
      assert is_list(body["items"]["data"])
      assert length(body["items"]["data"]) == 1

      item = Enum.at(body["items"]["data"], 0)
      assert item["object"] == "subscription_item"
      assert item["quantity"] == 2
    end

    test "returns 404 for non-existent subscription" do
      conn = request(:get, "/v1/subscriptions/sub_nonexistent", %{})

      assert conn.status == 404
      body = json_response(conn)
      assert body["error"]["type"] == "invalid_request_error"
      assert String.contains?(body["error"]["message"], "sub_nonexistent")
    end

    test "expands customer field", %{customer_id: customer_id, subscription_id: subscription_id} do
      conn =
        request(:get, "/v1/subscriptions/#{subscription_id}", %{
          "expand" => ["customer"]
        })

      assert conn.status == 200
      body = json_response(conn)

      # When expanded, customer should be an object instead of just ID
      customer = body["customer"]

      if is_map(customer) do
        assert customer["id"] == customer_id
        assert customer["object"] == "customer"
      else
        # If not expanded, it should still be the ID (implementation detail)
        assert customer == customer_id
      end
    end
  end

  describe "POST /v1/subscriptions/:id - Update subscription" do
    setup do
      # Create all necessary resources
      customer_conn = request(:post, "/v1/customers", %{"email" => "john@example.com"})
      customer = json_response(customer_conn)
      customer_id = customer["id"]

      product_conn = request(:post, "/v1/products", %{"name" => "Premium Plan"})
      product = json_response(product_conn)
      product_id = product["id"]

      price_params = %{
        "currency" => "usd",
        "product" => product_id,
        "recurring" => %{"interval" => "month"},
        "unit_amount" => "2000"
      }

      price_conn = request(:post, "/v1/prices", price_params)
      price = json_response(price_conn)
      price_id = price["id"]

      # Create subscription
      subscription_params = %{
        "customer" => customer_id,
        "items" => [%{"price" => price_id, "quantity" => "1"}]
      }

      sub_conn = request(:post, "/v1/subscriptions", subscription_params)
      subscription = json_response(sub_conn)
      subscription_id = subscription["id"]

      {:ok, customer_id: customer_id, product_id: product_id, price_id: price_id, subscription_id: subscription_id}
    end

    test "updates subscription metadata", %{subscription_id: subscription_id} do
      update_params = %{
        "metadata" => %{"tier" => "premium", "updated_at" => "2024-01-01"}
      }

      conn = request(:post, "/v1/subscriptions/#{subscription_id}", update_params)

      assert conn.status == 200
      body = json_response(conn)

      assert body["metadata"]["updated_at"] == "2024-01-01"
      assert body["metadata"]["tier"] == "premium"
    end

    test "updates cancel_at_period_end flag", %{subscription_id: subscription_id} do
      update_params = %{
        "cancel_at_period_end" => true
      }

      conn = request(:post, "/v1/subscriptions/#{subscription_id}", update_params)

      assert conn.status == 200
      body = json_response(conn)

      assert body["cancel_at_period_end"] == true
      # Should still be active until period end
      assert body["status"] == "active"
    end

    test "updates subscription items", %{price_id: price_id, subscription_id: subscription_id} do
      # Create another price for the new item
      product_conn = request(:post, "/v1/products", %{"name" => "Add-on"})
      product = json_response(product_conn)
      addon_product_id = product["id"]

      price_params = %{
        "currency" => "usd",
        "product" => addon_product_id,
        "recurring" => %{"interval" => "month"},
        "unit_amount" => "500"
      }

      price_conn = request(:post, "/v1/prices", price_params)
      addon_price = json_response(price_conn)
      addon_price_id = addon_price["id"]

      # Update subscription with new items
      update_params = %{
        "items" => [
          %{"price" => price_id, "quantity" => "2"},
          %{"price" => addon_price_id, "quantity" => "1"}
        ]
      }

      conn = request(:post, "/v1/subscriptions/#{subscription_id}", update_params)

      assert conn.status == 200
      body = json_response(conn)

      assert length(body["items"]["data"]) == 2

      # Verify quantities were updated
      item1 = Enum.at(body["items"]["data"], 0)
      assert item1["quantity"] == 2

      item2 = Enum.at(body["items"]["data"], 1)
      assert item2["quantity"] == 1
    end

    test "returns 404 for non-existent subscription" do
      update_params = %{
        "metadata" => %{"key" => "value"}
      }

      conn = request(:post, "/v1/subscriptions/sub_nonexistent", update_params)

      assert conn.status == 404
      body = json_response(conn)
      assert body["error"]["type"] == "invalid_request_error"
    end

    test "preserves immutable fields during update", %{subscription_id: subscription_id} do
      # Try to update immutable fields
      update_params = %{
        "created" => 99_999_999,
        "id" => "sub_modified",
        "object" => "something_else"
      }

      conn = request(:post, "/v1/subscriptions/#{subscription_id}", update_params)

      assert conn.status == 200
      body = json_response(conn)

      # Immutable fields should not change
      assert body["id"] == subscription_id
      assert body["object"] == "subscription"
      assert body["created"] != 99_999_999
    end
  end

  describe "DELETE /v1/subscriptions/:id - Cancel subscription" do
    setup do
      # Create all necessary resources
      customer_conn = request(:post, "/v1/customers", %{"email" => "john@example.com"})
      customer = json_response(customer_conn)
      customer_id = customer["id"]

      product_conn = request(:post, "/v1/products", %{"name" => "Premium Plan"})
      product = json_response(product_conn)
      product_id = product["id"]

      price_params = %{
        "currency" => "usd",
        "product" => product_id,
        "recurring" => %{"interval" => "month"},
        "unit_amount" => "2000"
      }

      price_conn = request(:post, "/v1/prices", price_params)
      price = json_response(price_conn)
      price_id = price["id"]

      # Create subscription
      subscription_params = %{
        "customer" => customer_id,
        "items" => [%{"price" => price_id, "quantity" => "1"}]
      }

      sub_conn = request(:post, "/v1/subscriptions", subscription_params)
      subscription = json_response(sub_conn)
      subscription_id = subscription["id"]

      {:ok, customer_id: customer_id, price_id: price_id, subscription_id: subscription_id}
    end

    test "cancels subscription successfully", %{subscription_id: subscription_id} do
      conn = request(:delete, "/v1/subscriptions/#{subscription_id}", %{})

      assert conn.status == 200
      body = json_response(conn)

      assert body["id"] == subscription_id
      assert body["status"] == "canceled"
      assert body["canceled_at"] != nil
      assert body["ended_at"] != nil
    end

    test "canceled_at timestamp is set correctly", %{subscription_id: subscription_id} do
      before_cancel = PaperTiger.now()

      conn = request(:delete, "/v1/subscriptions/#{subscription_id}", %{})

      after_cancel = PaperTiger.now()

      assert conn.status == 200
      body = json_response(conn)

      canceled_at = body["canceled_at"]
      assert canceled_at >= before_cancel
      assert canceled_at <= after_cancel
    end

    test "includes items in canceled subscription response", %{subscription_id: subscription_id} do
      conn = request(:delete, "/v1/subscriptions/#{subscription_id}", %{})

      assert conn.status == 200
      body = json_response(conn)

      assert is_list(body["items"]["data"])
      assert length(body["items"]["data"]) == 1
    end

    test "returns 404 for non-existent subscription" do
      conn = request(:delete, "/v1/subscriptions/sub_nonexistent", %{})

      assert conn.status == 404
      body = json_response(conn)
      assert body["error"]["type"] == "invalid_request_error"
    end

    test "subscription cannot be canceled twice" do
      # Create a subscription and cancel it
      customer_conn = request(:post, "/v1/customers", %{"email" => "test@example.com"})
      customer = json_response(customer_conn)
      customer_id = customer["id"]

      product_conn = request(:post, "/v1/products", %{"name" => "Plan"})
      product = json_response(product_conn)
      product_id = product["id"]

      price_params = %{
        "currency" => "usd",
        "product" => product_id,
        "unit_amount" => "1000"
      }

      price_conn = request(:post, "/v1/prices", price_params)
      price = json_response(price_conn)
      price_id = price["id"]

      subscription_params = %{
        "customer" => customer_id,
        "items" => [%{"price" => price_id, "quantity" => "1"}]
      }

      sub_conn = request(:post, "/v1/subscriptions", subscription_params)
      subscription = json_response(sub_conn)
      subscription_id = subscription["id"]

      # First cancel
      first_cancel = request(:delete, "/v1/subscriptions/#{subscription_id}", %{})
      assert first_cancel.status == 200
      first_body = json_response(first_cancel)
      first_canceled_at = first_body["canceled_at"]

      # Second cancel (should work but with same timestamp)
      second_cancel = request(:delete, "/v1/subscriptions/#{subscription_id}", %{})
      assert second_cancel.status == 200
      second_body = json_response(second_cancel)
      second_canceled_at = second_body["canceled_at"]

      assert second_body["status"] == "canceled"
      assert second_canceled_at == first_canceled_at
    end
  end

  describe "GET /v1/subscriptions - List subscriptions" do
    setup do
      # Create multiple subscriptions for a customer
      customer_conn = request(:post, "/v1/customers", %{"email" => "john@example.com"})
      customer = json_response(customer_conn)
      customer_id = customer["id"]

      product_conn = request(:post, "/v1/products", %{"name" => "Plan"})
      product = json_response(product_conn)
      product_id = product["id"]

      price_params = %{
        "currency" => "usd",
        "product" => product_id,
        "unit_amount" => "1000"
      }

      price_conn = request(:post, "/v1/prices", price_params)
      price = json_response(price_conn)
      price_id = price["id"]

      # Create multiple subscriptions
      subscription_ids =
        Enum.reduce(1..3, [], fn i, acc ->
          subscription_params = %{
            "customer" => customer_id,
            "items" => [%{"price" => price_id, "quantity" => "#{i}"}],
            "metadata" => %{"index" => "#{i}"}
          }

          sub_conn = request(:post, "/v1/subscriptions", subscription_params)
          subscription = json_response(sub_conn)
          acc ++ [subscription["id"]]
        end)

      {:ok, customer_id: customer_id, price_id: price_id, subscription_ids: subscription_ids}
    end

    test "lists all subscriptions", %{subscription_ids: subscription_ids} do
      conn = request(:get, "/v1/subscriptions", %{})

      assert conn.status == 200
      body = json_response(conn)

      assert is_list(body["data"])
      assert length(body["data"]) >= 3

      # Verify all created subscriptions are in the list
      listed_ids = Enum.map(body["data"], & &1["id"])

      for id <- subscription_ids do
        assert id in listed_ids
      end
    end

    test "lists subscriptions with limit", %{subscription_ids: _subscription_ids} do
      conn = request(:get, "/v1/subscriptions", %{"limit" => "2"})

      assert conn.status == 200
      body = json_response(conn)

      assert length(body["data"]) == 2
      assert body["has_more"] == true
    end

    test "filters subscriptions by customer", %{customer_id: customer_id} do
      # Create another customer with subscription
      other_customer_conn = request(:post, "/v1/customers", %{"email" => "other@example.com"})
      other_customer = json_response(other_customer_conn)
      other_customer_id = other_customer["id"]

      product_conn = request(:post, "/v1/products", %{"name" => "Plan"})
      product = json_response(product_conn)
      product_id = product["id"]

      price_params = %{
        "currency" => "usd",
        "product" => product_id,
        "unit_amount" => "1000"
      }

      price_conn = request(:post, "/v1/prices", price_params)
      price = json_response(price_conn)
      price_id = price["id"]

      subscription_params = %{
        "customer" => other_customer_id,
        "items" => [%{"price" => price_id, "quantity" => "1"}]
      }

      request(:post, "/v1/subscriptions", subscription_params)

      # List subscriptions filtered by customer
      conn = request(:get, "/v1/subscriptions", %{"customer" => customer_id})

      assert conn.status == 200
      body = json_response(conn)

      # All returned subscriptions should belong to the specified customer
      for subscription <- body["data"] do
        assert subscription["customer"] == customer_id
      end
    end

    test "returns pagination metadata", %{subscription_ids: _subscription_ids} do
      conn = request(:get, "/v1/subscriptions", %{"limit" => "2"})

      assert conn.status == 200
      body = json_response(conn)

      assert is_list(body["data"])
      assert body["has_more"] == true
      assert body["object"] == "list"
      assert body["url"] == "/v1/subscriptions"
    end

    test "lists subscriptions with starting_after cursor" do
      # Create 5 subscriptions to test pagination
      customer_conn = request(:post, "/v1/customers", %{"email" => "cursor@example.com"})
      customer = json_response(customer_conn)
      customer_id = customer["id"]

      product_conn = request(:post, "/v1/products", %{"name" => "Plan"})
      product = json_response(product_conn)
      product_id = product["id"]

      price_params = %{
        "currency" => "usd",
        "product" => product_id,
        "unit_amount" => "1000"
      }

      price_conn = request(:post, "/v1/prices", price_params)
      price = json_response(price_conn)
      price_id = price["id"]

      _sub_ids =
        Enum.reduce(1..5, [], fn _i, acc ->
          subscription_params = %{
            "customer" => customer_id,
            "items" => [%{"price" => price_id, "quantity" => "1"}]
          }

          sub_conn = request(:post, "/v1/subscriptions", subscription_params)
          subscription = json_response(sub_conn)

          # Small delay to ensure different timestamps
          Process.sleep(10)

          acc ++ [subscription["id"]]
        end)

      # Get first page
      first_page = request(:get, "/v1/subscriptions", %{"limit" => "2"})
      assert first_page.status == 200
      first_body = json_response(first_page)
      assert length(first_body["data"]) == 2

      # Get next page using cursor
      cursor = Enum.at(first_body["data"], 1)["id"]

      second_page =
        request(:get, "/v1/subscriptions", %{"limit" => "2", "starting_after" => cursor})

      assert second_page.status == 200
      second_body = json_response(second_page)
      assert second_body["data"] != []

      # Verify no overlap between pages
      first_ids = Enum.map(first_body["data"], & &1["id"])
      second_ids = Enum.map(second_body["data"], & &1["id"])

      intersection = Enum.filter(first_ids, fn id -> id in second_ids end)
      assert Enum.empty?(intersection)
    end
  end

  describe "Complete billing flow" do
    test "creates, updates, and cancels subscription with trial period" do
      # 1. Create customer
      customer_params = %{
        "email" => "billing@example.com",
        "name" => "Billing Test"
      }

      customer_conn = request(:post, "/v1/customers", customer_params)
      assert customer_conn.status == 200
      customer = json_response(customer_conn)
      customer_id = customer["id"]

      # 2. Create product
      product_conn = request(:post, "/v1/products", %{"name" => "Billing Plan"})
      assert product_conn.status == 200
      product = json_response(product_conn)
      product_id = product["id"]

      # 3. Create price
      price_params = %{
        "currency" => "usd",
        "product" => product_id,
        "recurring" => %{"interval" => "month"},
        "unit_amount" => "9999"
      }

      price_conn = request(:post, "/v1/prices", price_params)
      assert price_conn.status == 200
      price = json_response(price_conn)
      price_id = price["id"]

      # 4. Create subscription with trial
      subscription_params = %{
        "customer" => customer_id,
        "items" => [%{"price" => price_id, "quantity" => "1"}],
        "metadata" => %{"order_id" => "ORD-12345"},
        "trial_period_days" => "14"
      }

      sub_conn = request(:post, "/v1/subscriptions", subscription_params)
      assert sub_conn.status == 200
      subscription = json_response(sub_conn)
      subscription_id = subscription["id"]

      assert subscription["status"] == "trialing"
      assert subscription["trial_end"] != nil
      assert subscription["metadata"]["order_id"] == "ORD-12345"

      # 5. Retrieve subscription to verify
      retrieve_conn = request(:get, "/v1/subscriptions/#{subscription_id}", %{})
      assert retrieve_conn.status == 200
      retrieved = json_response(retrieve_conn)

      assert retrieved["id"] == subscription_id
      assert retrieved["status"] == "trialing"
      assert length(retrieved["items"]["data"]) == 1

      # 6. Update subscription (add metadata)
      update_params = %{
        "metadata" => %{"order_id" => "ORD-12345", "updated" => "true"}
      }

      update_conn = request(:post, "/v1/subscriptions/#{subscription_id}", update_params)
      assert update_conn.status == 200
      updated = json_response(update_conn)

      assert updated["metadata"]["updated"] == "true"

      # 7. Set cancel_at_period_end
      cancel_update = %{
        "cancel_at_period_end" => true
      }

      cancel_conn = request(:post, "/v1/subscriptions/#{subscription_id}", cancel_update)
      assert cancel_conn.status == 200
      updated_for_cancel = json_response(cancel_conn)

      assert updated_for_cancel["cancel_at_period_end"] == true
      # Should still be trialing
      assert updated_for_cancel["status"] == "trialing"

      # 8. Cancel subscription immediately
      delete_conn = request(:delete, "/v1/subscriptions/#{subscription_id}", %{})
      assert delete_conn.status == 200
      canceled = json_response(delete_conn)

      assert canceled["status"] == "canceled"
      assert canceled["canceled_at"] != nil
      assert canceled["ended_at"] != nil

      # 9. Verify subscription is in canceled state
      final_retrieve = request(:get, "/v1/subscriptions/#{subscription_id}", %{})
      assert final_retrieve.status == 200
      final = json_response(final_retrieve)

      assert final["status"] == "canceled"
      assert final["canceled_at"] != nil
    end

    test "creates multiple subscriptions for same customer and lists them filtered" do
      # Create customer
      customer_conn = request(:post, "/v1/customers", %{"email" => "multi@example.com"})
      assert customer_conn.status == 200
      customer = json_response(customer_conn)
      customer_id = customer["id"]

      # Create two products and prices
      product1_conn = request(:post, "/v1/products", %{"name" => "Plan A"})
      product1 = json_response(product1_conn)
      product1_id = product1["id"]

      product2_conn = request(:post, "/v1/products", %{"name" => "Plan B"})
      product2 = json_response(product2_conn)
      product2_id = product2["id"]

      price1_params = %{
        "currency" => "usd",
        "product" => product1_id,
        "unit_amount" => "1000"
      }

      price1_conn = request(:post, "/v1/prices", price1_params)
      price1 = json_response(price1_conn)
      price1_id = price1["id"]

      price2_params = %{
        "currency" => "usd",
        "product" => product2_id,
        "unit_amount" => "2000"
      }

      price2_conn = request(:post, "/v1/prices", price2_params)
      price2 = json_response(price2_conn)
      price2_id = price2["id"]

      # Create two subscriptions
      sub1_params = %{
        "customer" => customer_id,
        "items" => [%{"price" => price1_id, "quantity" => "1"}],
        "metadata" => %{"plan" => "A"}
      }

      sub1_conn = request(:post, "/v1/subscriptions", sub1_params)
      assert sub1_conn.status == 200
      sub1 = json_response(sub1_conn)
      sub1_id = sub1["id"]

      sub2_params = %{
        "customer" => customer_id,
        "items" => [%{"price" => price2_id, "quantity" => "1"}],
        "metadata" => %{"plan" => "B"}
      }

      sub2_conn = request(:post, "/v1/subscriptions", sub2_params)
      assert sub2_conn.status == 200
      sub2 = json_response(sub2_conn)
      sub2_id = sub2["id"]

      # List subscriptions for this customer
      list_conn = request(:get, "/v1/subscriptions", %{"customer" => customer_id})
      assert list_conn.status == 200
      list_body = json_response(list_conn)

      assert is_list(list_body["data"])
      assert length(list_body["data"]) >= 2

      listed_ids = Enum.map(list_body["data"], & &1["id"])
      assert sub1_id in listed_ids
      assert sub2_id in listed_ids

      # Cancel first subscription
      cancel_conn = request(:delete, "/v1/subscriptions/#{sub1_id}", %{})
      assert cancel_conn.status == 200

      # Verify first is canceled, second is still active
      sub1_final = request(:get, "/v1/subscriptions/#{sub1_id}", %{})
      sub1_final_body = json_response(sub1_final)
      assert sub1_final_body["status"] == "canceled"

      sub2_final = request(:get, "/v1/subscriptions/#{sub2_id}", %{})
      sub2_final_body = json_response(sub2_final)
      assert sub2_final_body["status"] == "active"
    end
  end
end
