defmodule PaperTiger.Resources.PromotionCode do
  @moduledoc """
  Handles Promotion Code resource endpoints.
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Coupons
  alias PaperTiger.Store.PromotionCodes

  @doc """
  Creates a Promotion Code.
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:promotion]),
         {:ok, coupon_id} <- validate_promotion(conn.params.promotion),
         {:ok, coupon} <- Coupons.get(coupon_id),
         promotion_code = build_promotion_code(conn.params, coupon),
         {:ok, promotion_code} <- PromotionCodes.insert(promotion_code) do
      maybe_store_idempotency(conn, promotion_code)

      promotion_code
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :invalid_params, field} ->
        error_response(conn, PaperTiger.Error.invalid_request("Missing required parameter", field))

      {:error, :invalid_promotion} ->
        error_response(conn, PaperTiger.Error.invalid_request("Invalid promotion", "promotion"))

      {:error, :not_found} ->
        coupon_id = conn.params |> Map.get(:promotion, %{}) |> param(:coupon)
        error_response(conn, PaperTiger.Error.not_found("coupon", coupon_id || ""))
    end
  end

  @doc """
  Retrieves a Promotion Code.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case PromotionCodes.get(id) do
      {:ok, promotion_code} ->
        promotion_code
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("promotion_code", id))
    end
  end

  @doc """
  Updates a Promotion Code.
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- PromotionCodes.get(id),
         updated = update_promotion_code(existing, conn.params),
         {:ok, updated} <- PromotionCodes.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("promotion_code", id))
    end
  end

  @doc """
  Lists Promotion Codes.
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result =
      case param(conn.params, :code) do
        code when is_binary(code) and code != "" ->
          PromotionCodes.find_active_by_code(code)
          |> PaperTiger.List.paginate(Map.put(pagination_opts, :url, "/v1/promotion_codes"))

        _ ->
          PromotionCodes.list(pagination_opts)
      end

    json_response(conn, 200, result)
  end

  defp validate_promotion(%{} = promotion) do
    if param(promotion, :type) == "coupon" and param(promotion, :coupon) not in [nil, ""] do
      {:ok, param(promotion, :coupon)}
    else
      {:error, :invalid_promotion}
    end
  end

  defp validate_promotion(_promotion), do: {:error, :invalid_promotion}

  defp build_promotion_code(params, coupon) do
    now = PaperTiger.now()

    %{
      active: boolean_param(params, :active, true),
      code: param(params, :code) || generated_code(),
      coupon: coupon,
      created: now,
      customer: param(params, :customer),
      expires_at: get_optional_integer(params, :expires_at),
      id: generate_id("promo", param(params, :id)),
      livemode: false,
      max_redemptions: get_optional_integer(params, :max_redemptions),
      metadata: param(params, :metadata) || %{},
      object: "promotion_code",
      promotion: %{coupon: coupon.id, type: "coupon"},
      restrictions: param(params, :restrictions) || default_restrictions(),
      times_redeemed: 0
    }
  end

  defp update_promotion_code(promotion_code, params) do
    params =
      if Map.has_key?(params, :active) do
        Map.put(params, :active, to_boolean(params.active))
      else
        params
      end

    apply_updates(params, promotion_code)
  end

  defp apply_updates(params, promotion_code) do
    merge_updates(promotion_code, params, [
      :code,
      :coupon,
      :created,
      :customer,
      :id,
      :livemode,
      :object,
      :promotion,
      :times_redeemed
    ])
  end

  defp default_restrictions do
    %{
      first_time_transaction: false,
      minimum_amount: nil,
      minimum_amount_currency: nil
    }
  end

  defp maybe_expand(promotion_code, params) do
    params
    |> parse_expand_params()
    |> then(&PaperTiger.Hydrator.hydrate(promotion_code, &1))
  end

  defp generated_code do
    :crypto.strong_rand_bytes(6)
    |> Base.encode16(case: :upper)
    |> binary_part(0, 10)
  end

  defp boolean_param(params, key, default) do
    if Map.has_key?(params, key) do
      to_boolean(Map.get(params, key))
    else
      default
    end
  end

  defp param(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp param(_map, _key), do: nil
end
