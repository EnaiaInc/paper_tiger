defmodule PaperTiger.Resources.TaxRate do
  @moduledoc """
  Handles TaxRate resource endpoints.

  ## Endpoints

  - POST   /v1/tax_rates      - Create tax rate
  - GET    /v1/tax_rates/:id  - Retrieve tax rate
  - POST   /v1/tax_rates/:id  - Update tax rate
  - GET    /v1/tax_rates      - List tax rates

  Note: Tax rates cannot be deleted (audit purposes).

  ## TaxRate Object

      %{
        id: "txr_...",
        object: "tax_rate",
        created: 1234567890,
        active: true,
        display_name: "VAT",
        inclusive: false,
        jurisdiction: "EU",
        percentage: 20.0,
        metadata: %{},
        # ... other fields
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.TaxRates

  require Logger

  @doc """
  Creates a new tax rate.

  ## Required Parameters

  - display_name - Tax rate display name (e.g., "VAT")
  - percentage - Tax percentage as decimal (e.g., 20.0 for 20%)
  - inclusive - Whether tax is included in price (boolean)

  ## Optional Parameters

  - active - Whether tax rate is active (default: true)
  - jurisdiction - Geographic jurisdiction (e.g., "EU", "US-CA")
  - metadata - Key-value metadata
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:display_name, :percentage, :inclusive]),
         tax_rate = build_tax_rate(conn.params),
         {:ok, tax_rate} <- TaxRates.insert(tax_rate) do
      maybe_store_idempotency(conn, tax_rate)

      tax_rate
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
  Retrieves a tax rate by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case TaxRates.get(id) do
      {:ok, tax_rate} ->
        tax_rate
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("tax_rate", id))
    end
  end

  @doc """
  Updates a tax rate.

  Note: Tax rates can only have limited fields updated.

  ## Updatable Fields

  - active
  - metadata
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- TaxRates.get(id),
         updated =
           merge_updates(existing, conn.params, [
             :id,
             :object,
             :created,
             :display_name,
             :percentage,
             :inclusive,
             :jurisdiction
           ]),
         {:ok, updated} <- TaxRates.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("tax_rate", id))
    end
  end

  @doc """
  Lists all tax rates with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  - active - Filter by active status
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result = TaxRates.list(pagination_opts)

    json_response(conn, 200, result)
  end

  ## Private Functions

  defp build_tax_rate(params) do
    %{
      id: generate_id("txr"),
      object: "tax_rate",
      created: PaperTiger.now(),
      active: Map.get(params, :active, true),
      display_name: Map.get(params, :display_name),
      percentage: Map.get(params, :percentage),
      inclusive: Map.get(params, :inclusive),
      jurisdiction: Map.get(params, :jurisdiction),
      metadata: Map.get(params, :metadata, %{}),
      # Additional fields
      livemode: false,
      country: Map.get(params, :country),
      state: Map.get(params, :state),
      tax_type: Map.get(params, :tax_type),
      description: Map.get(params, :description)
    }
  end

  defp maybe_expand(tax_rate, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(tax_rate, expand_params)
  end
end
