defmodule PaperTiger.TestHelpers do
  @moduledoc """
  ExUnit test helpers for PaperTiger.

  Provides convenient functions for testing PaperTiger integrations:

  ## HTTP Request Helpers

  Make HTTP requests with automatic Bearer token authentication:

      test "create customer" do
        response = PaperTiger.TestHelpers.post("/v1/customers", %{email: "test@example.com"})
        assert response["object"] == "customer"
      end

      response = PaperTiger.TestHelpers.get("/v1/customers")
      assert response["object"] == "list"

  ## Data Creation Helpers

  Quickly create common Stripe objects:

      customer = PaperTiger.TestHelpers.create_customer(email: "user@example.com")
      product = PaperTiger.TestHelpers.create_product(name: "Premium")
      price = PaperTiger.TestHelpers.create_price(product["id"], unit_amount: 9999)
      subscription = PaperTiger.TestHelpers.create_subscription(customer["id"], price["id"])

  ## Assertion Helpers

  Validate response structures:

      PaperTiger.TestHelpers.assert_stripe_object(response, "customer")
      PaperTiger.TestHelpers.assert_list_response(response)
      PaperTiger.TestHelpers.assert_error_response(response, "invalid_request_error")

  ## Time Helpers

  Control time in tests:

      PaperTiger.TestHelpers.advance_time(days: 30)
      PaperTiger.TestHelpers.advance_time(seconds: 3600)
      PaperTiger.TestHelpers.reset_time()

  All HTTP requests automatically include the Bearer token header.
  """

  import ExUnit.Assertions

  @default_auth_token "sk_test_123"

  # ============================================================================
  # HTTP Request Helpers
  # ============================================================================

  @doc """
  Makes a POST request with automatic Bearer token authentication.

  ## Parameters

  - `path` - Request path (e.g., "/v1/customers")
  - `params` - Request body as a map
  - `opts` - Optional keyword list:
    - `:token` - Authorization token (default: "sk_test_123")
    - `:headers` - Additional headers as a keyword list
    - `:content_type` - Content-Type header (default: "application/x-www-form-urlencoded")

  ## Returns

  Decoded JSON response as a map.

  ## Examples

      iex> response = PaperTiger.TestHelpers.post("/v1/customers", %{email: "test@example.com"})
      iex> response["object"]
      "customer"

      iex> response = PaperTiger.TestHelpers.post(
      ...>   "/v1/customers",
      ...>   %{email: "admin@example.com"},
      ...>   headers: [x_custom: "value"]
      ...> )
  """
  @spec post(String.t(), map(), keyword()) :: map()
  def post(path, params, opts \\ []) do
    token = Keyword.get(opts, :token, @default_auth_token)
    headers = Keyword.get(opts, :headers, [])
    content_type = Keyword.get(opts, :content_type, "application/x-www-form-urlencoded")

    all_headers = [
      {"authorization", "Bearer #{token}"},
      {"content-type", content_type}
      | headers
    ]

    body = encode_body(params, content_type)

    build_conn(:post, path, body, all_headers)
    |> call_router()
    |> decode_response()
  end

  @doc """
  Makes a GET request with automatic Bearer token authentication.

  ## Parameters

  - `path` - Request path (e.g., "/v1/customers")
  - `params` - Query parameters as a map (default: %{})
  - `opts` - Optional keyword list:
    - `:token` - Authorization token (default: "sk_test_123")
    - `:headers` - Additional headers as a keyword list

  ## Returns

  Decoded JSON response as a map.

  ## Examples

      iex> response = PaperTiger.TestHelpers.get("/v1/customers")
      iex> response["object"]
      "list"

      iex> response = PaperTiger.TestHelpers.get(
      ...>   "/v1/customers",
      ...>   %{limit: 10},
      ...>   headers: [x_request_id: "123"]
      ...> )
  """
  @spec get(String.t(), map(), keyword()) :: map()
  def get(path, params \\ %{}, opts \\ []) do
    token = Keyword.get(opts, :token, @default_auth_token)
    headers = Keyword.get(opts, :headers, [])

    all_headers = [
      {"authorization", "Bearer #{token}"}
      | headers
    ]

    query_string = encode_query_params(params)
    full_path = if query_string == "", do: path, else: "#{path}?#{query_string}"

    build_conn(:get, full_path, "", all_headers)
    |> call_router()
    |> decode_response()
  end

  @doc """
  Makes a DELETE request with automatic Bearer token authentication.

  ## Parameters

  - `path` - Request path (e.g., "/v1/customers/cus_123")
  - `opts` - Optional keyword list:
    - `:token` - Authorization token (default: "sk_test_123")
    - `:headers` - Additional headers as a keyword list

  ## Returns

  Decoded JSON response as a map.

  ## Examples

      iex> response = PaperTiger.TestHelpers.delete("/v1/customers/cus_123")
      iex> response["deleted"]
      true
  """
  @spec delete(String.t(), keyword()) :: map()
  def delete(path, opts \\ []) do
    token = Keyword.get(opts, :token, @default_auth_token)
    headers = Keyword.get(opts, :headers, [])

    all_headers = [
      {"authorization", "Bearer #{token}"}
      | headers
    ]

    build_conn(:delete, path, "", all_headers)
    |> call_router()
    |> decode_response()
  end

  # ============================================================================
  # Data Creation Helpers
  # ============================================================================

  @doc """
  Creates a customer with optional parameters.

  ## Parameters

  `params` - Optional keyword list or map with:
  - `:email` - Customer email
  - `:name` - Customer name
  - `:description` - Customer description
  - `:metadata` - Metadata map
  - `:phone` - Customer phone
  - `:address` - Customer address
  - `:shipping` - Shipping address
  - `:tax_exempt` - Tax exemption status ("none", "exempt", "reverse")

  ## Returns

  The created customer object as a map.

  ## Examples

      iex> customer = PaperTiger.TestHelpers.create_customer()
      iex> String.starts_with?(customer["id"], "cus_")
      true

      iex> customer = PaperTiger.TestHelpers.create_customer(email: "user@example.com", name: "John Doe")
      iex> customer["email"]
      "user@example.com"
      iex> customer["name"]
      "John Doe"
  """
  @spec create_customer(map() | keyword()) :: map()
  def create_customer(params \\ %{}) do
    params = normalize_params(params)
    post("/v1/customers", params)
  end

  @doc """
  Creates a product with optional parameters.

  ## Parameters

  `params` - Optional keyword list or map with:
  - `:name` - Product name (required)
  - `:active` - Whether product is active (default: true)
  - `:description` - Product description
  - `:metadata` - Metadata map
  - `:images` - List of image URLs
  - `:statement_descriptor` - Bank statement descriptor
  - `:type` - Product type ("service" or "good")

  ## Returns

  The created product object as a map.

  ## Examples

      iex> product = PaperTiger.TestHelpers.create_product(name: "Premium Plan")
      iex> product["name"]
      "Premium Plan"
      iex> product["object"]
      "product"
  """
  @spec create_product(map() | keyword()) :: map()
  def create_product(params \\ %{}) do
    params = normalize_params(params)
    params = Map.put_new(params, :name, "Test Product")
    post("/v1/products", params)
  end

  @doc """
  Creates a price for a product with optional parameters.

  ## Parameters

  - `product_id` - The product ID (required)
  - `params` - Optional keyword list or map with:
    - `:unit_amount` - Price in cents (required)
    - `:currency` - Currency code (default: "usd")
    - `:type` - Price type ("one_time" or "recurring", default: "one_time")
    - `:recurring` - Recurring period for subscription prices
      - `:interval` - "day", "week", "month", or "year"
      - `:interval_count` - Number of intervals
    - `:metadata` - Metadata map
    - `:nickname` - Price nickname
    - `:billing_scheme` - "per_unit" or "tiered"

  ## Returns

  The created price object as a map.

  ## Examples

      iex> product = PaperTiger.TestHelpers.create_product(name: "Plan")
      iex> price = PaperTiger.TestHelpers.create_price(product["id"], unit_amount: 9999)
      iex> price["unit_amount"]
      9999

      iex> price = PaperTiger.TestHelpers.create_price(
      ...>   product["id"],
      ...>   unit_amount: 2999,
      ...>   recurring: %{interval: "month", interval_count: 1}
      ...> )
      iex> price["type"]
      "recurring"
  """
  @spec create_price(String.t(), map() | keyword()) :: map()
  def create_price(product_id, params \\ %{}) do
    params = normalize_params(params)

    params =
      params
      |> Map.put(:product, product_id)
      |> Map.put_new(:unit_amount, 9999)
      |> Map.put_new(:currency, "usd")

    post("/v1/prices", params)
  end

  @doc """
  Creates a subscription for a customer.

  ## Parameters

  - `customer_id` - The customer ID (required)
  - `price_id` - The price ID (required)
  - `params` - Optional keyword list or map with:
    - `:items` - Override items array (if not provided, uses [{price: price_id}])
    - `:default_payment_method` - Payment method ID
    - `:trial_period_days` - Number of trial days
    - `:metadata` - Metadata map
    - `:billing_cycle_anchor` - Anchor for billing cycle
    - `:cancel_at_period_end` - Cancel at end of period (boolean)
    - `:off_session` - Off-session indicator

  ## Returns

  The created subscription object as a map.

  ## Examples

      iex> customer = PaperTiger.TestHelpers.create_customer()
      iex> product = PaperTiger.TestHelpers.create_product(name: "Plan")
      iex> price = PaperTiger.TestHelpers.create_price(product["id"], unit_amount: 2999)
      iex> subscription = PaperTiger.TestHelpers.create_subscription(customer["id"], price["id"])
      iex> subscription["customer"]
      customer["id"]

      iex> subscription = PaperTiger.TestHelpers.create_subscription(
      ...>   customer["id"],
      ...>   price["id"],
      ...>   trial_period_days: 14
      ...> )
      iex> subscription["status"]
      "trialing"
  """
  @spec create_subscription(String.t(), String.t(), map() | keyword()) :: map()
  def create_subscription(customer_id, price_id, params \\ %{}) do
    params = normalize_params(params)

    params =
      params
      |> Map.put(:customer, customer_id)
      |> Map.put_new(:items, [%{price: price_id}])

    post("/v1/subscriptions", params)
  end

  @doc """
  Creates an invoice for a customer.

  ## Parameters

  - `customer_id` - The customer ID (required)
  - `params` - Optional keyword list or map with:
    - `:description` - Invoice description
    - `:metadata` - Metadata map
    - `:auto_advance` - Auto-finalize invoice (default: false)
    - `:collection_method` - "charge_automatically" or "send_invoice"
    - `:custom_fields` - Custom fields on invoice
    - `:days_until_due` - Days until payment due
    - `:default_payment_method` - Payment method ID
    - `:footer` - Invoice footer text
    - `:on_behalf_of` - Created on behalf of account

  ## Returns

  The created invoice object as a map.

  ## Examples

      iex> customer = PaperTiger.TestHelpers.create_customer(email: "test@example.com")
      iex> invoice = PaperTiger.TestHelpers.create_invoice(customer["id"])
      iex> invoice["customer"]
      customer["id"]
      iex> invoice["object"]
      "invoice"
  """
  @spec create_invoice(String.t(), map() | keyword()) :: map()
  def create_invoice(customer_id, params \\ %{}) do
    params = normalize_params(params)
    params = Map.put(params, :customer, customer_id)

    post("/v1/invoices", params)
  end

  # ============================================================================
  # Assertion Helpers
  # ============================================================================

  @doc """
  Asserts that a response is a valid Stripe object of the expected type.

  ## Parameters

  - `object` - The object to validate (should be a map)
  - `expected_type` - The expected object type string (e.g., "customer", "invoice")

  ## Raises

  `AssertionError` if the object is not valid or type doesn't match.

  ## Examples

      iex> customer = PaperTiger.TestHelpers.create_customer()
      iex> PaperTiger.TestHelpers.assert_stripe_object(customer, "customer")
      # Passes

      iex> PaperTiger.TestHelpers.assert_stripe_object(customer, "invoice")
      # Raises AssertionError
  """
  @spec assert_stripe_object(map(), String.t()) :: :ok | no_return()
  def assert_stripe_object(object, expected_type) when is_map(object) and is_binary(expected_type) do
    assert is_map(object), "Expected object to be a map, got: #{inspect(object)}"

    assert Map.has_key?(object, "object"),
           "Expected object to have 'object' field, got: #{inspect(object)}"

    assert object["object"] == expected_type,
           "Expected object type #{expected_type}, got: #{object["object"]}"

    assert Map.has_key?(object, "id"),
           "Expected object to have 'id' field, got: #{inspect(object)}"

    :ok
  end

  @doc """
  Asserts that a response is a valid Stripe list response.

  List responses have the structure:
  ```
  %{
    "object" => "list",
    "data" => [...],
    "has_more" => true|false,
    "url" => "..."
  }
  ```

  ## Parameters

  - `response` - The response to validate

  ## Raises

  `AssertionError` if the response is not a valid list structure.

  ## Examples

      iex> response = PaperTiger.TestHelpers.get("/v1/customers")
      iex> PaperTiger.TestHelpers.assert_list_response(response)
      # Passes

      iex> PaperTiger.TestHelpers.assert_list_response(%{})
      # Raises AssertionError
  """
  @spec assert_list_response(map()) :: :ok | no_return()
  def assert_list_response(response) when is_map(response) do
    assert response["object"] == "list",
           "Expected list object, got: #{inspect(response)}"

    assert is_list(response["data"]),
           "Expected 'data' to be a list, got: #{inspect(response["data"])}"

    assert is_boolean(response["has_more"]),
           "Expected 'has_more' to be a boolean, got: #{inspect(response["has_more"])}"

    :ok
  end

  @doc """
  Asserts that a response is a valid Stripe error response.

  Error responses have the structure:
  ```
  %{
    "error" => %{
      "type" => "...",
      "message" => "...",
      ...
    }
  }
  ```

  ## Parameters

  - `response` - The response to validate
  - `expected_type` - The expected error type (e.g., "invalid_request_error", "card_error")

  ## Raises

  `AssertionError` if the response is not a valid error structure or type doesn't match.

  ## Examples

      iex> response = PaperTiger.TestHelpers.get("/v1/customers/cus_invalid")
      iex> PaperTiger.TestHelpers.assert_error_response(response, "invalid_request_error")
      # Passes if it's a 404 error

      iex> PaperTiger.TestHelpers.assert_error_response(response, "card_error")
      # Raises AssertionError if type doesn't match
  """
  @spec assert_error_response(map(), String.t()) :: :ok | no_return()
  def assert_error_response(response, expected_type) when is_map(response) and is_binary(expected_type) do
    assert Map.has_key?(response, "error"),
           "Expected response to have 'error' field, got: #{inspect(response)}"

    error = response["error"]

    assert is_map(error),
           "Expected 'error' to be a map, got: #{inspect(error)}"

    assert Map.has_key?(error, "type"),
           "Expected error to have 'type' field, got: #{inspect(error)}"

    assert error["type"] == expected_type,
           "Expected error type #{expected_type}, got: #{error["type"]}"

    assert Map.has_key?(error, "message"),
           "Expected error to have 'message' field, got: #{inspect(error)}"

    :ok
  end

  # ============================================================================
  # Time Helpers
  # ============================================================================

  @doc """
  Advances time by the given amount.

  Only effective in `:manual` or `:accelerated` time modes.

  ## Parameters

  Can pass either:
  - A single integer representing seconds to advance
  - A keyword list with time units:
    - `:seconds` - Number of seconds
    - `:minutes` - Number of minutes
    - `:hours` - Number of hours
    - `:days` - Number of days

  ## Examples

      iex> PaperTiger.TestHelpers.advance_time(86400)
      :ok

      iex> PaperTiger.TestHelpers.advance_time(days: 30)
      :ok

      iex> PaperTiger.TestHelpers.advance_time(days: 1, hours: 2, minutes: 30)
      :ok
  """
  @spec advance_time(integer() | keyword()) :: :ok
  def advance_time(amount) do
    PaperTiger.Clock.advance(amount)
  end

  @doc """
  Resets time to the current system time.

  Useful for cleaning up between tests. Clears any accumulated time offsets
  and resets to real time.

  ## Examples

      iex> PaperTiger.TestHelpers.reset_time()
      :ok
  """
  @spec reset_time() :: :ok
  def reset_time do
    PaperTiger.Clock.reset()
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp build_conn(method, path, body, headers) do
    conn = Plug.Test.conn(method, path, body)

    Enum.reduce(headers, conn, fn {key, value}, acc ->
      Plug.Conn.put_req_header(acc, to_string(key), to_string(value))
    end)
  end

  defp call_router(conn) do
    PaperTiger.Router.call(conn, PaperTiger.Router.init([]))
  end

  defp decode_response(conn) do
    body =
      conn.resp_body
      |> Jason.decode!()

    body
  end

  defp encode_body(params, "application/json") do
    Jason.encode!(params)
  end

  defp encode_body(params, "application/x-www-form-urlencoded") do
    params
    |> flatten_params()
    |> URI.encode_query()
  end

  defp encode_body(params, _default) do
    params
    |> flatten_params()
    |> URI.encode_query()
  end

  defp flatten_params(params) do
    Enum.reduce(params, [], fn {key, value}, acc ->
      acc ++ flatten_value(key, value)
    end)
    |> Map.new()
  end

  defp flatten_value(key, value) when is_list(value) do
    Enum.with_index(value, fn item, index ->
      {"#{key}[#{index}]", to_form_value(item)}
    end)
  end

  defp flatten_value(key, value) when is_map(value) do
    Enum.reduce(value, [], fn {k, v}, acc ->
      acc ++ flatten_value("#{key}[#{k}]", v)
    end)
  end

  defp flatten_value(key, value) do
    [{key, to_form_value(value)}]
  end

  defp to_form_value(value) when is_binary(value), do: value
  defp to_form_value(value) when is_integer(value), do: Integer.to_string(value)
  defp to_form_value(value) when is_float(value), do: Float.to_string(value)
  defp to_form_value(true), do: "true"
  defp to_form_value(false), do: "false"
  defp to_form_value(nil), do: ""
  defp to_form_value(value), do: inspect(value)

  defp encode_query_params(params) when is_map(params) and map_size(params) == 0, do: ""

  defp encode_query_params(params) when is_map(params) do
    params
    |> flatten_params()
    |> URI.encode_query()
  end

  defp normalize_params(params) when is_list(params) do
    params
    |> Map.new()
    |> normalize_keys()
  end

  defp normalize_params(params) when is_map(params) do
    normalize_keys(params)
  end

  defp normalize_params(params), do: params

  defp normalize_keys(params) do
    Enum.reduce(params, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, Atom.to_string(key), value)

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end
end
