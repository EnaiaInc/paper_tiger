defmodule PaperTiger.Resources.Plan do
  @moduledoc """
  Handles Plan resource endpoints.

  ## Endpoints

  - POST   /v1/plans      - Create plan
  - GET    /v1/plans/:id  - Retrieve plan
  - POST   /v1/plans/:id  - Update plan
  - DELETE /v1/plans/:id  - Delete plan
  - GET    /v1/plans      - List plans

  ## Plan Object

  Note: Plans are DEPRECATED in favor of Prices but still supported.

      %{
        id: "plan_...",
        object: "plan",
        created: 1234567890,
        active: true,
        amount: 2000,  # in cents
        currency: "usd",
        interval: "month",
        interval_count: 1,
        product: "prod_...",
        nickname: "Premium Plan",
        metadata: %{},
        # ... other fields
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Plans

  @doc """
  Creates a new plan.

  ## Required Parameters

  - currency - Three-letter ISO currency code (e.g., "usd")
  - interval - Billing interval ("day", "week", "month", or "year")
  - amount - Price in cents (e.g., 2000 for $20.00)

  ## Optional Parameters

  - id - Custom plan ID (if not provided, auto-generated as "plan_...")
  - active - Whether plan is active (default: true)
  - interval_count - Number of intervals between billings (default: 1)
  - product - Product ID this plan belongs to
  - nickname - Plan nickname
  - metadata - Key-value metadata
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:currency, :interval, :amount]),
         plan = build_plan(conn.params),
         {:ok, plan} <- Plans.insert(plan) do
      maybe_store_idempotency(conn, plan)

      plan
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
  Retrieves a plan by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case Plans.get(id) do
      {:ok, plan} ->
        plan
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("plan", id))
    end
  end

  @doc """
  Updates a plan.

  Note: Plans have limited fields that can be updated.

  ## Updatable Fields

  - active
  - metadata
  - nickname
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- Plans.get(id),
         updated =
           merge_updates(existing, conn.params, [
             :id,
             :object,
             :created,
             :currency,
             :amount,
             :interval,
             :interval_count,
             :product
           ]),
         {:ok, updated} <- Plans.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("plan", id))
    end
  end

  @doc """
  Deletes a plan.

  Returns a deletion confirmation object.
  """
  @spec delete(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def delete(conn, id) do
    case Plans.get(id) do
      {:ok, _plan} ->
        :ok = Plans.delete(id)

        json_response(conn, 200, %{
          deleted: true,
          id: id,
          object: "plan"
        })

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("plan", id))
    end
  end

  @doc """
  Lists all plans with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  - active - Filter by active status
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result = Plans.list(pagination_opts)

    json_response(conn, 200, result)
  end

  ## Private Functions

  defp build_plan(params) do
    %{
      id: Map.get(params, :id) || generate_id("plan"),
      object: "plan",
      created: PaperTiger.now(),
      active: Map.get(params, :active, true),
      amount: get_integer(params, :amount),
      currency: Map.get(params, :currency),
      interval: Map.get(params, :interval),
      interval_count: get_integer(params, :interval_count, 1),
      product: Map.get(params, :product),
      nickname: Map.get(params, :nickname),
      metadata: Map.get(params, :metadata, %{}),
      # Additional fields
      livemode: false,
      usage_type: Map.get(params, :usage_type, "licensed"),
      trial_period_days: get_integer(params, :trial_period_days),
      aggregate_usage: Map.get(params, :aggregate_usage),
      billing_scheme: Map.get(params, :billing_scheme, "per_unit"),
      tiers: Map.get(params, :tiers),
      tiers_mode: Map.get(params, :tiers_mode),
      transform_usage: Map.get(params, :transform_usage)
    }
  end

  defp maybe_expand(plan, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(plan, expand_params)
  end
end
