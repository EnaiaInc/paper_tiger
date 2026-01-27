defmodule PaperTiger.Resources.Price do
  @moduledoc """
  Handles Price resource endpoints.

  ## Endpoints

  - POST   /v1/prices      - Create price
  - GET    /v1/prices/:id  - Retrieve price
  - POST   /v1/prices/:id  - Update price
  - GET    /v1/prices      - List prices

  Note: Prices cannot be deleted (Stripe API limitation).

  ## Price Object

      %{
        id: "price_...",
        object: "price",
        created: 1234567890,
        active: true,
        currency: "usd",
        unit_amount: 2000,  # $20.00
        recurring: %{
          interval: "month",
          interval_count: 1
        },
        product: "prod_...",
        # ... other fields
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Plans
  alias PaperTiger.Store.Prices


  @doc """
  Creates a new price.

  ## Required Parameters

  - currency - Three-letter ISO currency code (e.g., "usd")
  - product - Product ID this price belongs to

  One of:
  - unit_amount - Price in cents (e.g., 2000 for $20.00)
  - unit_amount_decimal - Price as decimal string

  ## Optional Parameters

  - id - Custom ID (must start with "price_"). Useful for seeding deterministic data.
  - active - Whether price is active (default: true)
  - metadata - Key-value metadata
  - recurring - Recurring billing config (interval, interval_count)
  - billing_scheme - Pricing model (per_unit, tiered)
  - tiers - Tiered pricing configuration
  - tiers_mode - Tiering mode (graduated, volume)
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:currency, :product]),
         price = build_price(conn.params),
         {:ok, price} <- Prices.insert(price) do
      maybe_store_idempotency(conn, price)

      # Stripe auto-creates a Plan for recurring prices (legacy compatibility)
      # The Plan ID matches the Price ID
      maybe_create_plan_for_recurring_price(price)

      :telemetry.execute([:paper_tiger, :price, :created], %{}, %{object: price})

      price
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
  Retrieves a price by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case Prices.get(id) do
      {:ok, price} ->
        price
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("price", id))
    end
  end

  @doc """
  Updates a price.

  Note: Prices can only have limited fields updated.

  ## Updatable Fields

  - active
  - metadata
  - nickname
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- Prices.get(id),
         updated =
           merge_updates(existing, conn.params, [
             :id,
             :object,
             :created,
             :currency,
             :product,
             :unit_amount,
             :recurring
           ]),
         {:ok, updated} <- Prices.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("price", id))
    end
  end

  @doc """
  Lists all prices with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  - active - Filter by active status
  - currency - Filter by currency
  - product - Filter by product
  - recurring - Filter recurring/one-time prices
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result = Prices.list(pagination_opts)

    json_response(conn, 200, result)
  end

  ## Private Functions

  defp build_price(params) do
    unit_amount =
      case Map.get(params, :unit_amount) do
        nil -> nil
        value -> to_integer(value)
      end

    recurring = build_recurring(Map.get(params, :recurring))

    %{
      id: generate_id("price", Map.get(params, :id)),
      object: "price",
      created: PaperTiger.now(),
      active: Map.get(params, :active, true),
      currency: Map.get(params, :currency),
      unit_amount: unit_amount,
      unit_amount_decimal: Map.get(params, :unit_amount_decimal),
      product: Map.get(params, :product),
      metadata: Map.get(params, :metadata, %{}),
      recurring: recurring,
      # Additional fields
      livemode: false,
      type: if(Map.get(params, :recurring), do: "recurring", else: "one_time"),
      billing_scheme: Map.get(params, :billing_scheme, "per_unit"),
      tiers: Map.get(params, :tiers),
      tiers_mode: Map.get(params, :tiers_mode),
      nickname: Map.get(params, :nickname),
      lookup_key: Map.get(params, :lookup_key),
      tax_behavior: Map.get(params, :tax_behavior, "unspecified"),
      transform_quantity: Map.get(params, :transform_quantity)
    }
  end

  defp maybe_expand(price, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(price, expand_params)
  end

  # Build recurring structure with defaults (matching Stripe API behavior)
  defp build_recurring(nil), do: nil

  defp build_recurring(%{} = recurring) do
    interval = Map.get(recurring, :interval) || Map.get(recurring, "interval")
    interval_count = Map.get(recurring, :interval_count) || Map.get(recurring, "interval_count")

    recurring_map = %{interval: interval}

    # Only include interval_count if provided (it's optional per Stripe spec)
    if interval_count do
      Map.put(recurring_map, :interval_count, interval_count)
    else
      recurring_map
    end
  end

  # Stripe automatically creates a Plan object for recurring prices (legacy API compatibility).
  # The Plan ID matches the Price ID. This enables code using the legacy Plans API to work
  # with prices created via the newer Prices API.
  defp maybe_create_plan_for_recurring_price(%{recurring: nil}), do: :ok

  defp maybe_create_plan_for_recurring_price(%{recurring: recurring} = price) when is_map(recurring) do
    plan = %{
      active: price.active,
      amount: price.unit_amount,
      amount_decimal: price.unit_amount_decimal,
      billing_scheme: price.billing_scheme || "per_unit",
      created: price.created,
      currency: price.currency,
      id: price.id,
      interval: Map.get(recurring, :interval),
      interval_count: Map.get(recurring, :interval_count) || 1,
      livemode: false,
      metadata: price.metadata || %{},
      nickname: price.nickname,
      object: "plan",
      product: price.product,
      usage_type: "licensed"
    }

    Plans.insert(plan)
    :ok
  end
end
