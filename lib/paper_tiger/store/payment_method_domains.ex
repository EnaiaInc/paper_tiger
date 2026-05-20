defmodule PaperTiger.Store.PaymentMethodDomains do
  @moduledoc """
  ETS-backed storage for PaymentMethodDomain resources.
  """

  use PaperTiger.Store,
    table: :paper_tiger_payment_method_domains,
    resource: "payment_method_domain",
    plural: "payment_method_domains",
    prefix: "pmd"
end
