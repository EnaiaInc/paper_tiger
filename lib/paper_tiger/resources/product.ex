defmodule PaperTiger.Resources.Product do
  @moduledoc """
  Handles Product resource endpoints.

  ## Endpoints

  - POST   /v1/products      - Create product
  - GET    /v1/products/:id  - Retrieve product
  - POST   /v1/products/:id  - Update product
  - DELETE /v1/products/:id  - Delete product
  - GET    /v1/products      - List products

  ## Product Object

      %{
        id: "prod_...",
        object: "product",
        created: 1234567890,
        active: true,
        name: "Premium Plan",
        description: "A premium subscription plan",
        metadata: %{},
        # ... other fields
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Products

  require Logger

  @doc """
  Creates a new product.

  ## Required Parameters

  - name - Product name

  ## Optional Parameters

  - active - Whether product is active (default: true)
  - description - Product description
  - metadata - Key-value metadata
  - images - Product images URLs
  - statement_descriptor - Descriptor for bank statements
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:name]),
         product = build_product(conn.params),
         {:ok, product} <- Products.insert(product) do
      maybe_store_idempotency(conn, product)

      :telemetry.execute([:paper_tiger, :product, :created], %{}, %{object: product})

      product
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
  Retrieves a product by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case Products.get(id) do
      {:ok, product} ->
        product
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("product", id))
    end
  end

  @doc """
  Updates a product.

  ## Updatable Fields

  - active
  - name
  - description
  - metadata
  - images
  - statement_descriptor
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- Products.get(id),
         updated = merge_updates(existing, conn.params),
         {:ok, updated} <- Products.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("product", id))
    end
  end

  @doc """
  Deletes a product.

  Returns a deletion confirmation object.
  """
  @spec delete(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def delete(conn, id) do
    case Products.get(id) do
      {:ok, _product} ->
        :ok = Products.delete(id)

        json_response(conn, 200, %{
          deleted: true,
          id: id,
          object: "product"
        })

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("product", id))
    end
  end

  @doc """
  Lists all products with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  - active - Filter by active status
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result = Products.list(pagination_opts)

    json_response(conn, 200, result)
  end

  ## Private Functions

  defp build_product(params) do
    %{
      id: generate_id("prod"),
      object: "product",
      created: PaperTiger.now(),
      active: Map.get(params, :active, true),
      name: Map.get(params, :name),
      description: Map.get(params, :description),
      metadata: Map.get(params, :metadata, %{}),
      images: Map.get(params, :images, []),
      statement_descriptor: Map.get(params, :statement_descriptor),
      # Additional fields
      livemode: false,
      type: "service",
      unit_label: Map.get(params, :unit_label),
      updated: PaperTiger.now(),
      url: Map.get(params, :url),
      shippable: Map.get(params, :shippable),
      package_dimensions: Map.get(params, :package_dimensions),
      attributes: Map.get(params, :attributes, []),
      caption: Map.get(params, :caption)
    }
  end

  defp maybe_expand(product, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(product, expand_params)
  end
end
