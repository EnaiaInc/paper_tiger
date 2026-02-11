defmodule PaperTiger.TelemetryHandler do
  @moduledoc """
  Handles telemetry events and creates Stripe events + delivers webhooks.

  This module bridges the gap between resource operations and webhook delivery.
  When resources emit telemetry events (e.g., customer created), this handler:

  1. Creates a Stripe Event object
  2. Stores it in the Events store
  3. Delivers webhooks to registered endpoints

  ## Event Naming Convention

  Telemetry events follow the pattern:
    [:paper_tiger, :resource_type, :action]

  Which maps to Stripe event types:
    resource_type.action (e.g., "customer.created")

  For nested types like subscriptions:
    [:paper_tiger, :subscription, :created] -> "customer.subscription.created"
  """

  alias PaperTiger.ChaosCoordinator
  alias PaperTiger.Store.Events
  alias PaperTiger.Store.WebhookDeliveries
  alias PaperTiger.Store.Webhooks
  alias PaperTiger.WebhookDelivery

  require Logger

  @doc """
  Attaches all telemetry handlers for PaperTiger events.

  Call this during application startup.
  """
  @spec attach() :: :ok
  def attach do
    events = [
      # Customer events
      [:paper_tiger, :customer, :created],
      [:paper_tiger, :customer, :updated],
      [:paper_tiger, :customer, :deleted],
      # Subscription events
      [:paper_tiger, :subscription, :created],
      [:paper_tiger, :subscription, :updated],
      [:paper_tiger, :subscription, :deleted],
      # Invoice events
      [:paper_tiger, :invoice, :created],
      [:paper_tiger, :invoice, :updated],
      [:paper_tiger, :invoice, :paid],
      [:paper_tiger, :invoice, :payment_succeeded],
      [:paper_tiger, :invoice, :payment_failed],
      [:paper_tiger, :invoice, :finalized],
      [:paper_tiger, :invoice, :upcoming],
      # PaymentIntent events
      [:paper_tiger, :payment_intent, :created],
      [:paper_tiger, :payment_intent, :succeeded],
      [:paper_tiger, :payment_intent, :payment_failed],
      # Charge events
      [:paper_tiger, :charge, :created],
      [:paper_tiger, :charge, :succeeded],
      [:paper_tiger, :charge, :failed],
      # Product events
      [:paper_tiger, :product, :created],
      [:paper_tiger, :product, :updated],
      [:paper_tiger, :product, :deleted],
      # Price events
      [:paper_tiger, :price, :created],
      [:paper_tiger, :price, :updated],
      [:paper_tiger, :price, :deleted],
      # PaymentMethod events
      [:paper_tiger, :payment_method, :attached],
      [:paper_tiger, :payment_method, :detached],
      # Checkout Session events
      [:paper_tiger, :checkout, :session, :completed],
      [:paper_tiger, :checkout, :session, :expired]
    ]

    :telemetry.attach_many(
      "paper_tiger-webhook-handler",
      events,
      &__MODULE__.handle_event/4,
      nil
    )

    Logger.debug("PaperTiger telemetry handlers attached")
    :ok
  end

  @doc """
  Detaches all telemetry handlers.

  Useful for testing or cleanup.
  """
  @spec detach() :: :ok | {:error, :not_found}
  def detach do
    :telemetry.detach("paper_tiger-webhook-handler")
  end

  @doc """
  Handles a telemetry event by creating a Stripe event and delivering webhooks.
  """
  @spec handle_event(list(), map(), map(), any()) :: :ok
  def handle_event(event_name, _measurements, metadata, _config) do
    stripe_event_type = telemetry_to_stripe_event(event_name)
    object = metadata[:object]

    if object do
      event = create_event(stripe_event_type, object, metadata)
      deliver_to_webhooks(event, stripe_event_type)
    else
      Logger.warning("Telemetry event #{inspect(event_name)} missing :object in metadata")
    end

    :ok
  end

  ## Private Functions

  defp telemetry_to_stripe_event([:paper_tiger, :subscription | rest]) do
    # Subscriptions use nested naming: customer.subscription.created
    "customer.subscription.#{Enum.join(rest, ".")}"
  end

  defp telemetry_to_stripe_event([:paper_tiger, resource, action]) do
    "#{resource}.#{action}"
  end

  defp telemetry_to_stripe_event([:paper_tiger, resource | rest]) do
    "#{resource}.#{Enum.join(rest, ".")}"
  end

  defp create_event(type, object, metadata) do
    data =
      case Map.get(metadata, :previous_attributes) do
        nil -> %{object: object}
        prev -> %{object: object, previous_attributes: prev}
      end

    event = %{
      api_version: "2023-10-16",
      created: PaperTiger.now(),
      data: data,
      delivery_attempts: [],
      id: PaperTiger.Resource.generate_id("evt"),
      livemode: false,
      object: "event",
      pending_webhooks: 0,
      request: %{
        id: nil,
        idempotency_key: nil
      },
      type: type
    }

    {:ok, event} = Events.insert(event)
    Logger.debug("Event created: #{event.id} (#{type})")
    event
  end

  defp deliver_to_webhooks(event, event_type) do
    webhook_mode = Application.get_env(:paper_tiger, :webhook_mode)

    # In :collect mode, store all events for test inspection without needing
    # registered webhooks. This lets tests verify what webhooks would fire.
    if webhook_mode == :collect do
      Logger.debug("Collecting #{event_type} webhook for test inspection")
      WebhookDeliveries.record(event, %{id: "test_collector", url: "test://collect"})
    else
      deliver_to_registered_webhooks(event, event_type, webhook_mode)
    end
  end

  defp deliver_to_registered_webhooks(event, event_type, _webhook_mode) do
    %{data: webhooks} = Webhooks.list(%{})
    matching_webhooks = Enum.filter(webhooks, &event_matches_webhook?(&1, event_type))
    deliver_fn = build_delivery_fn(matching_webhooks, event_type)

    # Route through ChaosCoordinator for potential chaos
    ChaosCoordinator.queue_event(event, deliver_fn)
  end

  defp build_delivery_fn(matching_webhooks, event_type) do
    sync_mode? = Application.get_env(:paper_tiger, :webhook_mode) == :sync

    fn evt ->
      Enum.each(matching_webhooks, fn webhook ->
        deliver_to_webhook(evt, webhook, event_type, sync_mode?)
      end)
    end
  end

  defp deliver_to_webhook(evt, webhook, event_type, sync_mode?) do
    Logger.debug("Delivering #{event_type} to webhook #{webhook.id}")

    if sync_mode? do
      WebhookDelivery.deliver_event_sync(evt.id, webhook.id)
    else
      WebhookDelivery.deliver_event(evt.id, webhook.id)
    end
  end

  defp event_matches_webhook?(webhook, event_type) do
    enabled_events = webhook[:enabled_events] || webhook["enabled_events"] || []

    Enum.any?(enabled_events, fn pattern ->
      pattern == "*" or pattern == event_type or wildcard_match?(pattern, event_type)
    end)
  end

  defp wildcard_match?(pattern, event_type) do
    # Handle patterns like "customer.*" or "invoice.payment_*"
    if String.ends_with?(pattern, "*") do
      prefix = String.trim_trailing(pattern, "*")
      String.starts_with?(event_type, prefix)
    else
      false
    end
  end
end
