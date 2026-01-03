defmodule PaperTiger.Resources.CustomerTest do
  @moduledoc """
  End-to-end tests for Customer resource.

  Tests all CRUD operations via the PaperTiger Router:
  1. POST /v1/customers - Create customer
  2. GET /v1/customers/:id - Retrieve customer
  3. POST /v1/customers/:id - Update customer
  4. DELETE /v1/customers/:id - Delete customer
  5. GET /v1/customers - List customers
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
          {"authorization", "Bearer sk_test_customer_key"}
        ] ++ sandbox_headers()

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
  defp request_no_auth(method, path, params) do
    conn = Plug.Test.conn(method, path, params)

    conn_with_headers =
      Enum.reduce([{"content-type", "application/json"}] ++ sandbox_headers(), conn, fn {key, value}, acc ->
        Plug.Conn.put_req_header(acc, key, value)
      end)

    Router.call(conn_with_headers, [])
  end

  # Helper function to parse JSON response
  defp json_response(conn) do
    Jason.decode!(conn.resp_body)
  end

  describe "POST /v1/customers - Create customer" do
    test "creates a customer with email" do
      conn = request(:post, "/v1/customers", %{"email" => "john@example.com"})

      assert conn.status == 200
      customer = json_response(conn)
      assert customer["email"] == "john@example.com"
      assert String.starts_with?(customer["id"], "cus_")
      assert customer["object"] == "customer"
      assert is_integer(customer["created"])
      assert customer["metadata"] == %{}
    end

    test "creates a customer with metadata" do
      metadata = %{"order_id" => "12345", "tier" => "premium"}

      conn =
        request(:post, "/v1/customers", %{
          "email" => "jane@example.com",
          "metadata" => metadata
        })

      assert conn.status == 200
      customer = json_response(conn)
      assert customer["email"] == "jane@example.com"
      assert customer["metadata"] == metadata
    end

    test "creates a customer with all optional fields" do
      conn =
        request(:post, "/v1/customers", %{
          "description" => "Premium customer",
          "email" => "alice@example.com",
          "metadata" => %{"custom_id" => "ext_123"},
          "name" => "Alice Smith",
          "phone" => "+1-555-0100"
        })

      assert conn.status == 200
      customer = json_response(conn)
      assert customer["email"] == "alice@example.com"
      assert customer["name"] == "Alice Smith"
      assert customer["description"] == "Premium customer"
      assert customer["phone"] == "+1-555-0100"
      assert customer["metadata"]["custom_id"] == "ext_123"
    end

    test "creates a customer without email (all fields optional)" do
      conn = request(:post, "/v1/customers", %{})

      assert conn.status == 200
      customer = json_response(conn)
      assert String.starts_with?(customer["id"], "cus_")
      assert customer["object"] == "customer"
      assert is_nil(customer["email"])
    end

    test "supports idempotency with Idempotency-Key header" do
      idempotency_key = "test_key_#{:rand.uniform(1_000_000)}"

      # First request
      conn1 =
        request(:post, "/v1/customers", %{"email" => "idempotent@example.com"}, [
          {"idempotency-key", idempotency_key}
        ])

      assert conn1.status == 200
      customer1 = json_response(conn1)

      # Second request with same key
      conn2 =
        request(:post, "/v1/customers", %{"email" => "different@example.com"}, [
          {"idempotency-key", idempotency_key}
        ])

      assert conn2.status == 200
      customer2 = json_response(conn2)

      # Should return the same customer
      assert customer1["id"] == customer2["id"]
      assert customer1["email"] == customer2["email"]
    end

    test "returns 401 when missing authorization header" do
      conn = request_no_auth(:post, "/v1/customers", %{"email" => "test@example.com"})

      assert conn.status == 401
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
      assert response["error"]["message"] =~ "API key"
    end

    test "allows creating customer with valid Bearer token" do
      conn =
        request(:post, "/v1/customers", %{"email" => "valid@example.com"}, [])

      assert conn.status == 200
      customer = json_response(conn)
      assert customer["email"] == "valid@example.com"
    end

    test "can create multiple customers" do
      conn1 = request(:post, "/v1/customers", %{"email" => "first@example.com"})
      assert conn1.status == 200
      customer1 = json_response(conn1)
      id1 = customer1["id"]

      conn2 = request(:post, "/v1/customers", %{"email" => "second@example.com"})
      assert conn2.status == 200
      customer2 = json_response(conn2)
      id2 = customer2["id"]

      # Verify both exist
      assert id1 != id2
      assert customer1["email"] == "first@example.com"
      assert customer2["email"] == "second@example.com"
    end
  end

  describe "GET /v1/customers/:id - Retrieve customer" do
    test "retrieves an existing customer" do
      # Create customer first
      create_conn = request(:post, "/v1/customers", %{"email" => "retrieve@example.com"})
      customer_id = json_response(create_conn)["id"]

      # Retrieve it
      conn = request(:get, "/v1/customers/#{customer_id}")

      assert conn.status == 200
      customer = json_response(conn)
      assert customer["id"] == customer_id
      assert customer["email"] == "retrieve@example.com"
      assert customer["object"] == "customer"
    end

    test "returns 404 for missing customer" do
      conn = request(:get, "/v1/customers/cus_nonexistent")

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
      assert response["error"]["message"] =~ "cus_nonexistent"
    end

    test "retrieves customer with complex metadata" do
      metadata = %{
        "nested" => %{"tier" => "premium"},
        "source" => "api",
        "tags" => ["vip", "recurring"]
      }

      create_conn =
        request(:post, "/v1/customers", %{
          "email" => "complex@example.com",
          "metadata" => metadata
        })

      customer_id = json_response(create_conn)["id"]
      conn = request(:get, "/v1/customers/#{customer_id}")

      assert conn.status == 200
      retrieved = json_response(conn)
      assert retrieved["metadata"]["tags"] == ["vip", "recurring"]
      assert retrieved["metadata"]["source"] == "api"
    end

    test "retrieved customer contains all fields" do
      create_conn =
        request(:post, "/v1/customers", %{
          "email" => "fields@example.com",
          "name" => "Test Customer"
        })

      customer_id = json_response(create_conn)["id"]
      conn = request(:get, "/v1/customers/#{customer_id}")

      assert conn.status == 200
      customer = json_response(conn)

      # Verify expected fields are present
      assert Map.has_key?(customer, "id")
      assert Map.has_key?(customer, "object")
      assert Map.has_key?(customer, "created")
      assert Map.has_key?(customer, "email")
      assert Map.has_key?(customer, "name")
      assert Map.has_key?(customer, "metadata")
      assert Map.has_key?(customer, "balance")
      assert Map.has_key?(customer, "delinquent")
    end
  end

  describe "POST /v1/customers/:id - Update customer" do
    test "updates customer email" do
      # Create customer
      create_conn = request(:post, "/v1/customers", %{"email" => "old@example.com"})
      customer_id = json_response(create_conn)["id"]

      # Update email
      conn = request(:post, "/v1/customers/#{customer_id}", %{"email" => "new@example.com"})

      assert conn.status == 200
      updated = json_response(conn)
      assert updated["id"] == customer_id
      assert updated["email"] == "new@example.com"
    end

    test "updates customer name" do
      create_conn = request(:post, "/v1/customers", %{"name" => "John Doe"})
      customer_id = json_response(create_conn)["id"]

      conn = request(:post, "/v1/customers/#{customer_id}", %{"name" => "Jane Doe"})

      assert conn.status == 200
      updated = json_response(conn)
      assert updated["name"] == "Jane Doe"
    end

    test "updates customer metadata" do
      create_conn =
        request(:post, "/v1/customers", %{
          "metadata" => %{"tier" => "standard"}
        })

      customer_id = json_response(create_conn)["id"]

      conn =
        request(:post, "/v1/customers/#{customer_id}", %{
          "metadata" => %{"new_field" => "value", "tier" => "premium"}
        })

      assert conn.status == 200
      updated = json_response(conn)
      assert updated["metadata"]["tier"] == "premium"
      assert updated["metadata"]["new_field"] == "value"
    end

    test "updates description" do
      create_conn = request(:post, "/v1/customers", %{})
      customer_id = json_response(create_conn)["id"]

      conn =
        request(:post, "/v1/customers/#{customer_id}", %{
          "description" => "VIP customer from enterprise sales"
        })

      assert conn.status == 200
      updated = json_response(conn)
      assert updated["description"] == "VIP customer from enterprise sales"
    end

    test "preserves immutable fields (id, object, created)" do
      create_conn = request(:post, "/v1/customers", %{"email" => "immutable@example.com"})
      customer = json_response(create_conn)
      original_id = customer["id"]
      original_created = customer["created"]
      original_object = customer["object"]

      # Try to update immutable fields (these should be ignored)
      conn =
        request(:post, "/v1/customers/#{original_id}", %{
          "email" => "updated@example.com",
          "name" => "Updated Name"
        })

      assert conn.status == 200
      updated = json_response(conn)
      assert updated["id"] == original_id
      assert updated["created"] == original_created
      assert updated["object"] == original_object
      assert updated["email"] == "updated@example.com"
      assert updated["name"] == "Updated Name"
    end

    test "returns 404 when updating non-existent customer" do
      conn =
        request(:post, "/v1/customers/cus_nonexistent", %{
          "email" => "test@example.com"
        })

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "updates multiple fields at once" do
      create_conn = request(:post, "/v1/customers", %{"email" => "multi@example.com"})
      customer_id = json_response(create_conn)["id"]

      conn =
        request(:post, "/v1/customers/#{customer_id}", %{
          "description" => "Testing multiple updates",
          "email" => "multi_updated@example.com",
          "metadata" => %{"updated" => "true"},
          "name" => "Multi Field Update",
          "phone" => "+1-555-0200"
        })

      assert conn.status == 200
      updated = json_response(conn)
      assert updated["email"] == "multi_updated@example.com"
      assert updated["name"] == "Multi Field Update"
      assert updated["description"] == "Testing multiple updates"
      assert updated["phone"] == "+1-555-0200"
      assert updated["metadata"]["updated"] == "true"
    end
  end

  describe "DELETE /v1/customers/:id - Delete customer" do
    test "deletes an existing customer" do
      # Create customer
      create_conn = request(:post, "/v1/customers", %{"email" => "delete@example.com"})
      customer_id = json_response(create_conn)["id"]

      # Delete it
      conn = request(:delete, "/v1/customers/#{customer_id}")

      assert conn.status == 200
      result = json_response(conn)
      assert result["deleted"] == true
      assert result["id"] == customer_id
      assert result["object"] == "customer"
    end

    test "returns 404 when deleting non-existent customer" do
      conn = request(:delete, "/v1/customers/cus_nonexistent")

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "customer is not retrievable after deletion" do
      # Create customer
      create_conn = request(:post, "/v1/customers", %{"email" => "deleted@example.com"})
      customer_id = json_response(create_conn)["id"]

      # Delete it
      delete_conn = request(:delete, "/v1/customers/#{customer_id}")
      assert delete_conn.status == 200

      # Try to retrieve - should be 404
      retrieve_conn = request(:get, "/v1/customers/#{customer_id}")
      assert retrieve_conn.status == 404
    end

    test "deletion response has correct structure" do
      create_conn = request(:post, "/v1/customers", %{"email" => "struct@example.com"})
      customer_id = json_response(create_conn)["id"]

      conn = request(:delete, "/v1/customers/#{customer_id}")

      assert conn.status == 200
      result = json_response(conn)
      assert Map.has_key?(result, "deleted")
      assert Map.has_key?(result, "id")
      assert Map.has_key?(result, "object")
      assert result["deleted"] == true
    end
  end

  describe "GET /v1/customers - List customers" do
    test "lists customers with default limit" do
      # Create 3 customers
      for i <- 1..3 do
        request(:post, "/v1/customers", %{"email" => "list#{i}@example.com"})
      end

      conn = request(:get, "/v1/customers")

      assert conn.status == 200
      result = json_response(conn)
      assert is_list(result["data"])
      assert length(result["data"]) == 3
      assert result["has_more"] == false
      assert result["object"] == "list"
      assert result["url"] == "/v1/customers"
    end

    test "respects limit parameter" do
      # Create 5 customers
      for i <- 1..5 do
        request(:post, "/v1/customers", %{"email" => "limit#{i}@example.com"})
      end

      conn = request(:get, "/v1/customers?limit=2")

      assert conn.status == 200
      result = json_response(conn)
      assert length(result["data"]) == 2
      assert result["has_more"] == true
    end

    test "returns all customers when limit is greater than total" do
      # Create 2 customers
      for i <- 1..2 do
        request(:post, "/v1/customers", %{"email" => "high_limit#{i}@example.com"})
      end

      conn = request(:get, "/v1/customers?limit=100")

      assert conn.status == 200
      result = json_response(conn)
      assert length(result["data"]) == 2
      assert result["has_more"] == false
    end

    test "supports starting_after cursor pagination" do
      # Create 5 customers with delays to ensure different timestamps
      for i <- 1..5 do
        request(:post, "/v1/customers", %{"email" => "cursor#{i}@example.com"})
        # Ensure different timestamps
        Process.sleep(2)
      end

      # Get first page with limit 2
      conn1 = request(:get, "/v1/customers?limit=2")
      assert conn1.status == 200
      page1 = json_response(conn1)
      assert length(page1["data"]) == 2
      assert page1["has_more"] == true

      # Get second page using starting_after
      # Use the LAST customer from first page as cursor
      last_customer_id = Enum.at(page1["data"], 1)["id"]
      conn2 = request(:get, "/v1/customers?limit=2&starting_after=#{last_customer_id}")

      assert conn2.status == 200
      page2 = json_response(conn2)
      assert page2["data"] != []

      # Verify that the cursor customer is not in second page
      page2_ids = Enum.map(page2["data"], & &1["id"])
      assert not Enum.member?(page2_ids, last_customer_id)
    end

    test "returns empty list when no customers exist" do
      conn = request(:get, "/v1/customers")

      assert conn.status == 200
      result = json_response(conn)
      assert result["data"] == []
      assert result["has_more"] == false
    end

    test "customers are sorted by creation time (descending)" do
      # Create customers with delays to ensure different timestamps
      for i <- 1..3 do
        request(:post, "/v1/customers", %{"email" => "sort#{i}@example.com"})
        # Small delay to ensure different timestamps
        Process.sleep(1)
      end

      conn = request(:get, "/v1/customers?limit=10")

      assert conn.status == 200
      result = json_response(conn)
      returned_customers = result["data"]

      # Verify they are sorted by created time (descending - newest first)
      created_times = Enum.map(returned_customers, & &1["created"])
      sorted_times = Enum.sort(created_times, :desc)
      assert created_times == sorted_times
    end

    test "list includes all customer fields" do
      request(:post, "/v1/customers", %{
        "email" => "fields@example.com",
        "metadata" => %{"key" => "value"},
        "name" => "Test Customer"
      })

      conn = request(:get, "/v1/customers")

      assert conn.status == 200
      customer = Enum.at(json_response(conn)["data"], 0)

      # Verify expected fields are present
      assert Map.has_key?(customer, "id")
      assert Map.has_key?(customer, "object")
      assert Map.has_key?(customer, "created")
      assert Map.has_key?(customer, "email")
      assert Map.has_key?(customer, "name")
      assert Map.has_key?(customer, "metadata")
    end

    test "pagination with limit=1 creates multiple pages" do
      # Create 3 customers
      for i <- 1..3 do
        request(:post, "/v1/customers", %{"email" => "page#{i}@example.com"})
      end

      # First page
      conn1 = request(:get, "/v1/customers?limit=1")
      assert conn1.status == 200
      page1 = json_response(conn1)
      assert length(page1["data"]) == 1
      assert page1["has_more"] == true

      # Second page using cursor
      cursor = Enum.at(page1["data"], 0)["id"]
      conn2 = request(:get, "/v1/customers?limit=1&starting_after=#{cursor}")
      assert conn2.status == 200
      page2 = json_response(conn2)
      assert length(page2["data"]) == 1
      assert page2["has_more"] == true

      # Third page using cursor
      cursor2 = Enum.at(page2["data"], 0)["id"]
      conn3 = request(:get, "/v1/customers?limit=1&starting_after=#{cursor2}")
      assert conn3.status == 200
      page3 = json_response(conn3)
      assert length(page3["data"]) == 1
      assert page3["has_more"] == false
    end
  end

  describe "Integration - Full CRUD flow" do
    test "complete customer lifecycle" do
      # 1. Create
      create_conn =
        request(:post, "/v1/customers", %{
          "email" => "lifecycle@example.com",
          "metadata" => %{"status" => "new"},
          "name" => "Lifecycle Test"
        })

      assert create_conn.status == 200
      customer = json_response(create_conn)
      customer_id = customer["id"]
      assert customer["email"] == "lifecycle@example.com"
      assert customer["metadata"]["status"] == "new"

      # 2. Retrieve
      retrieve_conn = request(:get, "/v1/customers/#{customer_id}")

      assert retrieve_conn.status == 200
      retrieved = json_response(retrieve_conn)
      assert retrieved["id"] == customer_id
      assert retrieved["email"] == "lifecycle@example.com"

      # 3. Update
      update_conn =
        request(:post, "/v1/customers/#{customer_id}", %{
          "email" => "lifecycle_updated@example.com",
          "metadata" => %{"status" => "active"}
        })

      assert update_conn.status == 200
      updated = json_response(update_conn)
      assert updated["email"] == "lifecycle_updated@example.com"
      assert updated["metadata"]["status"] == "active"

      # 4. List (verify it's in the list)
      list_conn = request(:get, "/v1/customers")

      assert list_conn.status == 200
      customers = json_response(list_conn)["data"]
      found = Enum.find(customers, &(&1["id"] == customer_id))
      assert found != nil
      assert found["email"] == "lifecycle_updated@example.com"

      # 5. Delete
      delete_conn = request(:delete, "/v1/customers/#{customer_id}")

      assert delete_conn.status == 200
      assert json_response(delete_conn)["deleted"] == true

      # 6. Verify deleted (404 on retrieve)
      final_conn = request(:get, "/v1/customers/#{customer_id}")

      assert final_conn.status == 404
    end

    test "multiple customers can coexist" do
      # Create multiple customers
      ids =
        for i <- 1..3 do
          response =
            request(:post, "/v1/customers", %{
              "email" => "coexist#{i}@example.com",
              "name" => "Customer #{i}"
            })

          json_response(response)["id"]
        end

      # Verify all exist
      Enum.each(ids, fn id ->
        conn = request(:get, "/v1/customers/#{id}")
        assert conn.status == 200
      end)

      # List should show all
      list_conn = request(:get, "/v1/customers?limit=10")
      assert list_conn.status == 200
      list_ids = Enum.map(json_response(list_conn)["data"], & &1["id"])

      Enum.each(ids, fn id ->
        assert Enum.member?(list_ids, id)
      end)
    end

    test "updating one customer doesn't affect others" do
      # Create two customers
      conn1 = request(:post, "/v1/customers", %{"email" => "customer1@example.com"})
      customer1_id = json_response(conn1)["id"]

      conn2 = request(:post, "/v1/customers", %{"email" => "customer2@example.com"})
      customer2_id = json_response(conn2)["id"]

      # Update customer1
      update_conn =
        request(:post, "/v1/customers/#{customer1_id}", %{"name" => "Updated Customer 1"})

      assert update_conn.status == 200

      # Verify customer2 is unchanged
      check_conn = request(:get, "/v1/customers/#{customer2_id}")

      assert check_conn.status == 200
      assert is_nil(json_response(check_conn)["name"])
    end

    test "deleting one customer doesn't affect others" do
      # Create two customers
      conn1 = request(:post, "/v1/customers", %{"email" => "delete1@example.com"})
      customer1_id = json_response(conn1)["id"]

      conn2 = request(:post, "/v1/customers", %{"email" => "delete2@example.com"})
      customer2_id = json_response(conn2)["id"]

      # Delete customer1
      delete_conn = request(:delete, "/v1/customers/#{customer1_id}")
      assert delete_conn.status == 200

      # Verify customer2 still exists
      check_conn = request(:get, "/v1/customers/#{customer2_id}")
      assert check_conn.status == 200
      assert json_response(check_conn)["id"] == customer2_id
    end
  end

  describe "Edge cases and validation" do
    test "handles very long email addresses" do
      long_email = "very.long.email.address+test@subdomain.example.co.uk"

      conn = request(:post, "/v1/customers", %{"email" => long_email})

      assert conn.status == 200
      assert json_response(conn)["email"] == long_email
    end

    test "handles special characters in metadata" do
      metadata = %{
        "quotes" => "\"quoted\" 'value'",
        "special" => "!@#$%^&*()",
        "unicode" => "你好世界"
      }

      conn = request(:post, "/v1/customers", %{"metadata" => metadata})

      assert conn.status == 200
      returned_metadata = json_response(conn)["metadata"]
      assert returned_metadata["special"] == metadata["special"]
      assert returned_metadata["unicode"] == metadata["unicode"]
      assert returned_metadata["quotes"] == metadata["quotes"]
    end

    test "handles empty metadata object" do
      conn = request(:post, "/v1/customers", %{"metadata" => %{}})

      assert conn.status == 200
      assert json_response(conn)["metadata"] == %{}
    end

    test "handles empty string email as nil" do
      conn = request(:post, "/v1/customers", %{"email" => ""})

      assert conn.status == 200
      # Empty string should either be omitted or treated as nil
      email = json_response(conn)["email"]
      assert is_nil(email) or email == ""
    end

    test "generates unique customer IDs" do
      id_set =
        for _i <- 1..5 do
          conn = request(:post, "/v1/customers", %{})
          json_response(conn)["id"]
        end
        |> MapSet.new()

      # All IDs should be unique
      assert MapSet.size(id_set) == 5
    end
  end
end
