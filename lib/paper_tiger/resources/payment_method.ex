defmodule PaperTiger.Resources.PaymentMethod do
  @moduledoc """
  Handles PaymentMethod resource endpoints.

  ## Endpoints

  - POST   /v1/payment_methods      - Create payment method
  - GET    /v1/payment_methods/:id  - Retrieve payment method
  - POST   /v1/payment_methods/:id  - Update payment method
  - DELETE /v1/payment_methods/:id  - Delete payment method
  - GET    /v1/payment_methods      - List payment methods

  ## PaymentMethod Object

      %{
        id: "pm_...",
        object: "payment_method",
        created: 1234567890,
        type: "card",
        customer: "cus_...",
        metadata: %{},
        card: %{
          brand: "visa",
          last4: "4242",
          exp_month: 12,
          exp_year: 2025
        },
        billing_details: %{
          name: "John Doe",
          email: "john@example.com",
          phone: "+1234567890",
          address: %{
            country: "US",
            postal_code: "12345",
            state: "CA",
            city: "San Francisco",
            line1: "123 Main St",
            line2: nil
          }
        }
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.PaymentMethods

  require Logger

  @doc """
  Creates a new payment method.

  ## Required Parameters

  - type - Payment method type ("card", "us_bank_account", etc.)

  ## Optional Parameters

  - id - Custom ID (must start with "pm_"). Useful for seeding deterministic data.
  - customer - Customer ID to associate with
  - metadata - Key-value metadata
  - card - Card details (when type=card)
  - billing_details - Billing address and contact info
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:type]),
         payment_method = build_payment_method(conn.params),
         {:ok, payment_method} <- PaymentMethods.insert(payment_method) do
      maybe_store_idempotency(conn, payment_method)

      payment_method
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :invalid_params, field} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("Missing required parameter", field)
        )
    end
  end

  @doc """
  Retrieves a payment method by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case PaymentMethods.get(id) do
      {:ok, payment_method} ->
        payment_method
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("payment_method", id))
    end
  end

  @doc """
  Updates a payment method.

  Note: PaymentMethods can only have limited fields updated.

  ## Updatable Fields

  - metadata
  - billing_details
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- PaymentMethods.get(id),
         updated =
           merge_updates(existing, conn.params, [
             :id,
             :object,
             :created,
             :type,
             :customer,
             :card
           ]),
         {:ok, updated} <- PaymentMethods.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("payment_method", id))
    end
  end

  @doc """
  Deletes a payment method.

  Returns a deletion confirmation object.
  """
  @spec delete(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def delete(conn, id) do
    case PaymentMethods.get(id) do
      {:ok, _payment_method} ->
        :ok = PaymentMethods.delete(id)

        json_response(conn, 200, %{
          deleted: true,
          id: id,
          object: "payment_method"
        })

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("payment_method", id))
    end
  end

  @doc """
  Lists payment methods for a customer.

  Stripe API requires customer parameter for listing payment methods.

  ## Required Parameters

  - customer - Customer ID (required)

  ## Optional Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  - type - Filter by payment method type
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)
    customer_id = get_string_param(conn.params, :customer)

    payment_methods = PaymentMethods.find_by_customer(customer_id)
    result = PaperTiger.List.paginate(payment_methods, Map.put(pagination_opts, :url, "/v1/payment_methods"))

    json_response(conn, 200, result)
  end

  defp get_string_param(params, key) do
    case Map.get(params, key) do
      nil -> nil
      val when is_binary(val) -> val
      val when is_atom(val) -> Atom.to_string(val)
    end
  end

  @doc """
  Attaches a payment method to a customer.

  POST /v1/payment_methods/:id/attach

  Associates a payment method with a customer ID.
  """
  @spec attach(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def attach(conn, id) do
    with {:ok, payment_method} <- PaymentMethods.get(id),
         {:ok, customer_id} <- validate_customer_param(conn.params),
         attached = attach_to_customer(payment_method, customer_id),
         {:ok, attached} <- PaymentMethods.update(attached) do
      attached
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("payment_method", id))

      {:error, :invalid_params} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("Missing required parameter", "customer")
        )
    end
  end

  @doc """
  Detaches a payment method from a customer.

  POST /v1/payment_methods/:id/detach

  Removes the association between a payment method and a customer.
  """
  @spec detach(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def detach(conn, id) do
    with {:ok, payment_method} <- PaymentMethods.get(id),
         detached = detach_from_customer(payment_method),
         {:ok, detached} <- PaymentMethods.update(detached) do
      detached
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("payment_method", id))
    end
  end

  ## Private Functions

  defp build_payment_method(params) do
    %{
      id: generate_id("pm", Map.get(params, :id)),
      object: "payment_method",
      created: PaperTiger.now(),
      type: Map.get(params, :type),
      customer: Map.get(params, :customer),
      metadata: Map.get(params, :metadata, %{}),
      card: Map.get(params, :card),
      billing_details: Map.get(params, :billing_details),
      # Additional fields
      livemode: false
    }
  end

  defp validate_customer_param(params) do
    case Map.get(params, :customer) do
      nil -> {:error, :invalid_params}
      "" -> {:error, :invalid_params}
      customer_id -> {:ok, customer_id}
    end
  end

  defp attach_to_customer(payment_method, customer_id) do
    %{payment_method | customer: customer_id}
  end

  defp detach_from_customer(payment_method) do
    %{payment_method | customer: nil}
  end

  defp maybe_expand(payment_method, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(payment_method, expand_params)
  end
end
