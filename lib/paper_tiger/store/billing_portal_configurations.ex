defmodule PaperTiger.Store.BillingPortalConfigurations do
  @moduledoc false

  use PaperTiger.Store,
    table: :paper_tiger_billing_portal_configurations,
    resource: "billing_portal.configuration",
    prefix: "bpc",
    plural: "billing_portal_configurations",
    url_path: "/v1/billing_portal/configurations"
end
