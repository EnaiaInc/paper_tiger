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

  alias PaperTiger.Store.Customers
  alias PaperTiger.Store.Invoices
  alias PaperTiger.Store.Plans
  alias PaperTiger.Store.Prices
  alias PaperTiger.Store.SubscriptionItems
  alias PaperTiger.Store.Subscriptions

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
         customer_id = Map.get(conn.params, :customer),
         :ok <- validate_customer_exists(customer_id),
         items = Map.get(conn.params, :items),
         :ok <- validate_prices_exist(items),
         subscription = build_subscription(conn.params),
         {:ok, subscription} <- Subscriptions.insert(subscription),
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

      {:error, :customer_not_found, customer_id} ->
        error_response(conn, PaperTiger.Error.not_found("customer", customer_id))

      {:error, :price_not_found, price_id, index} ->
        error = %PaperTiger.Error{
          code: "resource_missing",
          message: "No such price: '#{price_id}'",
          param: "items[#{index}][price]",
          status: 404,
          type: "invalid_request_error"
        }

        error_response(conn, error)
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
        |> load_latest_invoice()
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
         updated = maybe_activate_subscription_after_trial(updated),
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

    # Get all subscriptions in current namespace
    all_subscriptions = Subscriptions.list_namespace(PaperTiger.Test.current_namespace())

    # Filter by customer and/or status if provided
    filtered_subscriptions =
      case {Map.get(conn.params, :customer), Map.get(conn.params, :status)} do
        {nil, nil} ->
          all_subscriptions

        {customer_id, nil} when is_binary(customer_id) ->
          Enum.filter(all_subscriptions, fn sub -> sub.customer == customer_id end)

        {nil, status} ->
          status_string = if is_atom(status), do: Atom.to_string(status), else: status
          Enum.filter(all_subscriptions, fn sub -> sub.status == status_string end)

        {customer_id, status} when is_binary(customer_id) ->
          status_string = if is_atom(status), do: Atom.to_string(status), else: status

          Enum.filter(all_subscriptions, fn sub ->
            sub.customer == customer_id and sub.status == status_string
          end)
      end

    # Load subscription items and latest invoice for each subscription in the list
    subscriptions_with_details =
      filtered_subscriptions
      |> Enum.map(&load_subscription_items/1)
      |> Enum.map(&load_latest_invoice/1)

    # Paginate the filtered results
    result =
      PaperTiger.List.paginate(
        subscriptions_with_details,
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
    |> maybe_coerce_trial_end()
  end

  defp maybe_coerce_cancel_at_period_end(params) do
    case Map.get(params, :cancel_at_period_end) do
      nil -> params
      value -> Map.put(params, :cancel_at_period_end, to_boolean(value))
    end
  end

  defp maybe_coerce_trial_end(params) do
    case Map.get(params, :trial_end) do
      nil -> params
      :now -> Map.put(params, :trial_end, PaperTiger.now())
      "now" -> Map.put(params, :trial_end, PaperTiger.now())
      value when is_integer(value) -> params
      value when is_binary(value) -> Map.put(params, :trial_end, String.to_integer(value))
    end
  end

  # Convert subscription from "trialing" to "active" when trial_end is set to now or past
  defp maybe_activate_subscription_after_trial(subscription) do
    now = PaperTiger.now()
    trial_end = Map.get(subscription, :trial_end)
    status = Map.get(subscription, :status)

    # If subscription is trialing and trial_end is now or in the past, activate it
    if status == "trialing" && trial_end != nil && trial_end <= now do
      subscription
      |> Map.put(:status, "active")
      |> Map.put(:trial_end, nil)
      |> Map.put(:trial_start, nil)
      |> Map.put(:current_period_start, now)
      |> Map.put(:current_period_end, now + 30 * 86_400)
    else
      # Otherwise, leave subscription as is
      subscription
    end
  end

  # Helper to get field from item map (supports both atom and string keys)
  defp get_item_field(item, field, default \\ nil) do
    Map.get(item, field) || Map.get(item, Atom.to_string(field), default)
  end

  defp calculate_trial_end(params, now) do
    case get_optional_integer(params, :trial_end) do
      nil ->
        trial_days = params |> Map.get(:trial_period_days, 0) |> to_integer()
        if trial_days > 0, do: now + trial_days * 86_400

      explicit_trial_end ->
        explicit_trial_end
    end
  end

  defp determine_subscription_status(params, trial_end) do
    case Map.get(params, :status) do
      nil -> derive_status_from_context(params, trial_end)
      explicit_status -> explicit_status
    end
  end

  defp derive_status_from_context(params, trial_end) do
    cond do
      trial_end -> "trialing"
      Map.get(params, :payment_behavior) == "default_incomplete" -> "incomplete"
      true -> "active"
    end
  end

  defp build_subscription(params) do
    now = PaperTiger.now()
    trial_end = calculate_trial_end(params, now)
    current_period_start = trial_end || now
    current_period_end = current_period_start + 30 * 86_400
    status = determine_subscription_status(params, trial_end)

    %{
      id: generate_id("sub", Map.get(params, :id)),
      object: "subscription",
      created: now,
      status: status,
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
      subscription_item = build_subscription_item(subscription_id, item, now + index, nil)
      SubscriptionItems.insert(subscription_item)
    end)

    :ok
  end

  defp create_subscription_items(_subscription_id, _items), do: :ok

  # Fetches full price object from store
  # Note: Prices are validated upfront in validate_prices_exist/1, so this should always succeed
  # Stripe API accepts both price IDs and plan IDs, so we check both stores
  defp fetch_price_object(price_id) when is_binary(price_id) do
    case Prices.get(price_id) do
      {:ok, price} ->
        price

      {:error, :not_found} ->
        # Try as plan ID (convert plan to price format for compatibility)
        case Plans.get(price_id) do
          {:ok, plan} -> convert_plan_to_price_format(plan)
          {:error, :not_found} -> nil
        end
    end
  end

  defp fetch_price_object(_), do: nil

  # Convert plan object to price format for compatibility
  defp convert_plan_to_price_format(plan) do
    recurring_map = %{interval: plan.interval}

    recurring_map =
      if plan.interval_count do
        Map.put(recurring_map, :interval_count, plan.interval_count)
      else
        recurring_map
      end

    %{
      active: plan.active,
      created: plan.created,
      currency: plan.currency,
      id: plan.id,
      livemode: plan.livemode,
      metadata: plan.metadata || %{},
      nickname: plan.nickname,
      object: "price",
      product: plan.product,
      recurring: recurring_map,
      type: "recurring",
      unit_amount: plan.amount
    }
  end

  # Validates that the customer exists in the store
  defp validate_customer_exists(customer_id) do
    case Customers.get(customer_id) do
      {:ok, _customer} -> :ok
      {:error, :not_found} -> {:error, :customer_not_found, customer_id}
    end
  end

  # Validates that all prices in the items list exist in the store
  # Note: Stripe accepts both plan IDs and price IDs for the :price key
  defp validate_prices_exist(items) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      price_id = get_item_field(item, :price)

      # Try to find as price first, then as plan (Stripe API accepts both)
      case validate_price_or_plan_exists(price_id) do
        :ok -> {:cont, :ok}
        {:error, :not_found} -> {:halt, {:error, :price_not_found, price_id, index}}
      end
    end)
  end

  defp validate_prices_exist(_), do: :ok

  # Helper to check if a price or plan exists (Stripe API accepts both IDs)
  defp validate_price_or_plan_exists(id) do
    case Prices.get(id) do
      {:ok, _price} ->
        :ok

      {:error, :not_found} ->
        case Plans.get(id) do
          {:ok, _plan} -> :ok
          {:error, :not_found} -> {:error, :not_found}
        end
    end
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
    existing_items = SubscriptionItems.find_by_subscription(subscription_id)
    existing_by_id = Map.new(existing_items, &{&1.id, &1})

    # Track which existing items we've seen (to delete removed ones)
    seen_ids = MapSet.new()

    # Process each item in the update payload
    {seen_ids, _} =
      items
      |> Enum.with_index()
      |> Enum.reduce({seen_ids, PaperTiger.now()}, fn {item, index}, {seen, now} ->
        item_id = get_item_field(item, :id)

        cond do
          # Item has an ID and exists - update it
          item_id && Map.has_key?(existing_by_id, item_id) ->
            existing = existing_by_id[item_id]
            updated = update_existing_item(existing, item)
            SubscriptionItems.update(updated)
            {MapSet.put(seen, item_id), now}

          # Item has an ID but doesn't exist - create with that ID (edge case)
          item_id ->
            new_item = build_subscription_item(subscription_id, item, now + index, item_id)
            SubscriptionItems.insert(new_item)
            {MapSet.put(seen, item_id), now}

          # No ID - create new item
          true ->
            new_item = build_subscription_item(subscription_id, item, now + index, nil)
            SubscriptionItems.insert(new_item)
            {seen, now}
        end
      end)

    # Delete items that weren't in the update payload
    existing_items
    |> Enum.reject(&MapSet.member?(seen_ids, &1.id))
    |> Enum.each(&SubscriptionItems.delete(&1.id))

    :ok
  end

  defp update_subscription_items(_subscription_id, _invalid), do: :ok

  defp build_subscription_item(subscription_id, item, created_at, custom_id) do
    price_id = get_item_field(item, :price)
    price_object = fetch_price_object(price_id)

    # Build plan object from price for backwards compatibility (Stripe API populates both)
    plan_object = build_plan_from_price(price_object)

    %{
      created: created_at,
      id: custom_id || generate_id("si"),
      metadata: get_item_field(item, :metadata, %{}),
      object: "subscription_item",
      plan: plan_object,
      price: price_object,
      quantity: item |> get_item_field(:quantity, 1) |> to_integer(),
      subscription: subscription_id
    }
  end

  # Builds a plan object from a price for backwards compatibility
  # The real Stripe API populates both plan and price on subscription items
  defp build_plan_from_price(nil), do: nil

  defp build_plan_from_price(price) do
    %{
      active: price.active,
      amount: price.unit_amount,
      created: price.created,
      currency: price.currency,
      id: price.id,
      interval: get_in(price, [:recurring, :interval]),
      interval_count: get_in(price, [:recurring, :interval_count]) || 1,
      livemode: price.livemode,
      metadata: price.metadata,
      nickname: price.nickname,
      object: "plan",
      product: price.product
    }
  end

  defp update_existing_item(existing, updates) do
    price_id = get_item_field(updates, :price)
    new_price = if(price_id, do: fetch_price_object(price_id), else: existing.price)
    new_plan = if(price_id, do: build_plan_from_price(new_price), else: existing[:plan])

    existing
    |> Map.put(:metadata, get_item_field(updates, :metadata, existing.metadata))
    |> Map.put(:price, new_price)
    |> Map.put(:plan, new_plan)
    |> Map.put(:quantity, updates |> get_item_field(:quantity, existing.quantity) |> to_integer())
  end

  defp cancel_subscription(subscription) do
    now = PaperTiger.now()

    # Stripe returns "incomplete_expired" when cancelling incomplete subscriptions
    new_status =
      if subscription.status == "incomplete" do
        "incomplete_expired"
      else
        "canceled"
      end

    %{
      subscription
      | canceled_at: now,
        ended_at: now,
        status: new_status
    }
  end

  # Loads the latest invoice ID for this subscription from the store
  # Note: By default Stripe returns only the invoice ID, not the full object
  # The full object is returned only when expand: ["latest_invoice"] is passed
  defp load_latest_invoice(subscription) do
    latest_invoice_id =
      case Invoices.find_by_subscription(subscription.id)
           |> Enum.sort_by(& &1.created, :desc)
           |> List.first() do
        nil -> nil
        invoice -> invoice.id
      end

    Map.put(subscription, :latest_invoice, latest_invoice_id)
  end

  defp maybe_expand(subscription, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(subscription, expand_params)
  end
end
