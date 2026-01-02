defmodule PaperTiger.Resources.Subscription do
  @moduledoc """
  Handles Subscription resource endpoints.

  ## Endpoints

  - POST   /v1/subscriptions      - Create subscription
  - GET    /v1/subscriptions/:id  - Retrieve subscription
  - POST   /v1/subscriptions/:id  - Update subscription
  - DELETE /v1/subscriptions/:id  - Cancel subscription
  - GET    /v1/subscriptions      - List subscriptions

  ## Subscription Object

      %{
        id: "sub_...",
        object: "subscription",
        created: 1234567890,
        status: "active",
        customer: "cus_...",
        items: %{
          data: [%{id: "si_...", price: %{id: "price_...", object: "price", ...}, quantity: 1}]
        },
        current_period_start: 1234567890,
        current_period_end: 1237159890,
        # ... other fields
      }

  ## Subscription Statuses

  - active - Subscription is active
  - trialing - In trial period
  - past_due - Payment failed
  - canceled - Canceled
  - unpaid - Unpaid and canceled
  - incomplete - Incomplete (needs payment)
  - incomplete_expired - Incomplete and expired
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Prices
  alias PaperTiger.Store.SubscriptionItems
  alias PaperTiger.Store.Subscriptions

  require Logger

  @doc """
  Creates a new subscription.

  ## Required Parameters

  - customer - Customer ID
  - items - Array of subscription items (each with price and quantity)

  ## Optional Parameters

  - id - Custom ID (must start with "sub_"). Useful for seeding deterministic data.
  - default_payment_method - Payment method ID
  - trial_period_days - Days of trial period
  - metadata - Key-value metadata
  - billing_cycle_anchor - Anchor for billing cycle
  - cancel_at_period_end - Cancel at end of current period
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:customer, :items]),
         subscription = build_subscription(conn.params),
         {:ok, subscription} <- Subscriptions.insert(subscription),
         items = Map.get(conn.params, :items),
         :ok <- create_subscription_items(subscription.id, items) do
      maybe_store_idempotency(conn, subscription)

      subscription_with_items = load_subscription_items(subscription)
      :telemetry.execute([:paper_tiger, :subscription, :created], %{}, %{object: subscription_with_items})

      subscription_with_items
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :invalid_params, field} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("Missing required parameter", field)
        )
    end
  end

  @doc """
  Retrieves a subscription by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case Subscriptions.get(id) do
      {:ok, subscription} ->
        subscription
        |> load_subscription_items()
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("subscription", id))
    end
  end

  @doc """
  Updates a subscription.

  ## Updatable Fields

  - items - Update subscription items
  - default_payment_method
  - trial_end
  - cancel_at_period_end
  - metadata
  - proration_behavior
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- Subscriptions.get(id),
         coerced_params = coerce_update_params(conn.params),
         updated = merge_updates(existing, coerced_params),
         {:ok, updated} <- Subscriptions.update(updated) do
      # Handle items update if provided
      if Map.has_key?(conn.params, :items) do
        update_subscription_items(id, conn.params.items)
      end

      updated_with_items = load_subscription_items(updated)
      :telemetry.execute([:paper_tiger, :subscription, :updated], %{}, %{object: updated_with_items})

      updated_with_items
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("subscription", id))
    end
  end

  @doc """
  Cancels a subscription.

  Note: DELETE /v1/subscriptions/:id cancels the subscription.
  For immediate cancellation, set cancel_at_period_end=false.
  """
  @spec delete(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def delete(conn, id) do
    with {:ok, subscription} <- Subscriptions.get(id),
         canceled = cancel_subscription(subscription),
         {:ok, canceled} <- Subscriptions.update(canceled) do
      canceled_with_items = load_subscription_items(canceled)
      :telemetry.execute([:paper_tiger, :subscription, :deleted], %{}, %{object: canceled_with_items})

      canceled_with_items
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("subscription", id))
    end
  end

  @doc """
  Lists all subscriptions with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  - customer - Filter by customer
  - status - Filter by status
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    # Get all subscriptions first
    all_subscriptions =
      :ets.tab2list(Subscriptions.table_name())
      |> Enum.map(fn {_id, subscription} -> subscription end)

    # Filter by customer if provided
    filtered_subscriptions =
      case Map.get(conn.params, :customer) do
        nil ->
          all_subscriptions

        customer_id when is_binary(customer_id) ->
          Enum.filter(all_subscriptions, fn sub -> sub.customer == customer_id end)
      end

    # Load subscription items for each subscription in the list
    subscriptions_with_items =
      Enum.map(filtered_subscriptions, &load_subscription_items/1)

    # Paginate the filtered results
    result =
      PaperTiger.List.paginate(
        subscriptions_with_items,
        Map.put(pagination_opts, :url, "/v1/subscriptions")
      )

    json_response(conn, 200, result)
  end

  @doc """
  Cancels a subscription immediately.

  POST /v1/subscriptions/:id/cancel

  Cancels the subscription right away without waiting for the current period to end.
  """
  @spec cancel(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def cancel(conn, id) do
    with {:ok, subscription} <- Subscriptions.get(id),
         canceled = cancel_subscription(subscription),
         {:ok, canceled} <- Subscriptions.update(canceled) do
      canceled
      |> load_subscription_items()
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("subscription", id))
    end
  end

  ## Private Functions

  defp coerce_update_params(params) do
    params
    |> maybe_coerce_cancel_at_period_end()
  end

  defp maybe_coerce_cancel_at_period_end(params) do
    case Map.get(params, :cancel_at_period_end) do
      nil -> params
      value -> Map.put(params, :cancel_at_period_end, to_boolean(value))
    end
  end

  # Helper to get field from item map (supports both atom and string keys)
  defp get_item_field(item, field, default \\ nil) do
    Map.get(item, field) || Map.get(item, Atom.to_string(field), default)
  end

  defp build_subscription(params) do
    now = PaperTiger.now()
    trial_days = params |> Map.get(:trial_period_days, 0) |> to_integer()
    trial_end = if trial_days > 0, do: now + trial_days * 86_400

    # Calculate billing period (default: monthly)
    period_days = 30
    current_period_start = trial_end || now
    current_period_end = current_period_start + period_days * 86_400

    %{
      id: generate_id("sub", Map.get(params, :id)),
      object: "subscription",
      created: now,
      status: if(trial_end, do: "trialing", else: "active"),
      customer: Map.get(params, :customer),
      # items will be loaded separately
      items: %{data: [], has_more: false, object: "list", url: "/v1/subscription_items"},
      current_period_start: current_period_start,
      current_period_end: current_period_end,
      trial_start: if(trial_end, do: now),
      trial_end: trial_end,
      metadata: Map.get(params, :metadata, %{}),
      # Additional fields
      livemode: false,
      billing_cycle_anchor: Map.get(params, :billing_cycle_anchor, current_period_start),
      cancel_at_period_end: false,
      cancel_at: nil,
      canceled_at: nil,
      default_payment_method: Map.get(params, :default_payment_method),
      collection_method: "charge_automatically",
      days_until_due: nil,
      ended_at: nil,
      latest_invoice: nil,
      next_pending_invoice_item_invoice: nil,
      pending_setup_intent: nil,
      pending_update: nil,
      start_date: now
    }
  end

  defp create_subscription_items(subscription_id, items) when is_list(items) do
    now = PaperTiger.now()

    items
    |> Enum.with_index()
    |> Enum.each(fn {item, index} ->
      price_id = get_item_field(item, :price)
      price_object = fetch_price_object(price_id)

      subscription_item = %{
        created: now + index,
        id: generate_id("si"),
        metadata: get_item_field(item, :metadata, %{}),
        object: "subscription_item",
        price: price_object,
        quantity: item |> get_item_field(:quantity, 1) |> to_integer(),
        subscription: subscription_id
      }

      SubscriptionItems.insert(subscription_item)
    end)

    :ok
  end

  defp create_subscription_items(_subscription_id, _items), do: :ok

  # Fetches full price object from store, or builds minimal object if not found
  defp fetch_price_object(price_id) when is_binary(price_id) do
    case Prices.get(price_id) do
      {:ok, price} -> price
      {:error, :not_found} -> build_minimal_price_object(price_id)
    end
  end

  defp fetch_price_object(_), do: nil

  # Build minimal price object when price doesn't exist in store
  # This ensures API compatibility even with ad-hoc price IDs
  defp build_minimal_price_object(price_id) do
    %{
      active: true,
      currency: "usd",
      id: price_id,
      livemode: false,
      object: "price",
      type: "recurring"
    }
  end

  defp load_subscription_items(subscription) do
    items =
      SubscriptionItems.find_by_subscription(subscription.id)
      |> Enum.sort_by(& &1.created, :asc)

    %{
      subscription
      | items: %{
          data: items,
          has_more: false,
          object: "list",
          url: "/v1/subscription_items?subscription=#{subscription.id}"
        }
    }
  end

  defp update_subscription_items(subscription_id, items) when is_list(items) do
    # Delete existing items and recreate with new values
    SubscriptionItems.delete_by_subscription(subscription_id)
    create_subscription_items(subscription_id, items)
  end

  defp update_subscription_items(_subscription_id, _invalid), do: :ok

  defp cancel_subscription(subscription) do
    now = PaperTiger.now()

    %{
      subscription
      | canceled_at: now,
        ended_at: now,
        status: "canceled"
    }
  end

  defp maybe_expand(subscription, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(subscription, expand_params)
  end
end
