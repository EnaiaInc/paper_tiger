defmodule PaperTiger.Resources.SubscriptionSchedule do
  @moduledoc """
  Handles SubscriptionSchedule resource endpoints.

  Subscription schedules are shape-sensitive: phases must be contiguous,
  each phase must have a concrete start/end window, and active schedules expose
  `current_phase`. PaperTiger models those Stripe-facing semantics
  deterministically while keeping billing side effects intentionally small.
  """

  import PaperTiger.Resource

  alias PaperTiger.Error
  alias PaperTiger.Store.Customers
  alias PaperTiger.Store.Plans
  alias PaperTiger.Store.Prices
  alias PaperTiger.Store.SubscriptionItems
  alias PaperTiger.Store.Subscriptions
  alias PaperTiger.Store.SubscriptionSchedules

  @allowed_end_behaviors ["cancel", "release"]
  @allowed_statuses_for_cancel_release ["active", "not_started"]
  @allowed_statuses_for_update ["active", "not_started"]
  @phase_duration_units %{
    "day" => 86_400,
    "month" => 30 * 86_400,
    "week" => 7 * 86_400,
    "year" => 365 * 86_400
  }
  @recurring_interval_units @phase_duration_units

  @doc """
  Creates a new subscription schedule.
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, schedule, subscription, items} <- build_schedule(conn.params),
         {:ok, schedule} <- SubscriptionSchedules.insert(schedule),
         :ok <- persist_subscription(subscription, items) do
      maybe_store_idempotency(conn, schedule)
      :telemetry.execute([:paper_tiger, :subscription_schedule, :created], %{}, %{object: schedule})

      schedule
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, %Error{} = error} ->
        error_response(conn, error)
    end
  end

  @doc """
  Retrieves a subscription schedule by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    with {:ok, schedule} <- SubscriptionSchedules.get(id),
         {:ok, schedule} <- sync_schedule_state(schedule) do
      schedule
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, Error.not_found("subscription_schedule", id))
    end
  end

  @doc """
  Updates a subscription schedule.
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- SubscriptionSchedules.get(id),
         {:ok, existing} <- sync_schedule_state(existing),
         :ok <- validate_mutable_status(existing, @allowed_statuses_for_update, "update"),
         {:ok, updated, subscription, items} <- update_schedule(existing, conn.params),
         {:ok, updated} <- SubscriptionSchedules.update(updated),
         :ok <- persist_subscription(subscription, items) do
      :telemetry.execute([:paper_tiger, :subscription_schedule, :updated], %{}, %{object: updated})

      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, Error.not_found("subscription_schedule", id))

      {:error, %Error{} = error} ->
        error_response(conn, error)
    end
  end

  @doc """
  Lists subscription schedules with Stripe-style filters.
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    with {:ok, schedules} <- sync_all_schedules(),
         {:ok, schedules} <- filter_schedules(schedules, conn.params) do
      result =
        PaperTiger.List.paginate(
          schedules,
          Map.put(parse_pagination_params(conn.params), :url, "/v1/subscription_schedules")
        )

      json_response(conn, 200, result)
    else
      {:error, %Error{} = error} ->
        error_response(conn, error)
    end
  end

  @doc """
  Cancels a subscription schedule.
  """
  @spec cancel(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def cancel(conn, id) do
    with {:ok, schedule} <- SubscriptionSchedules.get(id),
         {:ok, schedule} <- sync_schedule_state(schedule),
         :ok <- validate_mutable_status(schedule, @allowed_statuses_for_cancel_release, "cancel"),
         canceled = cancel_schedule(schedule),
         {:ok, canceled} <- SubscriptionSchedules.update(canceled),
         :ok <- maybe_cancel_subscription(schedule.subscription) do
      :telemetry.execute([:paper_tiger, :subscription_schedule, :canceled], %{}, %{object: canceled})

      canceled
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, Error.not_found("subscription_schedule", id))

      {:error, %Error{} = error} ->
        error_response(conn, error)
    end
  end

  @doc """
  Releases a subscription schedule.
  """
  @spec release(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def release(conn, id) do
    with {:ok, schedule} <- SubscriptionSchedules.get(id),
         {:ok, schedule} <- sync_schedule_state(schedule),
         :ok <- validate_mutable_status(schedule, @allowed_statuses_for_cancel_release, "release"),
         released = release_schedule(schedule),
         {:ok, released} <- SubscriptionSchedules.update(released),
         :ok <- maybe_release_subscription(schedule.subscription) do
      :telemetry.execute([:paper_tiger, :subscription_schedule, :released], %{}, %{object: released})

      released
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, Error.not_found("subscription_schedule", id))

      {:error, %Error{} = error} ->
        error_response(conn, error)
    end
  end

  defp build_schedule(params) do
    now = PaperTiger.now()

    with {:ok, source} <- validate_schedule_source(params),
         {:ok, start_date} <- normalize_schedule_start_date(param(params, :start_date), now),
         {:ok, phases} <- normalize_phases(schedule_phases(params, source), start_date),
         {:ok, end_behavior} <- normalize_end_behavior(param(params, :end_behavior, "release")) do
      schedule_id = generate_id("sub_sched", param(params, :id))
      base = base_schedule(schedule_id, params, source, phases, end_behavior, now)
      schedule = refresh_schedule_state(base, now)
      maybe_attach_subscription(schedule, source)
    end
  end

  defp update_schedule(existing, params) do
    now = PaperTiger.now()

    with {:ok, phases} <- updated_phases(existing, params),
         {:ok, end_behavior} <- normalize_end_behavior(param(params, :end_behavior, existing.end_behavior)) do
      updated =
        existing
        |> merge_metadata(params)
        |> merge_default_settings(params)
        |> Map.put(:end_behavior, end_behavior)
        |> Map.put(:phases, phases)
        |> refresh_schedule_state(now)

      maybe_attach_subscription(updated, {:subscription_id, updated.subscription})
    end
  end

  defp validate_schedule_source(params) do
    customer_id = param(params, :customer)
    subscription_id = param(params, :from_subscription)

    cond do
      present?(customer_id) and present?(subscription_id) ->
        {:error, Error.invalid_request("Cannot specify both customer and from_subscription", "from_subscription")}

      present?(subscription_id) ->
        fetch_schedule_subscription_source(subscription_id)

      present?(customer_id) ->
        fetch_schedule_customer_source(customer_id)

      true ->
        {:error, Error.invalid_request("Missing required parameter", "customer")}
    end
  end

  defp fetch_schedule_subscription_source(subscription_id) do
    case Subscriptions.get(subscription_id) do
      {:ok, subscription} -> {:ok, {:from_subscription, subscription}}
      {:error, :not_found} -> {:error, Error.not_found("subscription", subscription_id)}
    end
  end

  defp fetch_schedule_customer_source(customer_id) do
    case Customers.get(customer_id) do
      {:ok, _customer} -> {:ok, {:customer, customer_id}}
      {:error, :not_found} -> {:error, Error.not_found("customer", customer_id)}
    end
  end

  defp schedule_phases(params, {:from_subscription, subscription}) do
    case param(params, :phases) do
      nil -> phases_from_subscription(subscription)
      phases -> phases
    end
  end

  defp schedule_phases(params, _source), do: param(params, :phases, [])

  defp phases_from_subscription(subscription) do
    items =
      SubscriptionItems.find_by_subscription(subscription.id)
      |> Enum.map(fn item ->
        %{
          price: price_id(item.price),
          quantity: item.quantity
        }
      end)

    [
      %{
        end_date: subscription.current_period_end,
        items: items,
        start_date: subscription.current_period_start
      }
    ]
  end

  defp base_schedule(schedule_id, params, source, phases, end_behavior, now) do
    %{
      application: nil,
      billing_mode: param(params, :billing_mode),
      canceled_at: nil,
      completed_at: nil,
      created: now,
      current_phase: nil,
      customer: customer_for_source(source),
      customer_account: nil,
      default_settings: default_settings(param(params, :default_settings, %{})),
      end_behavior: end_behavior,
      from_subscription: from_subscription_id(source),
      id: schedule_id,
      livemode: false,
      metadata: param(params, :metadata, %{}),
      object: "subscription_schedule",
      phases: phases,
      released_at: nil,
      released_subscription: nil,
      renewal_interval: param(params, :renewal_interval),
      status: "not_started",
      subscription: subscription_for_source(source),
      test_clock: nil
    }
  end

  defp normalize_phases(phases, schedule_start) when is_list(phases) and phases != [] do
    with :ok <- validate_phase_count(phases) do
      phases
      |> do_normalize_phases(schedule_start)
      |> finalize_normalized_phases()
    end
  end

  defp normalize_phases(_phases, _schedule_start) do
    {:error, Error.invalid_request("Subscription schedules require at least one phase", "phases")}
  end

  defp validate_phase_count(phases) when length(phases) <= 10, do: :ok

  defp validate_phase_count(_phases) do
    {:error, Error.invalid_request("You can specify up to 10 current or future phases", "phases")}
  end

  defp do_normalize_phases(phases, schedule_start) do
    phases
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], schedule_start}, &normalize_phase_step/2)
  end

  defp normalize_phase_step({phase, index}, {:ok, acc, expected_start}) do
    case normalize_phase(phase, index, expected_start) do
      {:ok, normalized} -> {:cont, {:ok, [normalized | acc], normalized.end_date}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp finalize_normalized_phases({:ok, phases, _next_start}), do: {:ok, Enum.reverse(phases)}
  defp finalize_normalized_phases({:error, error}), do: {:error, error}

  defp normalize_phase(phase, index, expected_start) when is_map(phase) do
    phase_param = "phases[#{index}]"
    explicit_start = param(phase, :start_date)

    with {:ok, start_date} <- normalize_phase_start_date(explicit_start, expected_start, "#{phase_param}[start_date]"),
         :ok <- validate_contiguous_start(explicit_start, start_date, expected_start, index),
         {:ok, items} <- normalize_phase_items(phase, index),
         {:ok, end_date} <- normalize_phase_end_date(phase, items, start_date, index),
         :ok <- validate_phase_window(start_date, end_date, phase_param) do
      {:ok,
       %{
         add_invoice_items: param(phase, :add_invoice_items, []),
         application_fee_percent: param(phase, :application_fee_percent),
         automatic_tax: param(phase, :automatic_tax),
         billing_cycle_anchor: param(phase, :billing_cycle_anchor),
         billing_thresholds: param(phase, :billing_thresholds),
         collection_method: param(phase, :collection_method),
         coupon: param(phase, :coupon),
         currency: param(phase, :currency),
         default_payment_method: param(phase, :default_payment_method),
         default_tax_rates: param(phase, :default_tax_rates, []),
         description: param(phase, :description),
         discounts: param(phase, :discounts, []),
         end_date: end_date,
         invoice_settings: param(phase, :invoice_settings),
         items: items,
         metadata: param(phase, :metadata, %{}),
         on_behalf_of: param(phase, :on_behalf_of),
         plans: plans_from_items(items),
         proration_behavior: param(phase, :proration_behavior, "create_prorations"),
         start_date: start_date,
         transfer_data: param(phase, :transfer_data),
         trial: param(phase, :trial),
         trial_end: param(phase, :trial_end)
       }}
    end
  end

  defp normalize_phase(_phase, index, _expected_start) do
    {:error, Error.invalid_request("Invalid phase", "phases[#{index}]")}
  end

  defp normalize_phase_items(phase, phase_index) do
    items = param(phase, :items) || param(phase, :plans) || []

    if valid_phase_items?(items) do
      normalize_phase_item_list(items, phase_index)
    else
      {:error, Error.invalid_request("Each phase must include at least one item", "phases[#{phase_index}][items]")}
    end
  end

  defp valid_phase_items?(items), do: is_list(items) and items != []

  defp normalize_phase_item_list(items, phase_index) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, &normalize_phase_item_step(&1, &2, phase_index))
    |> finalize_normalized_phase_items()
  end

  defp normalize_phase_item_step({item, item_index}, {:ok, acc}, phase_index) do
    case normalize_phase_item(item, phase_index, item_index) do
      {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp finalize_normalized_phase_items({:ok, normalized}), do: {:ok, Enum.reverse(normalized)}
  defp finalize_normalized_phase_items({:error, error}), do: {:error, error}

  defp normalize_phase_item(item, phase_index, item_index) when is_map(item) do
    price_id = param(item, :price) || param(item, :plan)
    param_name = "phases[#{phase_index}][items][#{item_index}][price]"

    with :ok <- require_price(price_id, param_name),
         {:ok, price} <- fetch_price_or_plan(price_id, param_name) do
      {:ok,
       %{
         billing_thresholds: param(item, :billing_thresholds),
         discounts: param(item, :discounts, []),
         metadata: param(item, :metadata, %{}),
         plan: price.id,
         price: price.id,
         quantity: item |> param(:quantity, 1) |> to_integer(),
         tax_rates: param(item, :tax_rates, [])
       }}
    end
  end

  defp normalize_phase_item(_item, phase_index, item_index) do
    {:error, Error.invalid_request("Invalid phase item", "phases[#{phase_index}][items][#{item_index}]")}
  end

  defp normalize_phase_end_date(phase, items, start_date, index) do
    end_date = param(phase, :end_date)
    duration = param(phase, :duration)
    iterations = param(phase, :iterations)
    param_name = "phases[#{index}]"

    with :ok <- validate_phase_end_date_combination(end_date, duration, iterations, param_name) do
      phase_end_date_from_spec(end_date, duration, iterations, items, start_date, param_name)
    end
  end

  defp validate_phase_end_date_combination(end_date, duration, iterations, param_name) do
    cond do
      present?(end_date) and present?(duration) ->
        {:error, Error.invalid_request("Cannot specify duration with end_date", "#{param_name}[duration]")}

      present?(end_date) and present?(iterations) ->
        {:error, Error.invalid_request("Cannot specify iterations with end_date", "#{param_name}[iterations]")}

      present?(duration) and present?(iterations) ->
        {:error, Error.invalid_request("Cannot specify duration with iterations", "#{param_name}[iterations]")}

      true ->
        :ok
    end
  end

  defp phase_end_date_from_spec(end_date, duration, iterations, items, start_date, param_name) do
    cond do
      present?(end_date) ->
        normalize_timestamp(end_date, "#{param_name}[end_date]")

      present?(duration) ->
        duration_end_date(duration, start_date, "#{param_name}[duration]")

      present?(iterations) ->
        iterations_end_date(items, iterations, start_date, "#{param_name}[iterations]")

      true ->
        {:error,
         Error.invalid_request("Phase must define end_date, duration, or iterations", "#{param_name}[end_date]")}
    end
  end

  defp duration_end_date(duration, start_date, param_name) when is_map(duration) do
    interval = duration |> param(:interval) |> to_string()
    interval_count = duration |> param(:interval_count, 1) |> to_integer()

    cond do
      not Map.has_key?(@phase_duration_units, interval) ->
        {:error, Error.invalid_request("Invalid duration interval", "#{param_name}[interval]")}

      interval_count <= 0 ->
        {:error, Error.invalid_request("Invalid duration interval_count", "#{param_name}[interval_count]")}

      true ->
        {:ok, start_date + Map.fetch!(@phase_duration_units, interval) * interval_count}
    end
  end

  defp duration_end_date(_duration, _start_date, param_name) do
    {:error, Error.invalid_request("Invalid duration", param_name)}
  end

  defp iterations_end_date([item | _], iterations, start_date, param_name) do
    iterations = to_integer(iterations)

    with :ok <- validate_positive(iterations, param_name),
         {:ok, price} <- fetch_price_or_plan(item.price, "#{param_name}[price]"),
         {:ok, seconds} <- recurring_seconds(price, param_name) do
      {:ok, start_date + seconds * iterations}
    end
  end

  defp recurring_seconds(price, param_name) do
    recurring = Map.get(price, :recurring) || %{}
    interval = recurring |> param(:interval) |> to_string()
    interval_count = recurring |> param(:interval_count, 1) |> to_integer()

    cond do
      not Map.has_key?(@recurring_interval_units, interval) ->
        {:error, Error.invalid_request("Phase iterations require a recurring price", param_name)}

      interval_count <= 0 ->
        {:error, Error.invalid_request("Invalid recurring interval_count", param_name)}

      true ->
        {:ok, Map.fetch!(@recurring_interval_units, interval) * interval_count}
    end
  end

  defp normalize_phase_start_date(nil, expected_start, _param_name), do: {:ok, expected_start}
  defp normalize_phase_start_date(value, _expected_start, param_name), do: normalize_timestamp(value, param_name)

  defp normalize_timestamp("now", _param_name), do: {:ok, PaperTiger.now()}
  defp normalize_timestamp(:now, _param_name), do: {:ok, PaperTiger.now()}

  defp normalize_timestamp(value, _param_name) when is_integer(value), do: {:ok, value}

  defp normalize_timestamp(value, param_name) when is_binary(value) do
    case Integer.parse(value) do
      {timestamp, ""} -> {:ok, timestamp}
      _ -> {:error, Error.invalid_request("Invalid timestamp", param_name)}
    end
  end

  defp normalize_timestamp(_value, param_name), do: {:error, Error.invalid_request("Invalid timestamp", param_name)}

  defp validate_contiguous_start(nil, _start_date, _expected_start, _index), do: :ok
  defp validate_contiguous_start(_raw_start, _start_date, _expected_start, 0), do: :ok

  defp validate_contiguous_start(_raw_start, start_date, expected_start, index) do
    if start_date == expected_start do
      :ok
    else
      {:error,
       Error.invalid_request(
         "Phase start_date must equal the previous phase end_date",
         "phases[#{index}][start_date]"
       )}
    end
  end

  defp validate_phase_window(start_date, end_date, param_name) do
    if end_date > start_date do
      :ok
    else
      {:error, Error.invalid_request("Phase end_date must be after start_date", "#{param_name}[end_date]")}
    end
  end

  defp updated_phases(existing, params) do
    case param(params, :phases) do
      nil ->
        {:ok, existing.phases}

      phases ->
        now = PaperTiger.now()
        preserved = Enum.filter(existing.phases, fn phase -> phase.end_date <= now end)
        start_date = next_update_start_date(existing, preserved, now)

        with :ok <- validate_update_phase_anchor(phases),
             {:ok, normalized} <- normalize_phases(phases, start_date) do
          {:ok, preserved ++ normalized}
        end
    end
  end

  defp validate_update_phase_anchor([phase | _rest]) when is_map(phase) do
    if present?(param(phase, :start_date)) do
      :ok
    else
      {:error,
       Error.invalid_request(
         "Subscription schedule updates must include a start_date on the first current or future phase",
         "phases[0][start_date]"
       )}
    end
  end

  defp validate_update_phase_anchor(_phases), do: :ok

  defp next_update_start_date(_existing, preserved, _now) when preserved != [] do
    preserved |> List.last() |> Map.fetch!(:end_date)
  end

  defp next_update_start_date(existing, _preserved, _now) do
    case current_phase(existing.phases, PaperTiger.now()) do
      nil -> existing.phases |> List.first() |> Map.fetch!(:start_date)
      phase -> phase.start_date
    end
  end

  defp normalize_schedule_start_date(nil, now), do: {:ok, now}
  defp normalize_schedule_start_date("now", now), do: {:ok, now}
  defp normalize_schedule_start_date(:now, now), do: {:ok, now}
  defp normalize_schedule_start_date(value, _now), do: {:ok, to_integer(value)}

  defp normalize_end_behavior(value) do
    value = to_string(value)

    if value in @allowed_end_behaviors do
      {:ok, value}
    else
      {:error, Error.invalid_request("Invalid end_behavior", "end_behavior")}
    end
  end

  defp refresh_schedule_state(schedule, now) do
    if terminal_status?(schedule.status) do
      schedule
    else
      do_refresh_schedule_state(schedule, now)
    end
  end

  defp do_refresh_schedule_state(%{phases: []} = schedule, _now), do: %{schedule | current_phase: nil}

  defp do_refresh_schedule_state(schedule, now) do
    first_phase = List.first(schedule.phases)
    last_phase = List.last(schedule.phases)
    active_phase = current_phase(schedule.phases, now)

    cond do
      active_phase ->
        %{schedule | completed_at: nil, current_phase: phase_window(active_phase), status: "active"}

      now < first_phase.start_date ->
        %{schedule | current_phase: nil, status: "not_started"}

      now >= last_phase.end_date ->
        %{
          schedule
          | completed_at: schedule.completed_at || last_phase.end_date,
            current_phase: nil,
            status: "completed"
        }
    end
  end

  defp current_phase(phases, now) do
    Enum.find(phases, fn phase -> phase.start_date <= now and now < phase.end_date end)
  end

  defp phase_window(phase), do: %{end_date: phase.end_date, start_date: phase.start_date}

  defp maybe_attach_subscription(%{status: "active", subscription: nil} = schedule, _source) do
    phase = current_phase(schedule.phases, PaperTiger.now())
    subscription = build_managed_subscription(schedule, phase)
    items = build_subscription_items(subscription.id, phase.items, phase.start_date)
    {:ok, %{schedule | subscription: subscription.id}, subscription, items}
  end

  defp maybe_attach_subscription(%{status: "active"} = schedule, _source) do
    with {:ok, subscription} <- update_existing_subscription(schedule) do
      phase = current_phase(schedule.phases, PaperTiger.now())
      items = build_subscription_items(subscription.id, phase.items, phase.start_date)
      {:ok, schedule, subscription, items}
    end
  end

  defp maybe_attach_subscription(schedule, _source), do: {:ok, schedule, nil, []}

  defp build_managed_subscription(schedule, phase) do
    %{
      cancel_at: nil,
      cancel_at_period_end: schedule.end_behavior == "cancel",
      canceled_at: nil,
      created: PaperTiger.now(),
      current_period_end: phase.end_date,
      current_period_start: phase.start_date,
      customer: schedule.customer,
      days_until_due: nil,
      discount: nil,
      ended_at: nil,
      id: generate_id("sub"),
      items: %{data: [], has_more: false, object: "list", url: "/v1/subscription_items"},
      latest_invoice: nil,
      livemode: false,
      metadata: phase_subscription_metadata(%{}, phase.metadata),
      next_pending_invoice_item_invoice: nil,
      object: "subscription",
      pending_setup_intent: nil,
      pending_update: nil,
      schedule: schedule.id,
      start_date: phase.start_date,
      status: "active",
      trial_end: phase.trial_end,
      trial_start: if(phase.trial_end, do: phase.start_date)
    }
    |> apply_phase_to_subscription(schedule, phase)
  end

  defp update_existing_subscription(%{subscription: subscription_id} = schedule) do
    phase = current_phase(schedule.phases, PaperTiger.now())

    case Subscriptions.get(subscription_id) do
      {:ok, subscription} ->
        {:ok,
         subscription
         |> Map.put(:current_period_start, phase.start_date)
         |> Map.put(:current_period_end, phase.end_date)
         |> Map.put(:schedule, schedule.id)
         |> Map.put(:status, "active")
         |> apply_phase_to_subscription(schedule, phase)}

      {:error, :not_found} ->
        {:ok, build_managed_subscription(schedule, phase)}
    end
  end

  defp apply_phase_to_subscription(subscription, schedule, phase) do
    subscription
    |> apply_phase_billing_fields(schedule, phase)
    |> apply_phase_payment_fields(schedule, phase)
    |> apply_phase_descriptive_fields(schedule, phase)
  end

  defp apply_phase_billing_fields(subscription, schedule, phase) do
    subscription
    |> Map.put(
      :application_fee_percent,
      phase.application_fee_percent || schedule.default_settings.application_fee_percent
    )
    |> Map.put(:automatic_tax, phase.automatic_tax || schedule.default_settings.automatic_tax)
    |> Map.put(:billing_cycle_anchor, billing_cycle_anchor(schedule, phase))
    |> Map.put(:billing_thresholds, phase.billing_thresholds || schedule.default_settings.billing_thresholds)
    |> Map.put(:collection_method, phase.collection_method || schedule.default_settings.collection_method)
    |> Map.put(:currency, phase.currency || Map.get(subscription, :currency))
    |> Map.put(:default_tax_rates, phase.default_tax_rates || [])
    |> Map.put(:discounts, phase.discounts)
    |> Map.put(:invoice_settings, phase.invoice_settings || schedule.default_settings.invoice_settings)
  end

  defp apply_phase_payment_fields(subscription, schedule, phase) do
    subscription
    |> Map.put(
      :default_payment_method,
      phase.default_payment_method || schedule.default_settings.default_payment_method
    )
    |> Map.put(:default_source, schedule.default_settings.default_source)
    |> Map.put(:on_behalf_of, phase.on_behalf_of || schedule.default_settings.on_behalf_of)
    |> Map.put(:transfer_data, phase.transfer_data || schedule.default_settings.transfer_data)
  end

  defp apply_phase_descriptive_fields(subscription, schedule, phase) do
    subscription
    |> Map.put(:description, phase.description || schedule.default_settings.description)
    |> Map.put(:metadata, phase_subscription_metadata(Map.get(subscription, :metadata, %{}), phase.metadata))
  end

  defp billing_cycle_anchor(_schedule, %{billing_cycle_anchor: "phase_start"} = phase), do: phase.start_date
  defp billing_cycle_anchor(%{default_settings: %{billing_cycle_anchor: "phase_start"}}, phase), do: phase.start_date
  defp billing_cycle_anchor(_schedule, phase), do: phase.start_date

  defp phase_subscription_metadata(existing, phase_metadata) when is_map(phase_metadata) do
    existing
    |> Map.merge(phase_metadata)
    |> Map.reject(fn {_key, value} -> value == "" end)
  end

  defp phase_subscription_metadata(existing, _phase_metadata), do: existing

  defp build_subscription_items(subscription_id, phase_items, created_at) do
    phase_items
    |> Enum.with_index()
    |> Enum.map(fn {item, index} ->
      price = price_for_item(item)

      %{
        created: created_at + index,
        id: generate_id("si"),
        metadata: item.metadata || %{},
        object: "subscription_item",
        plan: plan_from_price(price),
        price: price,
        quantity: item.quantity || 1,
        subscription: subscription_id
      }
    end)
  end

  defp persist_subscription(nil, _items), do: :ok

  defp persist_subscription(subscription, items) do
    upsert_subscription(subscription)
    replace_subscription_items(subscription.id, items)
  end

  defp upsert_subscription(subscription) do
    case Subscriptions.get(subscription.id) do
      {:ok, _existing} -> Subscriptions.update(subscription)
      {:error, :not_found} -> Subscriptions.insert(subscription)
    end

    :ok
  end

  defp replace_subscription_items(subscription_id, items) do
    subscription_id
    |> SubscriptionItems.find_by_subscription()
    |> Enum.each(&SubscriptionItems.delete(&1.id))

    Enum.each(items, &SubscriptionItems.insert/1)
    :ok
  end

  defp cancel_schedule(schedule) do
    now = PaperTiger.now()

    %{
      schedule
      | canceled_at: now,
        current_phase: nil,
        status: "canceled",
        subscription: nil
    }
  end

  defp release_schedule(schedule) do
    now = PaperTiger.now()

    %{
      schedule
      | current_phase: nil,
        released_at: now,
        released_subscription: schedule.subscription,
        status: "released",
        subscription: nil
    }
  end

  defp maybe_cancel_subscription(nil), do: :ok

  defp maybe_cancel_subscription(subscription_id) do
    case Subscriptions.get(subscription_id) do
      {:ok, subscription} ->
        now = PaperTiger.now()
        Subscriptions.update(%{subscription | canceled_at: now, ended_at: now, schedule: nil, status: "canceled"})
        :ok

      {:error, :not_found} ->
        :ok
    end
  end

  defp maybe_release_subscription(nil), do: :ok

  defp maybe_release_subscription(subscription_id) do
    case Subscriptions.get(subscription_id) do
      {:ok, subscription} ->
        Subscriptions.update(%{subscription | schedule: nil})
        :ok

      {:error, :not_found} ->
        :ok
    end
  end

  defp sync_schedule_state(schedule) do
    refreshed =
      schedule
      |> refresh_schedule_state(PaperTiger.now())
      |> apply_completed_end_behavior(schedule)

    if refreshed == schedule do
      {:ok, refreshed}
    else
      with {:ok, refreshed, subscription, items} <-
             maybe_attach_subscription(refreshed, {:subscription_id, refreshed.subscription}),
           {:ok, refreshed} <- SubscriptionSchedules.update(refreshed),
           :ok <- persist_subscription(subscription, items) do
        {:ok, refreshed}
      end
    end
  end

  defp sync_all_schedules do
    SubscriptionSchedules.list(%{limit: 100})
    |> Map.fetch!(:data)
    |> Enum.reduce({:ok, []}, fn schedule, {:ok, acc} ->
      {:ok, synced} = sync_schedule_state(schedule)
      {:ok, [synced | acc]}
    end)
    |> case do
      {:ok, schedules} -> {:ok, Enum.reverse(schedules)}
    end
  end

  defp apply_completed_end_behavior(%{status: "completed"} = refreshed, %{status: previous_status})
       when previous_status == "completed" do
    refreshed
  end

  defp apply_completed_end_behavior(%{end_behavior: "cancel", status: "completed"} = refreshed, original) do
    :ok = maybe_cancel_subscription(original.subscription)
    %{refreshed | subscription: nil}
  end

  defp apply_completed_end_behavior(%{end_behavior: "release", status: "completed"} = refreshed, original) do
    :ok = maybe_release_subscription(original.subscription)
    %{refreshed | subscription: nil}
  end

  defp apply_completed_end_behavior(refreshed, _original), do: refreshed

  defp filter_schedules(schedules, params) do
    with {:ok, schedules} <- filter_by_string(schedules, params, :customer),
         {:ok, schedules} <-
           filter_by_boolean(schedules, params, :scheduled, fn schedule -> schedule.status == "not_started" end),
         {:ok, schedules} <- filter_by_range(schedules, params, :created),
         {:ok, schedules} <- filter_by_range(schedules, params, :canceled_at),
         {:ok, schedules} <- filter_by_range(schedules, params, :completed_at) do
      filter_by_range(schedules, params, :released_at)
    end
  end

  defp filter_by_string(schedules, params, key) do
    case param(params, key) do
      nil -> {:ok, schedules}
      value -> {:ok, Enum.filter(schedules, &(Map.get(&1, key) == value))}
    end
  end

  defp filter_by_boolean(schedules, params, key, predicate) do
    case param(params, key) do
      nil ->
        {:ok, schedules}

      value when value in [true, "true"] ->
        {:ok, Enum.filter(schedules, predicate)}

      value when value in [false, "false"] ->
        {:ok, Enum.reject(schedules, predicate)}

      _value ->
        {:error, Error.invalid_request("Invalid boolean value", Atom.to_string(key))}
    end
  end

  defp filter_by_range(schedules, params, field) do
    case param(params, field) do
      nil -> {:ok, schedules}
      value -> apply_range_filter(schedules, field, value)
    end
  end

  defp apply_range_filter(schedules, field, value) when is_map(value) do
    Enum.reduce_while(value, {:ok, schedules}, fn {operator, raw_value}, {:ok, acc} ->
      operator = operator |> to_string() |> String.to_atom()
      timestamp = to_integer(raw_value)

      if operator in [:gt, :gte, :lt, :lte] do
        {:cont, {:ok, Enum.filter(acc, &range_match?(Map.get(&1, field), operator, timestamp))}}
      else
        {:halt, {:error, Error.invalid_request("Invalid range operator", Atom.to_string(field))}}
      end
    end)
  end

  defp apply_range_filter(schedules, field, value) do
    timestamp = to_integer(value)
    {:ok, Enum.filter(schedules, &(Map.get(&1, field) == timestamp))}
  end

  defp range_match?(nil, _operator, _timestamp), do: false
  defp range_match?(value, :gt, timestamp), do: value > timestamp
  defp range_match?(value, :gte, timestamp), do: value >= timestamp
  defp range_match?(value, :lt, timestamp), do: value < timestamp
  defp range_match?(value, :lte, timestamp), do: value <= timestamp

  defp validate_mutable_status(schedule, allowed, action) do
    if schedule.status in allowed do
      :ok
    else
      {:error,
       Error.invalid_request(
         "Cannot #{action} a subscription schedule with status #{schedule.status}",
         nil
       )}
    end
  end

  defp default_settings(params) when is_map(params) do
    %{
      application_fee_percent: param(params, :application_fee_percent),
      automatic_tax: param(params, :automatic_tax, %{enabled: false, liability: nil}),
      billing_cycle_anchor: param(params, :billing_cycle_anchor, "automatic"),
      billing_thresholds: param(params, :billing_thresholds),
      collection_method: param(params, :collection_method, "charge_automatically"),
      default_payment_method: param(params, :default_payment_method),
      default_source: param(params, :default_source),
      description: param(params, :description),
      invoice_settings: invoice_settings(param(params, :invoice_settings)),
      on_behalf_of: param(params, :on_behalf_of),
      transfer_data: param(params, :transfer_data)
    }
  end

  defp default_settings(_params), do: default_settings(%{})

  defp invoice_settings(nil), do: %{issuer: %{type: "self"}}

  defp invoice_settings(settings) when is_map(settings) do
    issuer = param(settings, :issuer, %{type: "self"})

    settings
    |> Map.delete("issuer")
    |> Map.put(:issuer, issuer)
  end

  defp invoice_settings(settings), do: settings

  defp merge_metadata(schedule, params) do
    case param(params, :metadata) do
      nil ->
        schedule

      metadata when is_map(metadata) ->
        merged =
          schedule.metadata
          |> Map.merge(metadata)
          |> Map.reject(fn {_key, value} -> value == "" end)

        %{schedule | metadata: merged}

      "" ->
        %{schedule | metadata: %{}}
    end
  end

  defp merge_default_settings(schedule, params) do
    case param(params, :default_settings) do
      settings when is_map(settings) ->
        %{schedule | default_settings: Map.merge(schedule.default_settings, default_settings(settings))}

      _ ->
        schedule
    end
  end

  defp terminal_status?(status), do: status in ["canceled", "completed", "released"]

  defp validate_positive(value, _param_name) when value > 0, do: :ok

  defp validate_positive(_value, param_name),
    do: {:error, Error.invalid_request("Invalid positive integer", param_name)}

  defp require_price(nil, param_name), do: {:error, Error.invalid_request("Missing required parameter", param_name)}
  defp require_price("", param_name), do: {:error, Error.invalid_request("Missing required parameter", param_name)}
  defp require_price(_price_id, _param_name), do: :ok

  defp fetch_price_or_plan(id, param_name) do
    case Prices.get(id) do
      {:ok, price} ->
        {:ok, price}

      {:error, :not_found} ->
        case Plans.get(id) do
          {:ok, plan} -> {:ok, price_from_plan(plan)}
          {:error, :not_found} -> {:error, Error.not_found("price", id) |> Map.put(:param, param_name)}
        end
    end
  end

  defp price_for_item(item), do: fetch_price_or_plan!(item.price)

  defp fetch_price_or_plan!(id) do
    case fetch_price_or_plan(id, "price") do
      {:ok, price} -> price
      {:error, _error} -> %{id: id, metadata: %{}, object: "price", recurring: %{}, unit_amount: 0}
    end
  end

  defp price_from_plan(plan) do
    recurring =
      %{
        interval: plan.interval,
        interval_count: plan[:interval_count] || 1
      }

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
      recurring: recurring,
      type: "recurring",
      unit_amount: plan.amount
    }
  end

  defp plan_from_price(price) do
    %{
      active: price[:active],
      amount: price[:unit_amount],
      created: price[:created],
      currency: price[:currency],
      id: price[:id],
      interval: get_in(price, [:recurring, :interval]),
      interval_count: get_in(price, [:recurring, :interval_count]) || 1,
      livemode: price[:livemode] || false,
      metadata: price[:metadata] || %{},
      nickname: price[:nickname],
      object: "plan",
      product: price[:product]
    }
  end

  defp plans_from_items(items) do
    Enum.map(items, fn item -> %{plan: item.price, price: item.price, quantity: item.quantity} end)
  end

  defp price_id(%{id: id}), do: id
  defp price_id(id) when is_binary(id), do: id
  defp price_id(_), do: nil

  defp customer_for_source({:from_subscription, subscription}), do: subscription.customer
  defp customer_for_source({:customer, customer_id}), do: customer_id

  defp from_subscription_id({:from_subscription, subscription}), do: subscription.id
  defp from_subscription_id(_source), do: nil

  defp subscription_for_source({:from_subscription, subscription}), do: subscription.id
  defp subscription_for_source(_source), do: nil

  defp maybe_expand(schedule, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(schedule, expand_params)
  end

  defp present?(value), do: not is_nil(value) and value != ""

  defp param(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
