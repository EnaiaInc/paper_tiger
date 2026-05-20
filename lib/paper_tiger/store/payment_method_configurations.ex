defmodule PaperTiger.Store.PaymentMethodConfigurations do
  @moduledoc """
  ETS-backed storage for PaymentMethodConfiguration resources.
  """

  use PaperTiger.Store,
    table: :paper_tiger_payment_method_configurations,
    resource: "payment_method_configuration",
    plural: "payment_method_configurations",
    prefix: "pmc"
end
