defmodule PaperTiger.Store.BillingPortalSessions do
  @moduledoc false

  use PaperTiger.Store,
    table: :paper_tiger_billing_portal_sessions,
    resource: "billing_portal.session",
    prefix: "bps",
    plural: "billing_portal_sessions",
    url_path: "/v1/billing_portal/sessions"
end
