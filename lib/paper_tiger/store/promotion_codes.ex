defmodule PaperTiger.Store.PromotionCodes do
  @moduledoc false

  use PaperTiger.Store,
    table: :paper_tiger_promotion_codes,
    resource: "promotion_code",
    prefix: "promo",
    plural: "promotion_codes",
    url_path: "/v1/promotion_codes"

  @doc """
  Finds active promotion codes by customer-facing code, case-insensitively.
  """
  @spec find_active_by_code(String.t()) :: [map()]
  def find_active_by_code(code) when is_binary(code) do
    namespace = PaperTiger.Test.current_namespace()
    normalized_code = String.downcase(code)

    @table
    |> :ets.match_object({{namespace, :_}, :_})
    |> Enum.map(fn {_key, promotion_code} -> promotion_code end)
    |> Enum.filter(fn promotion_code ->
      Map.get(promotion_code, :active) == true and
        promotion_code |> Map.get(:code, "") |> String.downcase() == normalized_code
    end)
  end
end
