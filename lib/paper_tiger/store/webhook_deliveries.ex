defmodule PaperTiger.Store.WebhookDeliveries do
  @moduledoc """
  In-memory store for webhook deliveries in test mode.

  When `webhook_mode: :collect` is configured, webhooks are stored here
  instead of being delivered via HTTP. Tests can then inspect what
  webhooks would have been delivered.

  Data is namespace-scoped for test isolation with `async: true`.
  """

  use PaperTiger.Store,
    table: :paper_tiger_webhook_deliveries,
    resource: "webhook_delivery",
    plural: "webhook_deliveries"

  @doc """
  Records a webhook delivery for later inspection.

  Called by the telemetry handler when in `:collect` mode.
  """
  def record(event, webhook) do
    delivery = %{
      id: PaperTiger.Resource.generate_id("whd"),
      event_id: event.id,
      event_type: event.type,
      event_data: event.data,
      webhook_id: webhook[:id] || webhook["id"],
      webhook_url: webhook[:url] || webhook["url"],
      # Use `created` to match Stripe's convention (paginate expects this field)
      created: System.system_time(:second)
    }

    insert(delivery)
    delivery
  end

  @doc """
  Gets all recorded webhook deliveries for the current namespace.

  Returns deliveries in chronological order (oldest first).
  """
  def get_all do
    %{data: deliveries} = list(%{limit: 100})
    Enum.sort_by(deliveries, & &1.created)
  end

  @doc """
  Gets webhook deliveries filtered by event type.

  ## Examples

      # Get all customer.created events
      get_by_type("customer.created")

      # Get all invoice events
      get_by_type("invoice.*")
  """
  def get_by_type(type_pattern) do
    get_all()
    |> Enum.filter(fn delivery ->
      if String.ends_with?(type_pattern, "*") do
        prefix = String.trim_trailing(type_pattern, "*")
        String.starts_with?(delivery.event_type, prefix)
      else
        delivery.event_type == type_pattern
      end
    end)
  end
end
