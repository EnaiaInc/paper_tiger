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

  @doc """
  Returns the current test mode.

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
      :real_stripe
    else
      :paper_tiger
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

  ## Private - Real Stripe API

  defp create_customer_real(params) do
    case Stripe.Customer.create(normalize_params(params)) do
      {:ok, customer} -> {:ok, stripe_to_map(customer)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp get_customer_real(customer_id) do
    case Stripe.Customer.retrieve(customer_id) do
      {:ok, customer} -> {:ok, stripe_to_map(customer)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp update_customer_real(customer_id, params) do
    case Stripe.Customer.update(customer_id, normalize_params(params)) do
      {:ok, customer} -> {:ok, stripe_to_map(customer)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp delete_customer_real(customer_id) do
    case Stripe.Customer.delete(customer_id) do
      {:ok, result} -> {:ok, stripe_to_map(result)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp list_customers_real(params) do
    case Stripe.Customer.list(normalize_params(params)) do
      {:ok, %{data: customers, has_more: has_more}} ->
        {:ok, %{"data" => Enum.map(customers, &stripe_to_map/1), "has_more" => has_more}}

      {:error, error} ->
        {:error, stripe_error_to_map(error)}
    end
  end

  defp create_subscription_real(params) do
    case Stripe.Subscription.create(normalize_params(params)) do
      {:ok, subscription} -> {:ok, stripe_to_map(subscription)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp get_subscription_real(subscription_id) do
    case Stripe.Subscription.retrieve(subscription_id) do
      {:ok, subscription} -> {:ok, stripe_to_map(subscription)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp update_subscription_real(subscription_id, params) do
    case Stripe.Subscription.update(subscription_id, normalize_params(params)) do
      {:ok, subscription} -> {:ok, stripe_to_map(subscription)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp delete_subscription_real(subscription_id) do
    case Stripe.Subscription.cancel(subscription_id) do
      {:ok, result} -> {:ok, stripe_to_map(result)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp list_subscriptions_real(params) do
    case Stripe.Subscription.list(normalize_params(params)) do
      {:ok, %{data: subscriptions, has_more: has_more}} ->
        {:ok, %{"data" => Enum.map(subscriptions, &stripe_to_map/1), "has_more" => has_more}}

      {:error, error} ->
        {:error, stripe_error_to_map(error)}
    end
  end

  defp create_payment_method_real(params) do
    case Stripe.PaymentMethod.create(normalize_params(params)) do
      {:ok, payment_method} -> {:ok, stripe_to_map(payment_method)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp get_payment_method_real(payment_method_id) do
    case Stripe.PaymentMethod.retrieve(payment_method_id) do
      {:ok, payment_method} -> {:ok, stripe_to_map(payment_method)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp create_invoice_real(params) do
    case Stripe.Invoice.create(normalize_params(params)) do
      {:ok, invoice} -> {:ok, stripe_to_map(invoice)}
      {:error, error} -> {:error, stripe_error_to_map(error)}
    end
  end

  defp get_invoice_real(invoice_id) do
    case Stripe.Invoice.retrieve(invoice_id) do
      {:ok, invoice} -> {:ok, stripe_to_map(invoice)}
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
  defp stripe_to_map(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.new(fn {k, v} -> {to_string(k), normalize_value(v)} end)
  end

  defp stripe_to_map(map) when is_map(map), do: map
  defp stripe_to_map(other), do: other

  defp normalize_value(%_{} = struct), do: stripe_to_map(struct)
  defp normalize_value(list) when is_list(list), do: Enum.map(list, &normalize_value/1)
  defp normalize_value(map) when is_map(map), do: stripe_to_map(map)
  defp normalize_value(other), do: other

  defp stripe_error_to_map(%Stripe.Error{} = error) do
    %{
      "error" => %{
        "code" => error.code,
        "message" => error.message,
        "type" => error.code
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
