defmodule PaperTiger.Discounts do
  @moduledoc false

  import PaperTiger.Resource, only: [generate_id: 1, to_integer: 1]

  alias PaperTiger.Store.Coupons
  alias PaperTiger.Store.PromotionCodes

  @doc """
  Builds a Stripe-shaped discount from coupon/promotion_code params.
  """
  @spec build_from_params(map()) :: map() | nil
  def build_from_params(params) when is_map(params) do
    params
    |> discount_params()
    |> build_discount()
  end

  @doc """
  Calculates the discount amount for a subtotal/currency.
  """
  @spec amount(map() | nil, non_neg_integer(), String.t()) :: non_neg_integer()
  def amount(nil, _subtotal, _currency), do: 0

  def amount(%{coupon: coupon}, subtotal, currency) when is_map(coupon) do
    cond do
      percent = value(coupon, :percent_off) ->
        min(subtotal, round(subtotal * to_integer(percent) / 100))

      amount_off = value(coupon, :amount_off) ->
        if value(coupon, :currency) in [nil, currency] do
          min(subtotal, to_integer(amount_off))
        else
          0
        end

      true ->
        0
    end
  end

  def amount(_discount, _subtotal, _currency), do: 0

  @doc false
  @spec value(term(), atom()) :: term()
  def value(nil, _key), do: nil

  def value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  def value(_other, _key), do: nil

  defp discount_params(params) do
    cond do
      value(params, :promotion_code) not in [nil, ""] ->
        %{promotion_code: value(params, :promotion_code)}

      value(params, :coupon) not in [nil, ""] ->
        %{coupon: value(params, :coupon)}

      true ->
        first_discount(value(params, :discounts))
    end
  end

  defp first_discount(nil), do: nil
  defp first_discount([discount | _rest]) when is_map(discount), do: discount

  defp first_discount(discounts) when is_map(discounts) do
    discounts
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {_key, value} -> value end)
    |> Enum.find(&is_map/1)
  end

  defp first_discount(_discounts), do: nil

  defp build_discount(%{promotion_code: promotion_code_id}) do
    case PromotionCodes.get(to_string(promotion_code_id)) do
      {:ok, promotion_code} ->
        coupon_id = promotion_code |> value(:promotion) |> value(:coupon)
        coupon = fetch_coupon(coupon_id)

        if coupon do
          %{
            coupon: coupon,
            id: generate_id("di"),
            object: "discount",
            promotion_code: promotion_code.id,
            start: PaperTiger.now()
          }
        end

      {:error, :not_found} ->
        nil
    end
  end

  defp build_discount(%{coupon: coupon_id}) do
    case fetch_coupon(coupon_id) do
      nil ->
        nil

      coupon ->
        %{
          coupon: coupon,
          id: generate_id("di"),
          object: "discount",
          promotion_code: nil,
          start: PaperTiger.now()
        }
    end
  end

  defp build_discount(_discount), do: nil

  defp fetch_coupon(coupon_id) when is_binary(coupon_id) do
    case Coupons.get(coupon_id) do
      {:ok, coupon} -> coupon
      {:error, :not_found} -> nil
    end
  end

  defp fetch_coupon(_coupon_id), do: nil
end
