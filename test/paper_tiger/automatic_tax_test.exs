defmodule PaperTiger.AutomaticTaxTest do
  use ExUnit.Case, async: true

  alias PaperTiger.AutomaticTax

  describe "automatic_tax/2" do
    test "returns checkout-style status for checkout sessions" do
      automatic_tax = AutomaticTax.automatic_tax(%{automatic_tax: %{enabled: true}}, :checkout_session)

      assert automatic_tax == %{enabled: true, liability: nil, status: "complete"}
    end

    test "returns subscription-style disabled reason without calculation status" do
      automatic_tax = AutomaticTax.automatic_tax(%{"automatic_tax" => %{"enabled" => "true"}}, :subscription)

      assert automatic_tax == %{disabled_reason: nil, enabled: true, liability: nil}
    end

    test "returns invoice-style calculation status" do
      automatic_tax = AutomaticTax.automatic_tax(%{automatic_tax: %{enabled: true}}, :invoice)

      assert automatic_tax == %{disabled_reason: nil, enabled: true, liability: nil, status: "complete"}
    end
  end

  describe "apply_to_line_items/3" do
    test "applies deterministic tax totals and line tax fields" do
      {lines, totals} =
        AutomaticTax.apply_to_line_items(
          [%{quantity: "2", unit_amount: "1000"}],
          %{automatic_tax: %{enabled: true}, metadata: %{tax_country: "US"}},
          :invoice
        )

      assert totals.subtotal == 2000
      assert totals.amount_tax == 150
      assert totals.total == 2150
      assert totals.total_details.amount_tax == 150

      assert [
               %{
                 amount_tax: 150,
                 amount_total: 2150,
                 tax_amounts: [%{amount: 150, inclusive: false, tax_rate: nil, taxable_amount: 2000}],
                 taxes: [%{amount: 150, tax_behavior: "exclusive", taxable_amount: 2000}]
               }
             ] = lines
    end
  end
end
