defmodule PaperTiger.Store.PaymentLinks do
  @moduledoc false

  use PaperTiger.Store,
    table: :paper_tiger_payment_links,
    resource: "payment_link",
    prefix: "plink",
    plural: "payment_links",
    url_path: "/v1/payment_links"
end
