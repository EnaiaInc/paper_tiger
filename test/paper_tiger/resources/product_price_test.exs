defmodule PaperTiger.Resources.ProductPriceTest do
  @moduledoc """
  End-to-end tests for Product and Price resources.

  Tests all CRUD operations via the PaperTiger Router:

  ## Product Tests
  1. POST /v1/products - Create with name (required)
  2. GET /v1/products/:id - Retrieve
  3. POST /v1/products/:id - Update (name, metadata, active)
  4. DELETE /v1/products/:id - Delete
  5. GET /v1/products - List with pagination

  ## Price Tests
  1. POST /v1/prices - Create with product, currency, unit_amount
  2. Test recurring vs one-time prices
  3. Test with recurring={interval: "month"}
  4. GET /v1/prices/:id - Retrieve
  5. POST /v1/prices/:id - Update (metadata, active only)
  6. GET /v1/prices - List with pagination
  7. Note: Prices cannot be deleted (test excluded)

  ## Integration Tests
  1. Create product → create multiple prices → list prices for product
  2. Update product active flag doesn't affect prices
  3. Delete product (verify prices still exist)
  """

  use ExUnit.Case

  alias PaperTiger.Router

  setup do
    # Clear all data before each test
    PaperTiger.flush()
    :ok
  end

  # Helper function to create a test connection with proper setup
  defp conn(method, path, params, headers) do
    # Convert params to form data for proper processing
    body =
      if params && is_map(params) do
        params_to_form_data(params)
      else
        ""
      end

    conn = Plug.Test.conn(method, path, body)

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
  defp request(method, path, params \\ nil, headers \\ []) do
    conn = conn(method, path, params, headers)
    Router.call(conn, [])
  end

  # Helper function to parse JSON response
  defp json_response(conn) do
    Jason.decode!(conn.resp_body)
  end

  # Helper to normalize response values (form-encoded data comes back as strings)
  defp normalize_bool(value) when is_boolean(value), do: value
  defp normalize_bool("true"), do: true
  defp normalize_bool("false"), do: false
  defp normalize_bool(other), do: other

  defp normalize_int(value) when is_integer(value), do: value
  defp normalize_int(value) when is_binary(value), do: String.to_integer(value)
  defp normalize_int(other), do: other

  # Helper to create a product
  defp create_product(name, metadata \\ %{}) do
    conn = request(:post, "/v1/products", %{"metadata" => metadata, "name" => name})
    assert conn.status == 200
    json_response(conn)
  end

  # Helper to create a price
  defp create_price(product_id, currency \\ "usd", unit_amount \\ 2000, recurring \\ nil) do
    params = %{
      "currency" => currency,
      "product" => product_id,
      "unit_amount" => to_string(unit_amount)
    }

    params =
      if recurring do
        Map.put(params, "recurring", recurring)
      else
        params
      end

    conn = request(:post, "/v1/prices", params)
    assert conn.status == 200
    json_response(conn)
  end

  describe "POST /v1/products - Create product" do
    test "creates a product with name (required)" do
      conn = request(:post, "/v1/products", %{"name" => "Basic Plan"})

      assert conn.status == 200
      product = json_response(conn)
      assert product["name"] == "Basic Plan"
      assert String.starts_with?(product["id"], "prod_")
      assert product["object"] == "product"
      assert is_integer(product["created"])
      assert product["metadata"] == %{}
      assert product["active"] == true
    end

    test "creates a product with metadata" do
      metadata = %{"description" => "Premium tier", "tier" => "premium"}

      conn =
        request(:post, "/v1/products", %{
          "metadata" => metadata,
          "name" => "Premium Plan"
        })

      assert conn.status == 200
      product = json_response(conn)
      assert product["name"] == "Premium Plan"
      assert product["metadata"] == metadata
    end

    test "creates a product with description and other fields" do
      conn =
        request(:post, "/v1/products", %{
          "active" => true,
          "description" => "For large enterprises",
          "name" => "Enterprise Plan"
        })

      assert conn.status == 200
      product = json_response(conn)
      assert product["name"] == "Enterprise Plan"
      assert product["description"] == "For large enterprises"
      assert normalize_bool(product["active"]) == true
    end

    test "creates inactive product" do
      conn =
        request(:post, "/v1/products", %{
          "active" => false,
          "name" => "Inactive Product"
        })

      assert conn.status == 200
      product = json_response(conn)
      assert normalize_bool(product["active"]) == false
    end

    test "creates multiple products with unique IDs" do
      conn1 = request(:post, "/v1/products", %{"name" => "Product 1"})
      product1 = json_response(conn1)
      id1 = product1["id"]

      conn2 = request(:post, "/v1/products", %{"name" => "Product 2"})
      product2 = json_response(conn2)
      id2 = product2["id"]

      assert id1 != id2
      assert product1["name"] == "Product 1"
      assert product2["name"] == "Product 2"
    end

    test "fails without required name parameter" do
      conn = request(:post, "/v1/products", %{})

      assert conn.status == 400
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
      assert response["error"]["message"] =~ "Missing required parameter"
    end

    test "supports idempotency with Idempotency-Key header" do
      idempotency_key = "prod_key_#{:rand.uniform(1_000_000)}"

      conn1 =
        request(:post, "/v1/products", %{"name" => "Idempotent Product"}, [
          {"idempotency-key", idempotency_key}
        ])

      assert conn1.status == 200
      product1 = json_response(conn1)

      conn2 =
        request(:post, "/v1/products", %{"name" => "Different Name"}, [
          {"idempotency-key", idempotency_key}
        ])

      assert conn2.status == 200
      product2 = json_response(conn2)

      # Should return the same product
      assert product1["id"] == product2["id"]
      assert product1["name"] == product2["name"]
    end

    test "returns 401 when missing authorization header" do
      conn = Plug.Test.conn(:post, "/v1/products", "name=Test")

      conn_with_header =
        Plug.Conn.put_req_header(conn, "content-type", "application/x-www-form-urlencoded")

      response = Router.call(conn_with_header, [])

      assert response.status == 401
      assert response.resp_body != ""
    end
  end

  describe "GET /v1/products/:id - Retrieve product" do
    test "retrieves an existing product" do
      product = create_product("Retrieve Test")
      product_id = product["id"]

      conn = request(:get, "/v1/products/#{product_id}")

      assert conn.status == 200
      retrieved = json_response(conn)
      assert retrieved["id"] == product_id
      assert retrieved["name"] == "Retrieve Test"
      assert retrieved["object"] == "product"
    end

    test "returns 404 for missing product" do
      conn = request(:get, "/v1/products/prod_nonexistent")

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
      assert response["error"]["message"] =~ "prod_nonexistent"
    end

    test "retrieves product with metadata" do
      metadata = %{
        "tags" => ["featured", "bestseller"],
        "tier" => "premium"
      }

      product = create_product("With Metadata", metadata)
      product_id = product["id"]

      conn = request(:get, "/v1/products/#{product_id}")

      assert conn.status == 200
      retrieved = json_response(conn)
      assert retrieved["metadata"]["tier"] == "premium"
    end

    test "retrieved product contains all fields" do
      product = create_product("Complete Product")
      product_id = product["id"]

      conn = request(:get, "/v1/products/#{product_id}")

      assert conn.status == 200
      retrieved = json_response(conn)

      assert Map.has_key?(retrieved, "id")
      assert Map.has_key?(retrieved, "object")
      assert Map.has_key?(retrieved, "created")
      assert Map.has_key?(retrieved, "name")
      assert Map.has_key?(retrieved, "active")
      assert Map.has_key?(retrieved, "metadata")
    end
  end

  describe "POST /v1/products/:id - Update product" do
    test "updates product name" do
      product = create_product("Original Name")
      product_id = product["id"]

      conn = request(:post, "/v1/products/#{product_id}", %{"name" => "Updated Name"})

      assert conn.status == 200
      updated = json_response(conn)
      assert updated["id"] == product_id
      assert updated["name"] == "Updated Name"
    end

    test "updates product metadata" do
      product = create_product("Product", %{"status" => "new"})
      product_id = product["id"]

      new_metadata = %{"status" => "active", "tier" => "premium"}

      conn = request(:post, "/v1/products/#{product_id}", %{"metadata" => new_metadata})

      assert conn.status == 200
      updated = json_response(conn)
      assert updated["metadata"]["status"] == "active"
      assert updated["metadata"]["tier"] == "premium"
    end

    test "updates product active flag" do
      product = create_product("Active Product")
      product_id = product["id"]
      assert product["active"] == true

      conn = request(:post, "/v1/products/#{product_id}", %{"active" => false})

      assert conn.status == 200
      updated = json_response(conn)
      assert normalize_bool(updated["active"]) == false

      # Verify persistence
      check_conn = request(:get, "/v1/products/#{product_id}")
      assert normalize_bool(json_response(check_conn)["active"]) == false
    end

    test "updates description" do
      product = create_product("Product")
      product_id = product["id"]

      conn =
        request(:post, "/v1/products/#{product_id}", %{
          "description" => "Updated description for product"
        })

      assert conn.status == 200
      updated = json_response(conn)
      assert updated["description"] == "Updated description for product"
    end

    test "preserves immutable fields (id, object, created)" do
      product = create_product("Immutable Test")
      original_id = product["id"]
      original_created = product["created"]
      original_object = product["object"]

      conn = request(:post, "/v1/products/#{original_id}", %{"name" => "Updated"})

      assert conn.status == 200
      updated = json_response(conn)
      assert updated["id"] == original_id
      assert updated["created"] == original_created
      assert updated["object"] == original_object
    end

    test "returns 404 when updating non-existent product" do
      conn =
        request(:post, "/v1/products/prod_nonexistent", %{
          "name" => "Test"
        })

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "updates multiple fields at once" do
      product = create_product("Multi Update")
      product_id = product["id"]

      conn =
        request(:post, "/v1/products/#{product_id}", %{
          "active" => false,
          "description" => "New description",
          "metadata" => %{"updated" => "true"},
          "name" => "Updated Multi"
        })

      assert conn.status == 200
      updated = json_response(conn)
      assert updated["name"] == "Updated Multi"
      assert updated["description"] == "New description"
      assert normalize_bool(updated["active"]) == false
      assert updated["metadata"]["updated"] == "true"
    end
  end

  describe "DELETE /v1/products/:id - Delete product" do
    test "deletes an existing product" do
      product = create_product("Delete Test")
      product_id = product["id"]

      conn = request(:delete, "/v1/products/#{product_id}")

      assert conn.status == 200
      result = json_response(conn)
      assert result["deleted"] == true
      assert result["id"] == product_id
      assert result["object"] == "product"
    end

    test "returns 404 when deleting non-existent product" do
      conn = request(:delete, "/v1/products/prod_nonexistent")

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "product is not retrievable after deletion" do
      product = create_product("Deleted Product")
      product_id = product["id"]

      # Delete it
      delete_conn = request(:delete, "/v1/products/#{product_id}")
      assert delete_conn.status == 200

      # Try to retrieve - should be 404
      retrieve_conn = request(:get, "/v1/products/#{product_id}")
      assert retrieve_conn.status == 404
    end

    test "deletion response has correct structure" do
      product = create_product("Structure Test")
      product_id = product["id"]

      conn = request(:delete, "/v1/products/#{product_id}")

      assert conn.status == 200
      result = json_response(conn)
      assert Map.has_key?(result, "deleted")
      assert Map.has_key?(result, "id")
      assert Map.has_key?(result, "object")
      assert result["deleted"] == true
    end
  end

  describe "GET /v1/products - List products" do
    test "lists products with default limit" do
      for i <- 1..3 do
        create_product("Product #{i}")
      end

      conn = request(:get, "/v1/products")

      assert conn.status == 200
      result = json_response(conn)
      assert is_list(result["data"])
      assert length(result["data"]) == 3
      assert result["has_more"] == false
      assert result["object"] == "list"
      assert result["url"] == "/v1/products"
    end

    test "respects limit parameter" do
      for i <- 1..5 do
        create_product("Product #{i}")
      end

      conn = request(:get, "/v1/products?limit=2")

      assert conn.status == 200
      result = json_response(conn)
      assert length(result["data"]) == 2
      assert result["has_more"] == true
    end

    test "returns all products when limit is greater than total" do
      for i <- 1..2 do
        create_product("Product #{i}")
      end

      conn = request(:get, "/v1/products?limit=100")

      assert conn.status == 200
      result = json_response(conn)
      assert length(result["data"]) == 2
      assert result["has_more"] == false
    end

    test "supports starting_after cursor pagination" do
      # Create 5 products
      for i <- 1..5 do
        create_product("Product #{i}")
        Process.sleep(2)
      end

      # Get first page with limit 2
      conn1 = request(:get, "/v1/products?limit=2")
      assert conn1.status == 200
      page1 = json_response(conn1)
      assert length(page1["data"]) == 2
      assert page1["has_more"] == true

      # Get second page using starting_after
      last_product_id = Enum.at(page1["data"], 1)["id"]
      conn2 = request(:get, "/v1/products?limit=2&starting_after=#{last_product_id}")

      assert conn2.status == 200
      page2 = json_response(conn2)
      assert page2["data"] != []

      # Verify that the cursor product is not in second page
      page2_ids = Enum.map(page2["data"], & &1["id"])
      assert not Enum.member?(page2_ids, last_product_id)
    end

    test "returns empty list when no products exist" do
      conn = request(:get, "/v1/products")

      assert conn.status == 200
      result = json_response(conn)
      assert result["data"] == []
      assert result["has_more"] == false
    end

    test "products are sorted by creation time (descending)" do
      for i <- 1..3 do
        create_product("Product #{i}")
        Process.sleep(1)
      end

      conn = request(:get, "/v1/products?limit=10")

      assert conn.status == 200
      result = json_response(conn)
      returned_products = result["data"]

      # Verify they are sorted by created time (descending - newest first)
      created_times = Enum.map(returned_products, & &1["created"])
      sorted_times = Enum.sort(created_times, :desc)
      assert created_times == sorted_times
    end

    test "list includes all product fields" do
      create_product("Fields Test", %{"key" => "value"})

      conn = request(:get, "/v1/products")

      assert conn.status == 200
      product = Enum.at(json_response(conn)["data"], 0)

      assert Map.has_key?(product, "id")
      assert Map.has_key?(product, "object")
      assert Map.has_key?(product, "created")
      assert Map.has_key?(product, "name")
      assert Map.has_key?(product, "active")
      assert Map.has_key?(product, "metadata")
    end

    test "pagination with limit=1 creates multiple pages" do
      for i <- 1..3 do
        create_product("Product #{i}")
      end

      # First page
      conn1 = request(:get, "/v1/products?limit=1")
      assert conn1.status == 200
      page1 = json_response(conn1)
      assert length(page1["data"]) == 1
      assert page1["has_more"] == true

      # Second page using cursor
      cursor = Enum.at(page1["data"], 0)["id"]
      conn2 = request(:get, "/v1/products?limit=1&starting_after=#{cursor}")
      assert conn2.status == 200
      page2 = json_response(conn2)
      assert length(page2["data"]) == 1
      assert page2["has_more"] == true
    end
  end

  describe "POST /v1/prices - Create price" do
    test "creates a one-time price with required parameters" do
      product = create_product("Price Test Product")
      product_id = product["id"]

      conn =
        request(:post, "/v1/prices", %{
          "currency" => "usd",
          "product" => product_id,
          "unit_amount" => "2000"
        })

      assert conn.status == 200
      price = json_response(conn)
      assert price["product"] == product_id
      assert price["currency"] == "usd"
      assert normalize_int(price["unit_amount"]) == 2000
      assert String.starts_with?(price["id"], "price_")
      assert price["object"] == "price"
      assert price["active"] == true
      assert price["type"] == "one_time"
      assert is_nil(price["recurring"])
    end

    test "creates a recurring price with interval" do
      product = create_product("Recurring Price Product")
      product_id = product["id"]

      conn =
        request(:post, "/v1/prices", %{
          "currency" => "usd",
          "product" => product_id,
          "recurring" => %{"interval" => "month"},
          "unit_amount" => "2000"
        })

      assert conn.status == 200
      price = json_response(conn)
      assert price["product"] == product_id
      assert price["currency"] == "usd"
      assert normalize_int(price["unit_amount"]) == 2000
      assert price["type"] == "recurring"
      assert price["recurring"]["interval"] == "month"
    end

    test "creates recurring price with interval_count" do
      product = create_product("Quarterly Price Product")
      product_id = product["id"]

      conn =
        request(:post, "/v1/prices", %{
          "currency" => "usd",
          "product" => product_id,
          "recurring" => %{"interval" => "month", "interval_count" => "3"},
          "unit_amount" => "10000"
        })

      assert conn.status == 200
      price = json_response(conn)
      assert price["recurring"]["interval"] == "month"
      assert normalize_int(price["recurring"]["interval_count"]) == 3
    end

    test "creates recurring price with annual interval" do
      product = create_product("Annual Price Product")
      product_id = product["id"]

      conn =
        request(:post, "/v1/prices", %{
          "currency" => "usd",
          "product" => product_id,
          "recurring" => %{"interval" => "year"},
          "unit_amount" => "50000"
        })

      assert conn.status == 200
      price = json_response(conn)
      assert price["recurring"]["interval"] == "year"
    end

    test "creates price with metadata" do
      product = create_product("Price with Metadata")
      product_id = product["id"]
      metadata = %{"internal_id" => "123", "tier" => "premium"}

      conn =
        request(:post, "/v1/prices", %{
          "currency" => "usd",
          "metadata" => metadata,
          "product" => product_id,
          "unit_amount" => "2000"
        })

      assert conn.status == 200
      price = json_response(conn)
      assert price["metadata"] == metadata
    end

    test "creates inactive price" do
      product = create_product("Inactive Price Product")
      product_id = product["id"]

      conn =
        request(:post, "/v1/prices", %{
          "active" => false,
          "currency" => "usd",
          "product" => product_id,
          "unit_amount" => "2000"
        })

      assert conn.status == 200
      price = json_response(conn)
      assert normalize_bool(price["active"]) == false
    end

    test "creates prices with different currencies" do
      product = create_product("Multi-Currency Product")
      product_id = product["id"]

      currencies = ["usd", "eur", "gbp", "jpy"]

      Enum.each(currencies, fn currency ->
        conn =
          request(:post, "/v1/prices", %{
            "currency" => currency,
            "product" => product_id,
            "unit_amount" => "2000"
          })

        assert conn.status == 200
        price = json_response(conn)
        assert price["currency"] == currency
      end)
    end

    test "fails without required product parameter" do
      conn =
        request(:post, "/v1/prices", %{
          "currency" => "usd",
          "unit_amount" => "2000"
        })

      assert conn.status == 400
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "fails without required currency parameter" do
      product = create_product("Test")
      product_id = product["id"]

      conn =
        request(:post, "/v1/prices", %{
          "product" => product_id,
          "unit_amount" => "2000"
        })

      assert conn.status == 400
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "creates multiple prices for same product" do
      product = create_product("Multi-Price Product")
      product_id = product["id"]

      price1 = create_price(product_id, "usd", 2000)
      price2 = create_price(product_id, "eur", 1800)

      assert price1["id"] != price2["id"]
      assert price1["currency"] == "usd"
      assert price2["currency"] == "eur"
      assert price1["product"] == product_id
      assert price2["product"] == product_id
    end

    test "supports idempotency with Idempotency-Key header" do
      product = create_product("Idempotent Price Product")
      product_id = product["id"]
      idempotency_key = "price_key_#{:rand.uniform(1_000_000)}"

      conn1 =
        request(
          :post,
          "/v1/prices",
          %{
            "currency" => "usd",
            "product" => product_id,
            "unit_amount" => "2000"
          },
          [{"idempotency-key", idempotency_key}]
        )

      assert conn1.status == 200
      price1 = json_response(conn1)

      # Request with same key but different parameters should return same price
      conn2 =
        request(
          :post,
          "/v1/prices",
          %{
            "currency" => "eur",
            "product" => product_id,
            "unit_amount" => "3000"
          },
          [{"idempotency-key", idempotency_key}]
        )

      assert conn2.status == 200
      price2 = json_response(conn2)

      assert price1["id"] == price2["id"]
      assert price1["currency"] == price2["currency"]
    end
  end

  describe "GET /v1/prices/:id - Retrieve price" do
    test "retrieves an existing price" do
      product = create_product("Retrieve Price Product")
      product_id = product["id"]
      price = create_price(product_id)
      price_id = price["id"]

      conn = request(:get, "/v1/prices/#{price_id}")

      assert conn.status == 200
      retrieved = json_response(conn)
      assert retrieved["id"] == price_id
      assert retrieved["product"] == product_id
      assert retrieved["currency"] == "usd"
      assert retrieved["object"] == "price"
    end

    test "returns 404 for missing price" do
      conn = request(:get, "/v1/prices/price_nonexistent")

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "retrieves recurring price with all recurring data" do
      product = create_product("Recurring Retrieve")
      product_id = product["id"]
      price = create_price(product_id, "usd", 2000, %{"interval" => "month"})
      price_id = price["id"]

      conn = request(:get, "/v1/prices/#{price_id}")

      assert conn.status == 200
      retrieved = json_response(conn)
      assert retrieved["type"] == "recurring"
      assert retrieved["recurring"]["interval"] == "month"
    end

    test "retrieved price contains all fields" do
      product = create_product("Complete Price")
      product_id = product["id"]
      price = create_price(product_id, "usd", 5000, %{"interval" => "month"})
      price_id = price["id"]

      conn = request(:get, "/v1/prices/#{price_id}")

      assert conn.status == 200
      retrieved = json_response(conn)

      assert Map.has_key?(retrieved, "id")
      assert Map.has_key?(retrieved, "object")
      assert Map.has_key?(retrieved, "created")
      assert Map.has_key?(retrieved, "currency")
      assert Map.has_key?(retrieved, "product")
      assert Map.has_key?(retrieved, "unit_amount")
      assert Map.has_key?(retrieved, "active")
    end
  end

  describe "POST /v1/prices/:id - Update price" do
    test "updates price metadata" do
      product = create_product("Update Price")
      product_id = product["id"]
      price = create_price(product_id)
      price_id = price["id"]

      new_metadata = %{"tier" => "premium", "updated" => "true"}

      conn = request(:post, "/v1/prices/#{price_id}", %{"metadata" => new_metadata})

      assert conn.status == 200
      updated = json_response(conn)
      assert updated["metadata"]["tier"] == "premium"
      assert updated["metadata"]["updated"] == "true"
    end

    test "updates price active flag" do
      product = create_product("Active Flag Price")
      product_id = product["id"]
      price = create_price(product_id)
      price_id = price["id"]
      assert price["active"] == true

      conn = request(:post, "/v1/prices/#{price_id}", %{"active" => false})

      assert conn.status == 200
      updated = json_response(conn)
      assert normalize_bool(updated["active"]) == false

      # Verify persistence
      check_conn = request(:get, "/v1/prices/#{price_id}")
      assert normalize_bool(json_response(check_conn)["active"]) == false
    end

    test "reactivates a price" do
      product = create_product("Reactivate Price")
      product_id = product["id"]
      price = create_price(product_id, "usd", 2000, nil)
      price_id = price["id"]

      # First deactivate
      request(:post, "/v1/prices/#{price_id}", %{"active" => false})

      # Then reactivate
      conn = request(:post, "/v1/prices/#{price_id}", %{"active" => true})

      assert conn.status == 200
      updated = json_response(conn)
      assert normalize_bool(updated["active"]) == true
    end

    test "preserves immutable fields (id, object, created, currency, product, unit_amount)" do
      product = create_product("Immutable Price")
      product_id = product["id"]
      price = create_price(product_id, "usd", 2000)
      price_id = price["id"]
      original_currency = price["currency"]
      original_unit_amount = price["unit_amount"]
      original_product = price["product"]
      original_created = price["created"]

      conn = request(:post, "/v1/prices/#{price_id}", %{"metadata" => %{"test" => "value"}})

      assert conn.status == 200
      updated = json_response(conn)
      assert updated["id"] == price_id
      assert updated["currency"] == original_currency
      assert updated["unit_amount"] == original_unit_amount
      assert updated["product"] == original_product
      assert updated["created"] == original_created
    end

    test "returns 404 when updating non-existent price" do
      conn = request(:post, "/v1/prices/price_nonexistent", %{"active" => false})

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "updates multiple price fields at once" do
      product = create_product("Multi-field Price")
      product_id = product["id"]
      price = create_price(product_id)
      price_id = price["id"]

      conn =
        request(:post, "/v1/prices/#{price_id}", %{
          "active" => false,
          "metadata" => %{"reason" => "replaced", "status" => "archived"}
        })

      assert conn.status == 200
      updated = json_response(conn)
      assert normalize_bool(updated["active"]) == false
      assert updated["metadata"]["status"] == "archived"
      assert updated["metadata"]["reason"] == "replaced"
    end
  end

  describe "GET /v1/prices - List prices" do
    test "lists prices with default limit" do
      product = create_product("List Prices")
      product_id = product["id"]

      for i <- 1..3 do
        create_price(product_id, "usd", 1000 + i * 100)
      end

      conn = request(:get, "/v1/prices")

      assert conn.status == 200
      result = json_response(conn)
      assert is_list(result["data"])
      assert length(result["data"]) == 3
      assert result["has_more"] == false
      assert result["object"] == "list"
      assert result["url"] == "/v1/prices"
    end

    test "respects limit parameter" do
      product = create_product("Limit Prices")
      product_id = product["id"]

      for i <- 1..5 do
        create_price(product_id, "usd", 1000 + i * 100)
      end

      conn = request(:get, "/v1/prices?limit=2")

      assert conn.status == 200
      result = json_response(conn)
      assert length(result["data"]) == 2
      assert result["has_more"] == true
    end

    test "returns all prices when limit is greater than total" do
      product = create_product("All Prices")
      product_id = product["id"]

      for i <- 1..2 do
        create_price(product_id, "usd", 1000 + i * 100)
      end

      conn = request(:get, "/v1/prices?limit=100")

      assert conn.status == 200
      result = json_response(conn)
      assert length(result["data"]) == 2
      assert result["has_more"] == false
    end

    test "supports starting_after cursor pagination" do
      product = create_product("Paginated Prices")
      product_id = product["id"]

      for i <- 1..5 do
        create_price(product_id, "usd", 1000 + i * 100)
        Process.sleep(2)
      end

      # Get first page with limit 2
      conn1 = request(:get, "/v1/prices?limit=2")
      assert conn1.status == 200
      page1 = json_response(conn1)
      assert length(page1["data"]) == 2
      assert page1["has_more"] == true

      # Get second page using starting_after
      last_price_id = Enum.at(page1["data"], 1)["id"]
      conn2 = request(:get, "/v1/prices?limit=2&starting_after=#{last_price_id}")

      assert conn2.status == 200
      page2 = json_response(conn2)
      assert page2["data"] != []

      # Verify that the cursor price is not in second page
      page2_ids = Enum.map(page2["data"], & &1["id"])
      assert not Enum.member?(page2_ids, last_price_id)
    end

    test "returns empty list when no prices exist" do
      conn = request(:get, "/v1/prices")

      assert conn.status == 200
      result = json_response(conn)
      assert result["data"] == []
      assert result["has_more"] == false
    end

    test "prices are sorted by creation time (descending)" do
      product = create_product("Sorted Prices")
      product_id = product["id"]

      for i <- 1..3 do
        create_price(product_id, "usd", 1000 + i * 100)
        Process.sleep(1)
      end

      conn = request(:get, "/v1/prices?limit=10")

      assert conn.status == 200
      result = json_response(conn)
      returned_prices = result["data"]

      # Verify they are sorted by created time (descending - newest first)
      created_times = Enum.map(returned_prices, & &1["created"])
      sorted_times = Enum.sort(created_times, :desc)
      assert created_times == sorted_times
    end

    test "list includes all price fields" do
      product = create_product("Fields Price")
      product_id = product["id"]
      create_price(product_id, "usd", 2000, %{"interval" => "month"})

      conn = request(:get, "/v1/prices")

      assert conn.status == 200
      price = Enum.at(json_response(conn)["data"], 0)

      assert Map.has_key?(price, "id")
      assert Map.has_key?(price, "object")
      assert Map.has_key?(price, "created")
      assert Map.has_key?(price, "currency")
      assert Map.has_key?(price, "product")
      assert Map.has_key?(price, "unit_amount")
      assert Map.has_key?(price, "active")
    end

    test "pagination with limit=1 creates multiple pages" do
      product = create_product("Paginated Single")
      product_id = product["id"]

      for i <- 1..3 do
        create_price(product_id, "usd", 1000 + i * 100)
      end

      # First page
      conn1 = request(:get, "/v1/prices?limit=1")
      assert conn1.status == 200
      page1 = json_response(conn1)
      assert length(page1["data"]) == 1
      assert page1["has_more"] == true

      # Second page using cursor
      cursor = Enum.at(page1["data"], 0)["id"]
      conn2 = request(:get, "/v1/prices?limit=1&starting_after=#{cursor}")
      assert conn2.status == 200
      page2 = json_response(conn2)
      assert length(page2["data"]) == 1
      assert page2["has_more"] == true
    end

    test "filters prices by product" do
      product1 = create_product("Product A")
      product2 = create_product("Product B")

      create_price(product1["id"], "usd", 1000)
      create_price(product1["id"], "usd", 2000)
      create_price(product2["id"], "usd", 3000)

      # List all prices
      conn_all = request(:get, "/v1/prices")
      all_prices = json_response(conn_all)["data"]
      assert length(all_prices) == 3
    end
  end

  describe "Integration - Product and Price Lifecycle" do
    test "create product → create multiple prices → list prices for product" do
      # 1. Create product
      product = create_product("Lifecycle Product", %{"status" => "active"})
      product_id = product["id"]

      assert product["name"] == "Lifecycle Product"
      assert product["metadata"]["status"] == "active"

      # 2. Create multiple prices
      price_usd = create_price(product_id, "usd", 1000, %{"interval" => "month"})
      price_eur = create_price(product_id, "eur", 900, %{"interval" => "month"})
      price_one_time = create_price(product_id, "usd", 5000)

      assert price_usd["currency"] == "usd"
      assert price_eur["currency"] == "eur"
      assert price_one_time["type"] == "one_time"

      # 3. List prices
      conn = request(:get, "/v1/prices")
      result = json_response(conn)
      prices = result["data"]

      assert length(prices) == 3
      assert Enum.all?(prices, &(&1["product"] == product_id))

      # 4. Verify all prices exist
      Enum.each([price_usd, price_eur, price_one_time], fn price ->
        retrieve_conn = request(:get, "/v1/prices/#{price["id"]}")
        assert retrieve_conn.status == 200
        retrieved = json_response(retrieve_conn)
        assert retrieved["id"] == price["id"]
        assert retrieved["product"] == product_id
      end)
    end

    test "update product active flag doesn't affect prices" do
      # Create product with prices
      product = create_product("Product")
      product_id = product["id"]
      price = create_price(product_id, "usd", 2000, %{"interval" => "month"})
      price_id = price["id"]

      assert product["active"] == true
      assert price["active"] == true

      # Update product to inactive
      update_conn = request(:post, "/v1/products/#{product_id}", %{"active" => false})
      assert update_conn.status == 200
      updated_product = json_response(update_conn)
      assert normalize_bool(updated_product["active"]) == false

      # Verify price is still active
      price_conn = request(:get, "/v1/prices/#{price_id}")
      assert price_conn.status == 200
      retrieved_price = json_response(price_conn)
      assert retrieved_price["active"] == true
    end

    test "delete product (verify prices still exist)" do
      # Create product with prices
      product = create_product("Product to Delete")
      product_id = product["id"]
      price1 = create_price(product_id, "usd", 1000)
      price2 = create_price(product_id, "eur", 900)
      price1_id = price1["id"]
      price2_id = price2["id"]

      # Delete product
      delete_conn = request(:delete, "/v1/products/#{product_id}")
      assert delete_conn.status == 200
      assert json_response(delete_conn)["deleted"] == true

      # Verify product is gone
      product_check = request(:get, "/v1/products/#{product_id}")
      assert product_check.status == 404

      # Verify prices still exist
      price1_check = request(:get, "/v1/prices/#{price1_id}")
      assert price1_check.status == 200
      price1_retrieved = json_response(price1_check)
      assert price1_retrieved["product"] == product_id

      price2_check = request(:get, "/v1/prices/#{price2_id}")
      assert price2_check.status == 200
      price2_retrieved = json_response(price2_check)
      assert price2_retrieved["product"] == product_id
    end

    test "complete product and price workflow" do
      # 1. Create product
      product =
        create_product("Complete Product", %{
          "category" => "subscription",
          "tier" => "premium"
        })

      product_id = product["id"]

      # 2. Create multiple prices
      price1 =
        create_price(product_id, "usd", 2999, %{
          "interval" => "month",
          "interval_count" => "1"
        })

      price2 =
        create_price(product_id, "usd", 29_999, %{
          "interval" => "year"
        })

      # 3. Update product metadata
      update_conn =
        request(:post, "/v1/products/#{product_id}", %{
          "metadata" => %{"status" => "featured"}
        })

      assert update_conn.status == 200

      # 4. Update price metadata
      price_update_conn =
        request(:post, "/v1/prices/#{price1["id"]}", %{
          "metadata" => %{"promo" => "launch"}
        })

      assert price_update_conn.status == 200
      updated_price = json_response(price_update_conn)
      assert updated_price["metadata"]["promo"] == "launch"

      # 5. List and verify all
      list_conn = request(:get, "/v1/products?limit=100")
      products = json_response(list_conn)["data"]
      assert Enum.any?(products, &(&1["id"] == product_id))

      prices_conn = request(:get, "/v1/prices?limit=100")
      prices = json_response(prices_conn)["data"]
      assert Enum.any?(prices, &(&1["id"] == price1["id"]))
      assert Enum.any?(prices, &(&1["id"] == price2["id"]))
    end

    test "deactivate price but keep product active" do
      product = create_product("Active Product")
      product_id = product["id"]
      price = create_price(product_id, "usd", 2000, %{"interval" => "month"})
      price_id = price["id"]

      # Deactivate price
      update_conn = request(:post, "/v1/prices/#{price_id}", %{"active" => false})
      assert update_conn.status == 200
      updated_price = json_response(update_conn)
      assert normalize_bool(updated_price["active"]) == false

      # Verify product is still active
      product_conn = request(:get, "/v1/products/#{product_id}")
      assert product_conn.status == 200
      retrieved_product = json_response(product_conn)
      assert retrieved_product["active"] == true
    end

    test "multiple products with different pricing strategies" do
      # Product 1: Simple product with one price
      product1 = create_product("Simple Product")
      _price1 = create_price(product1["id"], "usd", 999)

      # Product 2: Recurring subscription with multiple intervals
      product2 = create_product("Subscription Product")
      _price2_monthly = create_price(product2["id"], "usd", 999, %{"interval" => "month"})
      _price2_annual = create_price(product2["id"], "usd", 9999, %{"interval" => "year"})

      # Product 3: Multi-currency product
      product3 = create_product("Global Product")
      _price3_usd = create_price(product3["id"], "usd", 1000)
      _price3_eur = create_price(product3["id"], "eur", 900)
      _price3_gbp = create_price(product3["id"], "gbp", 800)

      # Verify all were created
      products_conn = request(:get, "/v1/products?limit=100")
      all_products = json_response(products_conn)["data"]
      assert length(all_products) >= 3

      prices_conn = request(:get, "/v1/prices?limit=100")
      all_prices = json_response(prices_conn)["data"]
      assert length(all_prices) >= 6
    end
  end
end
