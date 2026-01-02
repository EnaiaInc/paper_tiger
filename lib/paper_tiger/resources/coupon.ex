defmodule PaperTiger.Resources.Coupon do
  @moduledoc """
  Handles Coupon resource endpoints.

  ## Endpoints

  - POST   /v1/coupons      - Create coupon
  - GET    /v1/coupons/:id  - Retrieve coupon
  - POST   /v1/coupons/:id  - Update coupon
  - DELETE /v1/coupons/:id  - Delete coupon
  - GET    /v1/coupons      - List coupons

  ## Coupon Object

      %{
        id: "SUMMER20",
        object: "coupon",
        created: 1234567890,
        percent_off: 20,
        amount_off: nil,
        currency: nil,
        duration: "forever",
        duration_in_months: nil,
        metadata: %{},
        max_redemptions: nil,
        redeem_by: nil,
        # ... other fields
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Coupons

  require Logger

  @doc """
  Creates a new coupon.

  ## Required Parameters

  - id - Coupon code (e.g., "SUMMER20")
  - duration - "forever", "once", or "repeating"

  One of:
  - percent_off - Percentage discount (e.g., 20 for 20% off)
  - amount_off - Amount discount in cents (requires currency)

  ## Optional Parameters

  - currency - Three-letter ISO currency code (required if amount_off)
  - duration_in_months - Number of months (required if duration="repeating")
  - metadata - Key-value metadata
  - max_redemptions - Maximum number of times coupon can be redeemed
  - redeem_by - Unix timestamp after which coupon cannot be redeemed
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:id, :duration]),
         {:ok, _params} <- validate_discount(conn.params),
         {:ok, _params} <- validate_coupon_duration(conn.params),
         coupon = build_coupon(conn.params),
         {:ok, coupon} <- Coupons.insert(coupon) do
      maybe_store_idempotency(conn, coupon)

      coupon
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :invalid_params, field} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("Missing required parameter", field)
        )

      {:error, :invalid_discount} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("Must provide either percent_off or amount_off")
        )

      {:error, :invalid_amount_off} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("amount_off requires currency to be specified")
        )

      {:error, :invalid_duration} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("duration_in_months required for duration=repeating")
        )
    end
  end

  @doc """
  Retrieves a coupon by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case Coupons.get(id) do
      {:ok, coupon} ->
        coupon
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("coupon", id))
    end
  end

  @doc """
  Updates a coupon.

  Note: Coupons are mostly immutable. Only metadata can be updated.

  ## Updatable Fields

  - metadata
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- Coupons.get(id),
         updated =
           merge_updates(existing, conn.params, [
             :id,
             :object,
             :created,
             :percent_off,
             :amount_off,
             :currency,
             :duration,
             :duration_in_months,
             :max_redemptions,
             :redeem_by
           ]),
         {:ok, updated} <- Coupons.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("coupon", id))
    end
  end

  @doc """
  Deletes a coupon.

  Returns a deletion confirmation object.
  """
  @spec delete(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def delete(conn, id) do
    case Coupons.get(id) do
      {:ok, _coupon} ->
        :ok = Coupons.delete(id)

        json_response(conn, 200, %{
          deleted: true,
          id: id,
          object: "coupon"
        })

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("coupon", id))
    end
  end

  @doc """
  Lists all coupons with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result = Coupons.list(pagination_opts)

    json_response(conn, 200, result)
  end

  ## Private Functions

  defp build_coupon(params) do
    %{
      id: Map.get(params, :id),
      object: "coupon",
      created: PaperTiger.now(),
      percent_off: get_integer_or_nil(params, :percent_off),
      amount_off: get_integer_or_nil(params, :amount_off),
      currency: Map.get(params, :currency),
      duration: Map.get(params, :duration),
      duration_in_months: get_integer_or_nil(params, :duration_in_months),
      metadata: Map.get(params, :metadata, %{}),
      max_redemptions: get_integer_or_nil(params, :max_redemptions),
      redeem_by: get_integer_or_nil(params, :redeem_by),
      # Additional fields
      livemode: false,
      valid: true
    }
  end

  # Like get_integer but returns nil instead of 0 for missing values
  defp get_integer_or_nil(params, key) do
    case Map.get(params, key) do
      nil -> nil
      value -> to_integer(value)
    end
  end

  defp validate_discount(params) do
    percent_off = Map.get(params, :percent_off)
    amount_off = Map.get(params, :amount_off)

    cond do
      not is_nil(percent_off) ->
        {:ok, params}

      not is_nil(amount_off) ->
        if is_nil(Map.get(params, :currency)) do
          {:error, :invalid_amount_off}
        else
          {:ok, params}
        end

      true ->
        {:error, :invalid_discount}
    end
  end

  defp validate_coupon_duration(params) do
    duration = Map.get(params, :duration)

    if duration == "repeating" and is_nil(Map.get(params, :duration_in_months)) do
      {:error, :invalid_duration}
    else
      {:ok, params}
    end
  end

  defp maybe_expand(coupon, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(coupon, expand_params)
  end
end
