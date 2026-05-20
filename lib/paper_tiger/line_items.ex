defmodule PaperTiger.LineItems do
  @moduledoc false

  import PaperTiger.Resource, only: [generate_id: 1, get_integer: 3, to_integer: 1]

  alias PaperTiger.Store.Prices

  @known_keys [
    :amount,
    :amount_discount,
    :amount_subtotal,
    :amount_tax,
    :amount_total,
    :currency,
    :description,
    :id,
    :price,
    :price_data,
    :quantity,
    :session,
    :payment_link,
    :unit_amount,
    :unit_amount_excluding_tax
  ]

  @doc """
  Normalizes Stripe line item params into a stored list item shape.
  """
  @spec normalize([map()] | term(), atom(), String.t()) :: [map()]
  def normalize(line_items, owner_key, owner_id) when is_list(line_items) and is_atom(owner_key) do
    Enum.map(line_items, &normalize_item(&1, owner_key, owner_id))
  end

  def normalize(_line_items, _owner_key, _owner_id), do: []

  @doc """
  Moves already-normalized line items to another owning object.
  """
  @spec reassign([map()] | term(), atom(), String.t()) :: [map()]
  def reassign(line_items, owner_key, owner_id) when is_list(line_items) and is_atom(owner_key) do
    Enum.map(line_items, fn item ->
      item
      |> normalize_keys()
      |> Map.drop([:payment_link, :session])
      |> Map.put(owner_key, owner_id)
    end)
  end

  def reassign(_line_items, _owner_key, _owner_id), do: []

  @doc """
  Returns a Stripe list object for line item collections.
  """
  @spec paginate([map()], map(), String.t()) :: map()
  def paginate(line_items, params, url) do
    limit = params |> get_integer(:limit, 10) |> min(100)
    starting_after = Map.get(params, :starting_after)
    ending_before = Map.get(params, :ending_before)

    line_items
    |> apply_cursor(starting_after, ending_before)
    |> Enum.take(limit + 1)
    |> then(fn page ->
      %{
        data: Enum.take(page, limit),
        has_more: length(page) > limit,
        object: "list",
        url: url
      }
    end)
  end

  @doc """
  Calculates subtotal/total fields from normalized line items.
  """
  @spec totals([map()]) :: map()
  def totals(line_items) when is_list(line_items) do
    Enum.reduce(
      line_items,
      %{amount_discount: 0, amount_subtotal: 0, amount_tax: 0, amount_total: 0},
      fn item, acc ->
        %{
          amount_discount: acc.amount_discount + (value(item, :amount_discount) || 0),
          amount_subtotal: acc.amount_subtotal + (value(item, :amount_subtotal) || 0),
          amount_tax: acc.amount_tax + (value(item, :amount_tax) || 0),
          amount_total: acc.amount_total + (value(item, :amount_total) || 0)
        }
      end
    )
  end

  def totals(_line_items), do: %{amount_discount: 0, amount_subtotal: 0, amount_tax: 0, amount_total: 0}

  @doc """
  Derives a currency from line item params or normalized line items.
  """
  @spec derive_currency([map()] | term()) :: String.t() | nil
  def derive_currency(line_items) when is_list(line_items) do
    Enum.find_value(line_items, fn item ->
      value(item, :currency) ||
        item |> value(:price) |> value(:currency) ||
        item |> value(:price_data) |> value(:currency)
    end)
  end

  def derive_currency(_line_items), do: nil

  @doc false
  @spec value(term(), atom()) :: term()
  def value(nil, _key), do: nil

  def value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  def value(_other, _key), do: nil

  defp normalize_item(item, owner_key, owner_id) do
    price = normalize_price(item)
    quantity = item |> value(:quantity) |> to_integer_default(1)
    unit_amount = unit_amount(item, price)
    currency = currency(item, price)
    amount_subtotal = value(item, :amount_subtotal) || unit_amount * quantity
    amount_tax = value(item, :amount_tax) || 0
    amount_discount = value(item, :amount_discount) || 0
    amount_total = value(item, :amount_total) || amount_subtotal + amount_tax - amount_discount

    item
    |> normalize_keys()
    |> Map.merge(%{
      amount_discount: amount_discount,
      amount_subtotal: amount_subtotal,
      amount_tax: amount_tax,
      amount_total: amount_total,
      currency: currency,
      description: description(item, price),
      id: value(item, :id) || generate_id("li"),
      object: "item",
      price: price,
      quantity: quantity,
      unit_amount_excluding_tax: unit_amount
    })
    |> Map.drop([:amount, :price_data, :payment_link, :session])
    |> Map.put(owner_key, owner_id)
  end

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        known_key = Enum.find(@known_keys, &(Atom.to_string(&1) == key))
        {known_key || key, value}

      {key, value} ->
        {key, value}
    end)
  end

  defp normalize_keys(_), do: %{}

  defp normalize_price(item) do
    case value(item, :price) do
      %{} = price -> price
      price_id when is_binary(price_id) -> fetch_price(price_id)
      _ -> build_price_from_price_data(item)
    end
  end

  defp fetch_price(price_id) do
    case Prices.get(price_id) do
      {:ok, price} -> price
      {:error, :not_found} -> minimal_price(price_id)
    end
  end

  defp minimal_price(price_id) do
    %{
      active: true,
      currency: "usd",
      id: price_id,
      livemode: false,
      object: "price",
      type: "one_time",
      unit_amount: 0
    }
  end

  defp build_price_from_price_data(item) do
    case value(item, :price_data) do
      %{} = price_data -> embedded_price(price_data)
      _ -> nil
    end
  end

  defp embedded_price(price_data) do
    unit_amount = value(price_data, :unit_amount) || 0
    recurring = value(price_data, :recurring)

    %{
      active: true,
      currency: value(price_data, :currency) || "usd",
      id: generate_id("price"),
      livemode: false,
      lookup_key: nil,
      metadata: value(price_data, :metadata) || %{},
      nickname: nil,
      object: "price",
      product: value(price_data, :product) || value(price_data, :product_data),
      recurring: recurring,
      tax_behavior: value(price_data, :tax_behavior) || "unspecified",
      type: price_type(recurring),
      unit_amount: to_integer(unit_amount),
      unit_amount_decimal: to_string(unit_amount)
    }
  end

  defp price_type(nil), do: "one_time"
  defp price_type(false), do: "one_time"
  defp price_type(_recurring), do: "recurring"

  defp unit_amount(item, price) do
    item
    |> value(:unit_amount_excluding_tax)
    |> case do
      nil ->
        value(item, :unit_amount) ||
          value(item, :amount) ||
          (price || value(item, :price)) |> value(:unit_amount) ||
          item |> value(:price_data) |> value(:unit_amount) ||
          0

      amount ->
        amount
    end
    |> to_integer_default()
  end

  defp currency(item, price) do
    value(item, :currency) ||
      value(price, :currency) ||
      item |> value(:price_data) |> value(:currency) ||
      "usd"
  end

  defp description(item, price) do
    value(item, :description) ||
      value(price, :nickname) ||
      item |> value(:price_data) |> value(:product_data) |> value(:name)
  end

  defp apply_cursor(line_items, nil, nil), do: line_items

  defp apply_cursor(line_items, starting_after, nil) when is_binary(starting_after) do
    line_items
    |> Enum.drop_while(fn item -> Map.get(item, :id) != starting_after end)
    |> Enum.drop(1)
  end

  defp apply_cursor(line_items, nil, ending_before) when is_binary(ending_before) do
    Enum.take_while(line_items, fn item -> Map.get(item, :id) != ending_before end)
  end

  defp apply_cursor(line_items, _starting_after, ending_before) do
    apply_cursor(line_items, nil, ending_before)
  end

  defp to_integer_default(value, default \\ 0)
  defp to_integer_default(value, _default) when is_integer(value), do: value

  defp to_integer_default(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _} -> integer
      :error -> default
    end
  end

  defp to_integer_default(nil, default), do: default
  defp to_integer_default(_value, default), do: default
end
