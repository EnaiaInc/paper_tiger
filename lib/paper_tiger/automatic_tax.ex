defmodule PaperTiger.AutomaticTax do
  @moduledoc """
  Deterministic Stripe Tax helpers for PaperTiger's local test surface.

  This intentionally models only the automatic-tax totals that tests need.
  It is not a standalone Tax Calculations/Transactions API implementation.
  """

  @default_fixture_rates %{
    "CA" => 1300,
    "EU" => 2100,
    "GB" => 2000,
    "US" => 750
  }

  @doc """
  Returns a Stripe-shaped automatic_tax map from request params or a resource.
  """
  @spec automatic_tax(map(), atom()) :: map()
  def automatic_tax(source, resource \\ :checkout_session)

  def automatic_tax(source, resource) when is_map(source) do
    enabled = source |> value(:automatic_tax) |> value(:enabled) |> truthy?()

    resource_automatic_tax(enabled, resource)
  end

  @doc """
  True when `automatic_tax[enabled]=true` was requested.
  """
  @spec enabled?(map()) :: boolean()
  def enabled?(source) when is_map(source) do
    source |> automatic_tax(:checkout_session) |> Map.fetch!(:enabled)
  end

  @doc """
  Applies deterministic automatic-tax fields to line items and returns totals.
  """
  @spec apply_to_line_items([map()], map(), atom()) :: {[map()], map()}
  def apply_to_line_items(line_items, source, resource \\ :invoice)

  def apply_to_line_items(line_items, source, resource) when is_list(line_items) and is_map(source) do
    if enabled?(source) do
      jurisdiction = jurisdiction(source)
      rate_bps = rate_bps(jurisdiction)

      taxed_lines =
        Enum.map(line_items, fn line ->
          taxable_amount = line_amount(line)
          tax_amount = calculate_tax(taxable_amount, rate_bps)

          line
          |> Map.put(:amount_subtotal, taxable_amount)
          |> Map.put(:amount_tax, tax_amount)
          |> Map.put(:amount_total, taxable_amount + tax_amount)
          |> Map.put(:amount_excluding_tax, taxable_amount)
          |> Map.put(:subtotal, taxable_amount)
          |> Map.put(:taxes, [tax(tax_amount, taxable_amount)])
          |> Map.put(:unit_amount_excluding_tax, unit_amount_excluding_tax(line))
          |> Map.put(:tax_amounts, [
            legacy_tax_amount(tax_amount, taxable_amount)
          ])
        end)

      subtotal = Enum.reduce(taxed_lines, 0, &(&2 + line_amount(&1)))
      amount_tax = Enum.reduce(taxed_lines, 0, &(&2 + line_tax_amount(&1)))

      {taxed_lines,
       %{
         amount_tax: amount_tax,
         automatic_tax: automatic_tax(source, resource),
         subtotal: subtotal,
         total: subtotal + amount_tax,
         total_details: %{amount_discount: 0, amount_shipping: 0, amount_tax: amount_tax}
       }}
    else
      subtotal = Enum.reduce(line_items, 0, &(&2 + line_amount(&1)))

      {line_items,
       %{
         amount_tax: 0,
         automatic_tax: automatic_tax(source, resource),
         subtotal: subtotal,
         total: subtotal,
         total_details: %{amount_discount: 0, amount_shipping: 0, amount_tax: 0}
       }}
    end
  end

  def apply_to_line_items(_line_items, source, resource) when is_map(source) do
    {[], apply_to_line_items([], source, resource) |> elem(1)}
  end

  def apply_to_line_items(_line_items, _source, _resource), do: {[], %{amount_tax: 0, subtotal: 0, total: 0}}

  defp resource_automatic_tax(enabled, :subscription) do
    %{
      disabled_reason: nil,
      enabled: enabled,
      liability: nil
    }
  end

  defp resource_automatic_tax(enabled, :invoice) do
    %{
      disabled_reason: nil,
      enabled: enabled,
      liability: nil,
      status: if(enabled, do: "complete")
    }
  end

  defp resource_automatic_tax(enabled, _resource) do
    %{
      enabled: enabled,
      liability: nil,
      status: if(enabled, do: "complete")
    }
  end

  defp tax(amount, taxable_amount) do
    %{
      amount: amount,
      tax_behavior: "exclusive",
      taxable_amount: taxable_amount
    }
  end

  defp legacy_tax_amount(amount, taxable_amount) do
    %{
      amount: amount,
      inclusive: false,
      tax_rate: nil,
      taxable_amount: taxable_amount
    }
  end

  defp jurisdiction(source) do
    value(source, :tax_jurisdiction) ||
      source |> value(:automatic_tax) |> value(:jurisdiction) ||
      source |> value(:metadata) |> value(:tax_country) ||
      source |> value(:customer_details) |> value(:address) |> value(:country) ||
      source |> value(:shipping) |> value(:address) |> value(:country) ||
      "US"
  end

  defp rate_bps(jurisdiction) do
    fixtures = Application.get_env(:paper_tiger, :tax_fixtures, @default_fixture_rates)

    fixture_value =
      Map.get(fixtures, to_string(jurisdiction)) ||
        Map.get(@default_fixture_rates, to_string(jurisdiction))

    normalize_rate_bps(fixture_value || @default_fixture_rates["US"])
  end

  defp normalize_rate_bps(rate) when is_integer(rate), do: rate
  defp normalize_rate_bps(rate) when is_float(rate), do: round(rate * 100)

  defp normalize_rate_bps(rate) when is_binary(rate) do
    case Integer.parse(rate) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp normalize_rate_bps(_), do: 0

  defp calculate_tax(amount, rate_bps), do: round(amount * rate_bps / 10_000)

  defp line_tax_amount(line) do
    cond do
      tax_amount = first_tax_amount(line, :tax_amounts) ->
        tax_amount

      tax_amount = first_tax_amount(line, :taxes) ->
        tax_amount

      true ->
        0
    end
  end

  defp first_tax_amount(line, key) do
    line
    |> value(key)
    |> case do
      [%{} = tax | _] -> value(tax, :amount) || 0
      _ -> nil
    end
  end

  defp line_amount(line) do
    unit_amount =
      value(line, :unit_amount_excluding_tax) ||
        value(line, :unit_amount) ||
        line |> value(:price) |> value(:unit_amount) ||
        line |> value(:price_data) |> value(:unit_amount)

    quantity = value(line, :quantity) || 1

    if unit_amount do
      to_integer(unit_amount) * to_integer(quantity)
    else
      line |> value(:amount) |> to_integer()
    end
  end

  defp unit_amount_excluding_tax(line) do
    value(line, :unit_amount_excluding_tax) ||
      value(line, :unit_amount) ||
      line |> value(:price) |> value(:unit_amount) ||
      line |> value(:price_data) |> value(:unit_amount) ||
      line_amount(line)
  end

  defp value(nil, _key), do: nil

  defp value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value(_other, _key), do: nil

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _} -> integer
      :error -> 0
    end
  end

  defp to_integer(_), do: 0
end
