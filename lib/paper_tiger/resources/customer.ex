defmodule PaperTiger.Resources.Customer do
  @moduledoc """
  Handles Customer resource endpoints.

  ## Endpoints

  - POST   /v1/customers      - Create customer
  - GET    /v1/customers/:id  - Retrieve customer
  - POST   /v1/customers/:id  - Update customer
  - DELETE /v1/customers/:id  - Delete customer
  - GET    /v1/customers      - List customers

  ## Customer Object

      %{
        id: "cus_...",
        object: "customer",
        created: 1234567890,
        email: "user@example.com",
        name: "John Doe",
        description: nil,
        metadata: %{},
        default_source: nil,
        default_payment_method: nil,
        # ... other fields
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Customers


  @doc """
  Creates a new customer.

  ## Required Parameters

  None (all optional for Customer creation)

  ## Optional Parameters

  - id - Custom ID (must start with "cus_"). Useful for seeding deterministic data.
  - email - Customer email
  - name - Customer name
  - description - Customer description
  - metadata - Key-value metadata
  - default_source - Default payment source
  - default_payment_method - Default payment method
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    customer = build_customer(conn.params)

    {:ok, customer} = Customers.insert(customer)
    maybe_store_idempotency(conn, customer)

    :telemetry.execute([:paper_tiger, :customer, :created], %{}, %{object: customer})

    customer
    |> maybe_expand(conn.params)
    |> then(&json_response(conn, 200, &1))
  end

  @doc """
  Retrieves a customer by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case Customers.get(id) do
      {:ok, customer} ->
        customer
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("customer", id))
    end
  end

  @doc """
  Updates a customer.

  ## Updatable Fields

  - email
  - name
  - description
  - metadata
  - default_source
  - default_payment_method
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- Customers.get(id),
         updated = merge_updates(existing, conn.params),
         {:ok, updated} <- Customers.update(updated) do
      :telemetry.execute([:paper_tiger, :customer, :updated], %{}, %{object: updated})

      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("customer", id))
    end
  end

  @doc """
  Deletes a customer.

  Returns a deletion confirmation object.
  """
  @spec delete(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def delete(conn, id) do
    case Customers.get(id) do
      {:ok, customer} ->
        :ok = Customers.delete(id)

        deleted_object = %{
          deleted: true,
          id: id,
          object: "customer"
        }

        :telemetry.execute([:paper_tiger, :customer, :deleted], %{}, %{object: customer})

        json_response(conn, 200, deleted_object)

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("customer", id))
    end
  end

  @doc """
  Lists all customers with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result = Customers.list(pagination_opts)

    json_response(conn, 200, result)
  end

  ## Private Functions

  defp build_customer(params) do
    # Use provided created timestamp or default to now
    created = get_optional_integer(params, :created) || PaperTiger.now()

    %{
      id: generate_id("cus", Map.get(params, :id)),
      object: "customer",
      created: created,
      email: Map.get(params, :email),
      name: Map.get(params, :name),
      description: Map.get(params, :description),
      metadata: Map.get(params, :metadata, %{}),
      default_source: Map.get(params, :default_source),
      default_payment_method: Map.get(params, :default_payment_method),
      # Additional fields
      balance: 0,
      currency: nil,
      delinquent: false,
      discount: nil,
      invoice_prefix: nil,
      invoice_settings: %{
        custom_fields: nil,
        default_payment_method: nil,
        footer: nil
      },
      livemode: false,
      phone: Map.get(params, :phone),
      preferred_locales: [],
      shipping: Map.get(params, :shipping),
      tax_exempt: "none",
      address: Map.get(params, :address)
    }
  end

  defp maybe_expand(customer, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(customer, expand_params)
  end
end
