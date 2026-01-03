defmodule PaperTiger.Resources.PaymentMethodTest do
  @moduledoc """
  End-to-end tests for PaymentMethod resource with attach/detach flow.

  Tests complete payment method lifecycle:
  1. Setup: Create customer
  2. POST /v1/payment_methods - Create payment method
     - Test with type="card"
     - Test with billing_details
     - Verify card object structure
  3. POST /v1/payment_methods/:id/attach - Attach to customer
     - Requires customer parameter
     - Updates payment_method.customer field
     - Test error without customer param
  4. POST /v1/payment_methods/:id/detach - Detach from customer
     - Clears payment_method.customer field
     - Can detach already-detached method
  5. Standard CRUD:
     - GET /v1/payment_methods/:id - Retrieve
     - POST /v1/payment_methods/:id - Update (metadata, billing_details)
     - DELETE /v1/payment_methods/:id - Delete
     - GET /v1/payment_methods - List with pagination
  """

  use ExUnit.Case, async: true

  import PaperTiger.Test

  alias PaperTiger.Router

  setup :checkout_paper_tiger

  # Helper function to create a test connection with proper setup
  defp conn(method, path, params, headers) do
    conn = Plug.Test.conn(method, path, params)

    headers_with_defaults =
      headers ++
        [
          {"content-type", "application/json"},
          {"authorization", "Bearer sk_test_payment_key"}
        ]

    Enum.reduce(headers_with_defaults, conn, fn {key, value}, acc ->
      Plug.Conn.put_req_header(acc, key, value)
    end)
  end

  # Helper function to run a request through the router
  defp request(method, path, params \\ nil, headers \\ []) do
    conn = conn(method, path, params, headers)
    Router.call(conn, [])
  end

  # Helper function to run request without authorization header
  defp request_no_auth(method, path, params \\ nil) do
    conn = Plug.Test.conn(method, path, params)

    conn_with_headers =
      Enum.reduce([{"content-type", "application/json"}], conn, fn {key, value}, acc ->
        Plug.Conn.put_req_header(acc, key, value)
      end)

    Router.call(conn_with_headers, [])
  end

  # Helper function to parse JSON response
  defp json_response(conn) do
    Jason.decode!(conn.resp_body)
  end

  # Helper function to create a test customer
  defp create_customer(email \\ "test@example.com") do
    conn = request(:post, "/v1/customers", %{"email" => email})
    json_response(conn)["id"]
  end

  describe "POST /v1/payment_methods - Create payment method" do
    test "creates a payment method with type card" do
      conn =
        request(:post, "/v1/payment_methods", %{
          "type" => "card"
        })

      assert conn.status == 200
      pm = json_response(conn)
      assert pm["type"] == "card"
      assert String.starts_with?(pm["id"], "pm_")
      assert pm["object"] == "payment_method"
      assert is_integer(pm["created"])
      assert pm["livemode"] == false
    end

    test "creates payment method with billing_details" do
      billing_details = %{
        "address" => %{
          "city" => "San Francisco",
          "country" => "US",
          "line1" => "123 Main St",
          "line2" => "Apt 5",
          "postal_code" => "94102",
          "state" => "CA"
        },
        "email" => "john@example.com",
        "name" => "John Doe",
        "phone" => "+1-555-0100"
      }

      conn =
        request(:post, "/v1/payment_methods", %{
          "billing_details" => billing_details,
          "type" => "card"
        })

      assert conn.status == 200
      pm = json_response(conn)
      assert pm["billing_details"]["name"] == "John Doe"
      assert pm["billing_details"]["email"] == "john@example.com"
      assert pm["billing_details"]["address"]["city"] == "San Francisco"
    end

    test "creates payment method with card details" do
      card = %{
        "brand" => "visa",
        "exp_month" => 12,
        "exp_year" => 2026,
        "last4" => "4242"
      }

      conn =
        request(:post, "/v1/payment_methods", %{
          "card" => card,
          "type" => "card"
        })

      assert conn.status == 200
      pm = json_response(conn)
      assert pm["card"]["brand"] == "visa"
      assert pm["card"]["last4"] == "4242"
      assert pm["card"]["exp_month"] == 12
      assert pm["card"]["exp_year"] == 2026
    end

    test "creates payment method with metadata" do
      metadata = %{"order_id" => "12345", "tier" => "premium"}

      conn =
        request(:post, "/v1/payment_methods", %{
          "metadata" => metadata,
          "type" => "card"
        })

      assert conn.status == 200
      pm = json_response(conn)
      assert pm["metadata"]["order_id"] == "12345"
      assert pm["metadata"]["tier"] == "premium"
    end

    test "creates payment method with customer" do
      customer_id = create_customer("owner@example.com")

      conn =
        request(:post, "/v1/payment_methods", %{
          "customer" => customer_id,
          "type" => "card"
        })

      assert conn.status == 200
      pm = json_response(conn)
      assert pm["customer"] == customer_id
    end

    test "creates payment method without customer" do
      conn =
        request(:post, "/v1/payment_methods", %{
          "type" => "card"
        })

      assert conn.status == 200
      pm = json_response(conn)
      assert is_nil(pm["customer"])
    end

    test "returns 401 when missing authorization header" do
      conn = request_no_auth(:post, "/v1/payment_methods", %{"type" => "card"})

      assert conn.status == 401
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
      assert response["error"]["message"] =~ "API key"
    end

    test "requires type parameter" do
      conn = request(:post, "/v1/payment_methods", %{})

      assert conn.status == 400
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
      # Error message should indicate missing parameter
      assert response["error"]["message"] =~ "parameter"
    end

    test "can create multiple payment methods" do
      conn1 = request(:post, "/v1/payment_methods", %{"type" => "card"})
      assert conn1.status == 200
      pm1_id = json_response(conn1)["id"]

      conn2 = request(:post, "/v1/payment_methods", %{"type" => "card"})
      assert conn2.status == 200
      pm2_id = json_response(conn2)["id"]

      assert pm1_id != pm2_id
    end

    test "supports idempotency with Idempotency-Key header" do
      idempotency_key = "test_pm_#{:rand.uniform(1_000_000)}"

      # First request
      conn1 =
        request(:post, "/v1/payment_methods", %{"type" => "card"}, [
          {"idempotency-key", idempotency_key}
        ])

      assert conn1.status == 200
      pm1 = json_response(conn1)

      # Second request with same key
      conn2 =
        request(:post, "/v1/payment_methods", %{"type" => "card"}, [
          {"idempotency-key", idempotency_key}
        ])

      assert conn2.status == 200
      pm2 = json_response(conn2)

      # Should return the same payment method
      assert pm1["id"] == pm2["id"]
    end

    test "payment method object structure is correct" do
      conn =
        request(:post, "/v1/payment_methods", %{
          "billing_details" => %{
            "email" => "jane@example.com",
            "name" => "Jane Doe"
          },
          "card" => %{
            "brand" => "visa",
            "exp_month" => 12,
            "exp_year" => 2026,
            "last4" => "4242"
          },
          "metadata" => %{"key" => "value"},
          "type" => "card"
        })

      assert conn.status == 200
      pm = json_response(conn)

      # Verify all expected fields
      assert Map.has_key?(pm, "id")
      assert Map.has_key?(pm, "object")
      assert Map.has_key?(pm, "created")
      assert Map.has_key?(pm, "type")
      assert Map.has_key?(pm, "customer")
      assert Map.has_key?(pm, "metadata")
      assert Map.has_key?(pm, "card")
      assert Map.has_key?(pm, "billing_details")
      assert Map.has_key?(pm, "livemode")

      assert pm["object"] == "payment_method"
      assert pm["type"] == "card"
      assert is_integer(pm["created"])
      assert pm["livemode"] == false
    end
  end

  describe "GET /v1/payment_methods/:id - Retrieve payment method" do
    test "retrieves an existing payment method" do
      # Create a payment method
      create_conn =
        request(:post, "/v1/payment_methods", %{
          "card" => %{"brand" => "visa", "last4" => "4242"},
          "type" => "card"
        })

      pm_id = json_response(create_conn)["id"]

      # Retrieve it
      conn = request(:get, "/v1/payment_methods/#{pm_id}")

      assert conn.status == 200
      pm = json_response(conn)
      assert pm["id"] == pm_id
      assert pm["type"] == "card"
      assert pm["object"] == "payment_method"
    end

    test "returns 404 for missing payment method" do
      conn = request(:get, "/v1/payment_methods/pm_nonexistent")

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
      assert response["error"]["message"] =~ "pm_nonexistent"
    end

    test "retrieves payment method with all fields" do
      customer_id = create_customer("pm_customer@example.com")

      create_conn =
        request(:post, "/v1/payment_methods", %{
          "billing_details" => %{
            "email" => "test@example.com",
            "name" => "Test User"
          },
          "card" => %{"brand" => "mastercard", "last4" => "5555"},
          "customer" => customer_id,
          "metadata" => %{"internal_id" => "ext_123"},
          "type" => "card"
        })

      pm_id = json_response(create_conn)["id"]
      conn = request(:get, "/v1/payment_methods/#{pm_id}")

      assert conn.status == 200
      pm = json_response(conn)
      assert pm["id"] == pm_id
      assert pm["customer"] == customer_id
      assert pm["card"]["brand"] == "mastercard"
      assert pm["billing_details"]["name"] == "Test User"
      assert pm["metadata"]["internal_id"] == "ext_123"
    end
  end

  describe "POST /v1/payment_methods/:id - Update payment method" do
    test "updates payment method metadata" do
      create_conn =
        request(:post, "/v1/payment_methods", %{
          "metadata" => %{"old_key" => "old_value"},
          "type" => "card"
        })

      pm_id = json_response(create_conn)["id"]

      # Update metadata (replaces existing)
      conn =
        request(:post, "/v1/payment_methods/#{pm_id}", %{
          "metadata" => %{"new_key" => "new_value", "old_key" => "old_value"}
        })

      assert conn.status == 200
      pm = json_response(conn)
      assert pm["id"] == pm_id
      assert pm["metadata"]["new_key"] == "new_value"
      assert pm["metadata"]["old_key"] == "old_value"
    end

    test "updates payment method billing_details" do
      create_conn = request(:post, "/v1/payment_methods", %{"type" => "card"})
      pm_id = json_response(create_conn)["id"]

      billing_details = %{
        "address" => %{
          "city" => "New York",
          "line1" => "456 Oak Ave",
          "state" => "NY"
        },
        "email" => "updated@example.com",
        "name" => "Updated Name"
      }

      conn =
        request(:post, "/v1/payment_methods/#{pm_id}", %{
          "billing_details" => billing_details
        })

      assert conn.status == 200
      pm = json_response(conn)
      assert pm["billing_details"]["name"] == "Updated Name"
      assert pm["billing_details"]["email"] == "updated@example.com"
      assert pm["billing_details"]["address"]["line1"] == "456 Oak Ave"
    end

    test "preserves immutable fields (id, object, created, type, card)" do
      create_conn =
        request(:post, "/v1/payment_methods", %{
          "card" => %{"brand" => "visa", "last4" => "4242"},
          "type" => "card"
        })

      pm = json_response(create_conn)
      original_id = pm["id"]
      original_created = pm["created"]
      original_object = pm["object"]
      original_type = pm["type"]
      original_card = pm["card"]

      # Try to update immutable fields (these should be ignored)
      conn =
        request(:post, "/v1/payment_methods/#{original_id}", %{
          "metadata" => %{"updated" => "true"}
        })

      assert conn.status == 200
      updated = json_response(conn)
      assert updated["id"] == original_id
      assert updated["created"] == original_created
      assert updated["object"] == original_object
      assert updated["type"] == original_type
      assert updated["card"] == original_card
    end

    test "returns 404 when updating non-existent payment method" do
      conn =
        request(:post, "/v1/payment_methods/pm_nonexistent", %{
          "metadata" => %{"key" => "value"}
        })

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "updates multiple fields at once" do
      create_conn = request(:post, "/v1/payment_methods", %{"type" => "card"})
      pm_id = json_response(create_conn)["id"]

      conn =
        request(:post, "/v1/payment_methods/#{pm_id}", %{
          "billing_details" => %{
            "email" => "multi@example.com",
            "name" => "Multi Update"
          },
          "metadata" => %{"account" => "123", "tier" => "premium"}
        })

      assert conn.status == 200
      pm = json_response(conn)
      assert pm["metadata"]["tier"] == "premium"
      assert pm["metadata"]["account"] == "123"
      assert pm["billing_details"]["name"] == "Multi Update"
    end
  end

  describe "DELETE /v1/payment_methods/:id - Delete payment method" do
    test "deletes an existing payment method" do
      create_conn = request(:post, "/v1/payment_methods", %{"type" => "card"})
      pm_id = json_response(create_conn)["id"]

      # Delete it
      conn = request(:delete, "/v1/payment_methods/#{pm_id}")

      assert conn.status == 200
      result = json_response(conn)
      assert result["deleted"] == true
      assert result["id"] == pm_id
      assert result["object"] == "payment_method"
    end

    test "returns 404 when deleting non-existent payment method" do
      conn = request(:delete, "/v1/payment_methods/pm_nonexistent")

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "payment method is not retrievable after deletion" do
      create_conn = request(:post, "/v1/payment_methods", %{"type" => "card"})
      pm_id = json_response(create_conn)["id"]

      # Delete it
      delete_conn = request(:delete, "/v1/payment_methods/#{pm_id}")
      assert delete_conn.status == 200

      # Try to retrieve - should be 404
      retrieve_conn = request(:get, "/v1/payment_methods/#{pm_id}")
      assert retrieve_conn.status == 404
    end

    test "deletion response has correct structure" do
      create_conn = request(:post, "/v1/payment_methods", %{"type" => "card"})
      pm_id = json_response(create_conn)["id"]

      conn = request(:delete, "/v1/payment_methods/#{pm_id}")

      assert conn.status == 200
      result = json_response(conn)
      assert Map.has_key?(result, "deleted")
      assert Map.has_key?(result, "id")
      assert Map.has_key?(result, "object")
      assert result["deleted"] == true
    end
  end

  describe "GET /v1/payment_methods - List payment methods" do
    test "lists payment methods with default limit" do
      # Create 3 payment methods
      for _i <- 1..3 do
        request(:post, "/v1/payment_methods", %{"type" => "card"})
      end

      conn = request(:get, "/v1/payment_methods")

      assert conn.status == 200
      result = json_response(conn)
      assert is_list(result["data"])
      assert length(result["data"]) == 3
      assert result["has_more"] == false
      assert result["object"] == "list"
      assert result["url"] == "/v1/payment_methods"
    end

    test "respects limit parameter" do
      # Create 5 payment methods
      for _i <- 1..5 do
        request(:post, "/v1/payment_methods", %{"type" => "card"})
      end

      conn = request(:get, "/v1/payment_methods?limit=2")

      assert conn.status == 200
      result = json_response(conn)
      assert length(result["data"]) == 2
      assert result["has_more"] == true
    end

    test "returns all when limit is greater than total" do
      # Create 2 payment methods
      for _i <- 1..2 do
        request(:post, "/v1/payment_methods", %{"type" => "card"})
      end

      conn = request(:get, "/v1/payment_methods?limit=100")

      assert conn.status == 200
      result = json_response(conn)
      assert length(result["data"]) == 2
      assert result["has_more"] == false
    end

    test "supports starting_after cursor pagination" do
      # Create 5 payment methods with delays
      for _i <- 1..5 do
        request(:post, "/v1/payment_methods", %{"type" => "card"})
        Process.sleep(2)
      end

      # Get first page with limit 2
      conn1 = request(:get, "/v1/payment_methods?limit=2")
      assert conn1.status == 200
      page1 = json_response(conn1)
      assert length(page1["data"]) == 2
      assert page1["has_more"] == true

      # Get second page using starting_after
      last_pm_id = Enum.at(page1["data"], 1)["id"]
      conn2 = request(:get, "/v1/payment_methods?limit=2&starting_after=#{last_pm_id}")

      assert conn2.status == 200
      page2 = json_response(conn2)
      assert page2["data"] != []

      # Verify that the cursor payment method is not in second page
      page2_ids = Enum.map(page2["data"], & &1["id"])
      assert not Enum.member?(page2_ids, last_pm_id)
    end

    test "returns empty list when no payment methods exist" do
      conn = request(:get, "/v1/payment_methods")

      assert conn.status == 200
      result = json_response(conn)
      assert result["data"] == []
      assert result["has_more"] == false
    end

    test "payment methods are sorted by creation time (descending)" do
      # Create 3 payment methods with delays
      for _i <- 1..3 do
        request(:post, "/v1/payment_methods", %{"type" => "card"})
        Process.sleep(1)
      end

      conn = request(:get, "/v1/payment_methods?limit=10")

      assert conn.status == 200
      result = json_response(conn)
      pms = result["data"]

      # Verify they are sorted by created time (descending - newest first)
      created_times = Enum.map(pms, & &1["created"])
      sorted_times = Enum.sort(created_times, :desc)
      assert created_times == sorted_times
    end

    test "list includes all payment method fields" do
      request(:post, "/v1/payment_methods", %{
        "card" => %{"brand" => "visa", "last4" => "4242"},
        "metadata" => %{"key" => "value"},
        "type" => "card"
      })

      conn = request(:get, "/v1/payment_methods")

      assert conn.status == 200
      pm = Enum.at(json_response(conn)["data"], 0)

      # Verify expected fields are present
      assert Map.has_key?(pm, "id")
      assert Map.has_key?(pm, "object")
      assert Map.has_key?(pm, "created")
      assert Map.has_key?(pm, "type")
      assert Map.has_key?(pm, "customer")
      assert Map.has_key?(pm, "metadata")
    end
  end

  describe "POST /v1/payment_methods/:id/attach - Attach to customer" do
    test "attaches payment method to customer" do
      customer_id = create_customer("attach@example.com")

      create_conn = request(:post, "/v1/payment_methods", %{"type" => "card"})
      pm_id = json_response(create_conn)["id"]

      # Attach to customer
      conn =
        request(:post, "/v1/payment_methods/#{pm_id}/attach", %{
          "customer" => customer_id
        })

      assert conn.status == 200
      pm = json_response(conn)
      assert pm["id"] == pm_id
      assert pm["customer"] == customer_id
    end

    test "updates payment_method.customer field on attach" do
      customer1_id = create_customer("customer1@example.com")
      customer2_id = create_customer("customer2@example.com")

      create_conn = request(:post, "/v1/payment_methods", %{"type" => "card"})
      pm_id = json_response(create_conn)["id"]

      # Attach to first customer
      attach1_conn =
        request(:post, "/v1/payment_methods/#{pm_id}/attach", %{
          "customer" => customer1_id
        })

      assert attach1_conn.status == 200
      assert json_response(attach1_conn)["customer"] == customer1_id

      # Reattach to second customer
      attach2_conn =
        request(:post, "/v1/payment_methods/#{pm_id}/attach", %{
          "customer" => customer2_id
        })

      assert attach2_conn.status == 200
      assert json_response(attach2_conn)["customer"] == customer2_id

      # Verify the change persists
      get_conn = request(:get, "/v1/payment_methods/#{pm_id}")
      assert json_response(get_conn)["customer"] == customer2_id
    end

    test "attach requires customer parameter" do
      create_conn = request(:post, "/v1/payment_methods", %{"type" => "card"})
      pm_id = json_response(create_conn)["id"]

      # Try to attach without customer parameter
      conn = request(:post, "/v1/payment_methods/#{pm_id}/attach", %{})

      assert conn.status == 400
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
      # Error message should indicate missing parameter
      assert response["error"]["message"] =~ "parameter"
    end

    test "attach fails without customer parameter" do
      create_conn = request(:post, "/v1/payment_methods", %{"type" => "card"})
      pm_id = json_response(create_conn)["id"]

      # Try to attach with empty customer
      conn =
        request(:post, "/v1/payment_methods/#{pm_id}/attach", %{
          "customer" => ""
        })

      assert conn.status == 400
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "returns 404 when attaching non-existent payment method" do
      customer_id = create_customer("test@example.com")

      conn =
        request(:post, "/v1/payment_methods/pm_nonexistent/attach", %{
          "customer" => customer_id
        })

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "attach preserves other payment method fields" do
      customer_id = create_customer("preserve@example.com")

      create_conn =
        request(:post, "/v1/payment_methods", %{
          "billing_details" => %{
            "email" => "original@example.com",
            "name" => "Original Name"
          },
          "card" => %{"brand" => "visa", "last4" => "4242"},
          "metadata" => %{"original" => "data"},
          "type" => "card"
        })

      pm_id = json_response(create_conn)["id"]

      # Attach to customer
      conn =
        request(:post, "/v1/payment_methods/#{pm_id}/attach", %{
          "customer" => customer_id
        })

      assert conn.status == 200
      pm = json_response(conn)
      assert pm["customer"] == customer_id
      assert pm["type"] == "card"
      assert pm["card"]["brand"] == "visa"
      assert pm["metadata"]["original"] == "data"
      assert pm["billing_details"]["name"] == "Original Name"
    end

    test "can attach already-attached payment method to different customer" do
      customer1_id = create_customer("customer1@example.com")
      customer2_id = create_customer("customer2@example.com")

      create_conn = request(:post, "/v1/payment_methods", %{"type" => "card"})
      pm_id = json_response(create_conn)["id"]

      # Attach to first customer
      request(:post, "/v1/payment_methods/#{pm_id}/attach", %{
        "customer" => customer1_id
      })

      # Attach to different customer (reassign)
      conn =
        request(:post, "/v1/payment_methods/#{pm_id}/attach", %{
          "customer" => customer2_id
        })

      assert conn.status == 200
      pm = json_response(conn)
      assert pm["customer"] == customer2_id
    end
  end

  describe "POST /v1/payment_methods/:id/detach - Detach from customer" do
    test "detaches payment method from customer" do
      customer_id = create_customer("detach@example.com")

      create_conn =
        request(:post, "/v1/payment_methods", %{
          "customer" => customer_id,
          "type" => "card"
        })

      pm_id = json_response(create_conn)["id"]

      # Verify it's attached
      get_before = request(:get, "/v1/payment_methods/#{pm_id}")
      assert json_response(get_before)["customer"] == customer_id

      # Detach from customer
      conn = request(:post, "/v1/payment_methods/#{pm_id}/detach", %{})

      assert conn.status == 200
      pm = json_response(conn)
      assert pm["id"] == pm_id
      assert is_nil(pm["customer"])
    end

    test "clears payment_method.customer field on detach" do
      customer_id = create_customer("clear@example.com")

      create_conn =
        request(:post, "/v1/payment_methods", %{
          "customer" => customer_id,
          "type" => "card"
        })

      pm_id = json_response(create_conn)["id"]

      # Detach from customer
      detach_conn = request(:post, "/v1/payment_methods/#{pm_id}/detach", %{})

      assert detach_conn.status == 200
      detached = json_response(detach_conn)
      assert is_nil(detached["customer"])

      # Verify the change persists
      get_conn = request(:get, "/v1/payment_methods/#{pm_id}")
      assert is_nil(json_response(get_conn)["customer"])
    end

    test "can detach already-detached payment method" do
      create_conn = request(:post, "/v1/payment_methods", %{"type" => "card"})
      pm_id = json_response(create_conn)["id"]

      # Detach (even though not attached)
      conn = request(:post, "/v1/payment_methods/#{pm_id}/detach", %{})

      assert conn.status == 200
      pm = json_response(conn)
      assert is_nil(pm["customer"])

      # Detach again (should still work)
      conn2 = request(:post, "/v1/payment_methods/#{pm_id}/detach", %{})

      assert conn2.status == 200
      pm2 = json_response(conn2)
      assert is_nil(pm2["customer"])
    end

    test "returns 404 when detaching non-existent payment method" do
      conn = request(:post, "/v1/payment_methods/pm_nonexistent/detach", %{})

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "detach preserves other payment method fields" do
      customer_id = create_customer("preserve_detach@example.com")

      create_conn =
        request(:post, "/v1/payment_methods", %{
          "billing_details" => %{
            "email" => "detach@example.com",
            "name" => "Detach Test"
          },
          "card" => %{"brand" => "mastercard", "last4" => "5555"},
          "customer" => customer_id,
          "metadata" => %{"preserve" => "this"},
          "type" => "card"
        })

      pm_id = json_response(create_conn)["id"]

      # Detach from customer
      conn = request(:post, "/v1/payment_methods/#{pm_id}/detach", %{})

      assert conn.status == 200
      pm = json_response(conn)
      assert is_nil(pm["customer"])
      assert pm["type"] == "card"
      assert pm["card"]["brand"] == "mastercard"
      assert pm["metadata"]["preserve"] == "this"
      assert pm["billing_details"]["name"] == "Detach Test"
    end

    test "detached method can be reattached to different customer" do
      customer1_id = create_customer("customer1@example.com")
      customer2_id = create_customer("customer2@example.com")

      create_conn =
        request(:post, "/v1/payment_methods", %{
          "customer" => customer1_id,
          "type" => "card"
        })

      pm_id = json_response(create_conn)["id"]

      # Detach from first customer
      detach_conn = request(:post, "/v1/payment_methods/#{pm_id}/detach", %{})
      assert is_nil(json_response(detach_conn)["customer"])

      # Reattach to different customer
      attach_conn =
        request(:post, "/v1/payment_methods/#{pm_id}/attach", %{
          "customer" => customer2_id
        })

      assert attach_conn.status == 200
      pm = json_response(attach_conn)
      assert pm["customer"] == customer2_id
    end
  end

  describe "Integration - Complete attach/detach flow" do
    test "complete payment method lifecycle with attach/detach" do
      # 1. Create customer
      customer1_id = create_customer("lifecycle1@example.com")
      customer2_id = create_customer("lifecycle2@example.com")

      # 2. Create payment method
      create_conn =
        request(:post, "/v1/payment_methods", %{
          "billing_details" => %{
            "email" => "john@example.com",
            "name" => "John Doe"
          },
          "card" => %{"brand" => "visa", "last4" => "4242"},
          "metadata" => %{"status" => "new"},
          "type" => "card"
        })

      assert create_conn.status == 200
      pm_id = json_response(create_conn)["id"]

      # 3. Attach to first customer
      attach1_conn =
        request(:post, "/v1/payment_methods/#{pm_id}/attach", %{
          "customer" => customer1_id
        })

      assert attach1_conn.status == 200
      assert json_response(attach1_conn)["customer"] == customer1_id

      # 4. Update payment method
      update_conn =
        request(:post, "/v1/payment_methods/#{pm_id}", %{
          "metadata" => %{"status" => "active"}
        })

      assert update_conn.status == 200
      assert json_response(update_conn)["metadata"]["status"] == "active"

      # 5. Retrieve to verify
      get_conn = request(:get, "/v1/payment_methods/#{pm_id}")
      assert get_conn.status == 200
      pm = json_response(get_conn)
      assert pm["customer"] == customer1_id
      assert pm["metadata"]["status"] == "active"

      # 6. Detach from first customer
      detach_conn = request(:post, "/v1/payment_methods/#{pm_id}/detach", %{})
      assert detach_conn.status == 200
      assert is_nil(json_response(detach_conn)["customer"])

      # 7. Reattach to second customer
      attach2_conn =
        request(:post, "/v1/payment_methods/#{pm_id}/attach", %{
          "customer" => customer2_id
        })

      assert attach2_conn.status == 200
      assert json_response(attach2_conn)["customer"] == customer2_id

      # 8. List payment methods
      list_conn = request(:get, "/v1/payment_methods")
      assert list_conn.status == 200
      pms = json_response(list_conn)["data"]
      found = Enum.find(pms, &(&1["id"] == pm_id))
      assert found != nil
      assert found["customer"] == customer2_id

      # 9. Delete payment method
      delete_conn = request(:delete, "/v1/payment_methods/#{pm_id}")
      assert delete_conn.status == 200
      assert json_response(delete_conn)["deleted"] == true

      # 10. Verify deleted
      final_conn = request(:get, "/v1/payment_methods/#{pm_id}")
      assert final_conn.status == 404
    end

    test "multiple payment methods with different attach states" do
      customer_id = create_customer("multi_attach@example.com")

      # Create 3 payment methods
      pm_ids =
        for i <- 1..3 do
          create_conn =
            request(:post, "/v1/payment_methods", %{
              "metadata" => %{"index" => "#{i}"},
              "type" => "card"
            })

          json_response(create_conn)["id"]
        end

      # Attach first to customer
      request(:post, "/v1/payment_methods/#{Enum.at(pm_ids, 0)}/attach", %{
        "customer" => customer_id
      })

      # Attach second to customer
      request(:post, "/v1/payment_methods/#{Enum.at(pm_ids, 1)}/attach", %{
        "customer" => customer_id
      })

      # Leave third unattached

      # Detach first
      request(:post, "/v1/payment_methods/#{Enum.at(pm_ids, 0)}/detach", %{})

      # List and verify states
      list_conn = request(:get, "/v1/payment_methods")
      pms = json_response(list_conn)["data"]

      # Find each payment method and verify its state
      pm1 = Enum.find(pms, &(&1["metadata"]["index"] == "1"))
      pm2 = Enum.find(pms, &(&1["metadata"]["index"] == "2"))
      pm3 = Enum.find(pms, &(&1["metadata"]["index"] == "3"))

      # detached
      assert is_nil(pm1["customer"])
      # attached
      assert pm2["customer"] == customer_id
      # never attached
      assert is_nil(pm3["customer"])
    end

    test "attach/detach flow with updates" do
      customer_id = create_customer("flow_updates@example.com")

      # Create payment method
      create_conn = request(:post, "/v1/payment_methods", %{"type" => "card"})
      pm_id = json_response(create_conn)["id"]

      # Update before attach
      request(:post, "/v1/payment_methods/#{pm_id}", %{
        "metadata" => %{"stage" => "created"}
      })

      # Attach
      request(:post, "/v1/payment_methods/#{pm_id}/attach", %{
        "customer" => customer_id
      })

      # Update after attach
      request(:post, "/v1/payment_methods/#{pm_id}", %{
        "metadata" => %{"stage" => "attached"}
      })

      # Detach
      request(:post, "/v1/payment_methods/#{pm_id}/detach", %{})

      # Update after detach
      request(:post, "/v1/payment_methods/#{pm_id}", %{
        "metadata" => %{"stage" => "detached"}
      })

      # Final verify
      final_conn = request(:get, "/v1/payment_methods/#{pm_id}")
      pm = json_response(final_conn)
      assert pm["metadata"]["stage"] == "detached"
      assert is_nil(pm["customer"])
    end
  end

  describe "Edge cases and validation" do
    test "handles special characters in billing_details" do
      billing_details = %{
        "address" => %{
          "city" => "Montréal",
          "line1" => "123 Rue de l'Église"
        },
        "email" => "josé@example.com",
        "name" => "José García-López"
      }

      conn =
        request(:post, "/v1/payment_methods", %{
          "billing_details" => billing_details,
          "type" => "card"
        })

      assert conn.status == 200
      pm = json_response(conn)
      assert pm["billing_details"]["name"] == "José García-López"
      assert pm["billing_details"]["address"]["line1"] == "123 Rue de l'Église"
    end

    test "handles empty metadata object" do
      conn =
        request(:post, "/v1/payment_methods", %{
          "metadata" => %{},
          "type" => "card"
        })

      assert conn.status == 200
      assert json_response(conn)["metadata"] == %{}
    end

    test "handles special characters in metadata" do
      metadata = %{
        "quotes" => "\"quoted\" 'value'",
        "special" => "!@#$%^&*()",
        "unicode" => "你好世界"
      }

      conn =
        request(:post, "/v1/payment_methods", %{
          "metadata" => metadata,
          "type" => "card"
        })

      assert conn.status == 200
      returned_metadata = json_response(conn)["metadata"]
      assert returned_metadata["special"] == metadata["special"]
      assert returned_metadata["unicode"] == metadata["unicode"]
      assert returned_metadata["quotes"] == metadata["quotes"]
    end

    test "generates unique payment method IDs" do
      id_set =
        for _i <- 1..5 do
          conn = request(:post, "/v1/payment_methods", %{"type" => "card"})
          json_response(conn)["id"]
        end
        |> MapSet.new()

      # All IDs should be unique
      assert MapSet.size(id_set) == 5
    end

    test "handles multiple attach/detach cycles" do
      customer1_id = create_customer("cycle1@example.com")
      customer2_id = create_customer("cycle2@example.com")

      create_conn = request(:post, "/v1/payment_methods", %{"type" => "card"})
      pm_id = json_response(create_conn)["id"]

      # Cycle 1: attach to customer1, detach
      request(:post, "/v1/payment_methods/#{pm_id}/attach", %{
        "customer" => customer1_id
      })

      request(:post, "/v1/payment_methods/#{pm_id}/detach", %{})

      # Cycle 2: attach to customer2, detach
      request(:post, "/v1/payment_methods/#{pm_id}/attach", %{
        "customer" => customer2_id
      })

      request(:post, "/v1/payment_methods/#{pm_id}/detach", %{})

      # Cycle 3: attach to customer1 again, detach
      request(:post, "/v1/payment_methods/#{pm_id}/attach", %{
        "customer" => customer1_id
      })

      request(:post, "/v1/payment_methods/#{pm_id}/detach", %{})

      # Verify final state
      final_conn = request(:get, "/v1/payment_methods/#{pm_id}")
      pm = json_response(final_conn)
      assert is_nil(pm["customer"])
    end

    test "handles large metadata values" do
      large_value = String.duplicate("x", 1000)

      conn =
        request(:post, "/v1/payment_methods", %{
          "metadata" => %{"large_field" => large_value},
          "type" => "card"
        })

      assert conn.status == 200
      pm = json_response(conn)
      assert String.length(pm["metadata"]["large_field"]) == 1000
    end
  end

  describe "Error handling and validation" do
    test "missing type parameter returns error" do
      conn = request(:post, "/v1/payment_methods", %{})

      assert conn.status == 400
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
      # Error message should indicate missing parameter
      assert response["error"]["message"] =~ "parameter"
    end

    test "attach without customer returns error" do
      create_conn = request(:post, "/v1/payment_methods", %{"type" => "card"})
      pm_id = json_response(create_conn)["id"]

      conn = request(:post, "/v1/payment_methods/#{pm_id}/attach", %{})

      assert conn.status == 400
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
      # Error message should indicate missing parameter
      assert response["error"]["message"] =~ "parameter"
    end

    test "operations on deleted payment method return 404" do
      create_conn = request(:post, "/v1/payment_methods", %{"type" => "card"})
      pm_id = json_response(create_conn)["id"]

      # Delete it
      request(:delete, "/v1/payment_methods/#{pm_id}")

      # Try operations on deleted PM
      assert request(:get, "/v1/payment_methods/#{pm_id}").status == 404
      assert request(:post, "/v1/payment_methods/#{pm_id}", %{}).status == 404
      assert request(:delete, "/v1/payment_methods/#{pm_id}").status == 404

      customer_id = create_customer()

      assert request(:post, "/v1/payment_methods/#{pm_id}/attach", %{
               "customer" => customer_id
             }).status == 404

      assert request(:post, "/v1/payment_methods/#{pm_id}/detach", %{}).status == 404
    end

    test "authorization is required for all operations" do
      create_conn = request(:post, "/v1/payment_methods", %{"type" => "card"})
      pm_id = json_response(create_conn)["id"]

      # Try operations without auth
      assert request_no_auth(:get, "/v1/payment_methods/#{pm_id}").status == 401
      assert request_no_auth(:post, "/v1/payment_methods", %{"type" => "card"}).status == 401
      assert request_no_auth(:delete, "/v1/payment_methods/#{pm_id}").status == 401
    end
  end
end
