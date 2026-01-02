defmodule PaperTiger.Resources.SubscriptionSchedule do
  @moduledoc """
  Handles SubscriptionSchedule resource endpoints.

  ## Endpoints

  - POST   /v1/subscription_schedules             - Create subscription schedule
  - GET    /v1/subscription_schedules/:id         - Retrieve subscription schedule
  - POST   /v1/subscription_schedules/:id         - Update subscription schedule
  - POST   /v1/subscription_schedules/:id/cancel  - Cancel subscription schedule
  - POST   /v1/subscription_schedules/:id/release - Release subscription schedule
  - GET    /v1/subscription_schedules             - List subscription schedules

  ## SubscriptionSchedule Object

      %{
        id: "sub_sched_...",
        object: "subscription_schedule",
        created: 1234567890,
        customer: "cus_...",
        status: "not_started",
        phases: [
          %{
            start_date: 1234567890,
            end_date: 1237159890,
            plans: [%{price: "price_...", quantity: 1}]
          }
        ],
        # ... other fields
      }

  ## Schedule Statuses

  - not_started - Schedule hasn't started yet
  - active - Schedule is currently active
  - completed - Schedule has completed all phases
  - released - Schedule was released
  - canceled - Schedule was canceled
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.SubscriptionSchedules

  require Logger

  @doc """
  Creates a new subscription schedule.

  ## Required Parameters

  - customer - Customer ID
  - phases - Array of schedule phases

  ## Optional Parameters

  - from_subscription - Create from existing subscription
  - start_date - When schedule should start
  - end_behavior - What happens when schedule ends
  - metadata - Key-value metadata
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:customer]),
         schedule = build_schedule(conn.params),
         {:ok, schedule} <- SubscriptionSchedules.insert(schedule) do
      maybe_store_idempotency(conn, schedule)
      :telemetry.execute([:paper_tiger, :subscription_schedule, :created], %{}, %{object: schedule})

      schedule
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
  Retrieves a subscription schedule by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case SubscriptionSchedules.get(id) do
      {:ok, schedule} ->
        schedule
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("subscription_schedule", id))
    end
  end

  @doc """
  Updates a subscription schedule.
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- SubscriptionSchedules.get(id),
         updated = merge_updates(existing, conn.params),
         {:ok, updated} <- SubscriptionSchedules.update(updated) do
      :telemetry.execute([:paper_tiger, :subscription_schedule, :updated], %{}, %{object: updated})

      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("subscription_schedule", id))
    end
  end

  @doc """
  Lists all subscription schedules with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  - customer - Filter by customer ID
  - scheduled - Filter to only scheduled (not_started) schedules
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    # Get schedules, optionally filtered
    schedules =
      case {Map.get(conn.params, :customer), Map.get(conn.params, :scheduled)} do
        {nil, nil} ->
          :ets.tab2list(SubscriptionSchedules.table_name())
          |> Enum.map(fn {_id, schedule} -> schedule end)

        {customer_id, nil} when is_binary(customer_id) ->
          SubscriptionSchedules.find_by_customer(customer_id)

        {nil, scheduled} when scheduled in [true, "true"] ->
          SubscriptionSchedules.find_scheduled()

        {customer_id, scheduled} when is_binary(customer_id) and scheduled in [true, "true"] ->
          SubscriptionSchedules.find_by_customer(customer_id)
          |> Enum.filter(fn s -> s.status == "not_started" end)

        {customer_id, _} when is_binary(customer_id) ->
          SubscriptionSchedules.find_by_customer(customer_id)

        _ ->
          :ets.tab2list(SubscriptionSchedules.table_name())
          |> Enum.map(fn {_id, schedule} -> schedule end)
      end

    result =
      PaperTiger.List.paginate(
        schedules,
        Map.put(pagination_opts, :url, "/v1/subscription_schedules")
      )

    json_response(conn, 200, result)
  end

  @doc """
  Cancels a subscription schedule.

  POST /v1/subscription_schedules/:id/cancel

  Cancels the schedule and any associated subscription.
  """
  @spec cancel(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def cancel(conn, id) do
    with {:ok, schedule} <- SubscriptionSchedules.get(id),
         canceled = cancel_schedule(schedule),
         {:ok, canceled} <- SubscriptionSchedules.update(canceled) do
      :telemetry.execute([:paper_tiger, :subscription_schedule, :canceled], %{}, %{object: canceled})

      canceled
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("subscription_schedule", id))
    end
  end

  @doc """
  Releases a subscription schedule.

  POST /v1/subscription_schedules/:id/release

  Releases the schedule, keeping any active subscription but removing future phases.
  """
  @spec release(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def release(conn, id) do
    with {:ok, schedule} <- SubscriptionSchedules.get(id),
         released = release_schedule(schedule),
         {:ok, released} <- SubscriptionSchedules.update(released) do
      :telemetry.execute([:paper_tiger, :subscription_schedule, :released], %{}, %{object: released})

      released
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("subscription_schedule", id))
    end
  end

  ## Private Functions

  defp build_schedule(params) do
    now = PaperTiger.now()

    %{
      canceled_at: nil,
      completed_at: nil,
      created: now,
      current_phase: nil,
      customer: Map.get(params, :customer),
      default_settings: %{
        application_fee_percent: nil,
        billing_cycle_anchor: "automatic",
        billing_thresholds: nil,
        collection_method: "charge_automatically",
        default_payment_method: nil,
        invoice_settings: nil,
        transfer_data: nil
      },
      end_behavior: Map.get(params, :end_behavior, "release"),
      from_subscription: Map.get(params, :from_subscription),
      id: generate_id("sub_sched", Map.get(params, :id)),
      livemode: false,
      metadata: Map.get(params, :metadata, %{}),
      object: "subscription_schedule",
      phases: build_phases(Map.get(params, :phases, [])),
      released_at: nil,
      released_subscription: nil,
      status: "not_started",
      subscription: nil
    }
  end

  defp build_phases(phases) when is_list(phases) do
    Enum.map(phases, fn phase ->
      %{
        add_invoice_items: [],
        application_fee_percent: nil,
        billing_cycle_anchor: nil,
        billing_thresholds: nil,
        collection_method: nil,
        coupon: nil,
        default_payment_method: nil,
        default_tax_rates: [],
        end_date: Map.get(phase, :end_date) || Map.get(phase, "end_date"),
        invoice_settings: nil,
        items: Map.get(phase, :items) || Map.get(phase, "items") || [],
        metadata: Map.get(phase, :metadata) || Map.get(phase, "metadata") || %{},
        plans: Map.get(phase, :plans) || Map.get(phase, "plans") || [],
        proration_behavior: "create_prorations",
        start_date: Map.get(phase, :start_date) || Map.get(phase, "start_date"),
        transfer_data: nil,
        trial_end: nil
      }
    end)
  end

  defp build_phases(_), do: []

  defp cancel_schedule(schedule) do
    now = PaperTiger.now()

    %{
      schedule
      | canceled_at: now,
        status: "canceled"
    }
  end

  defp release_schedule(schedule) do
    now = PaperTiger.now()

    %{
      schedule
      | released_at: now,
        released_subscription: schedule.subscription,
        status: "released"
    }
  end

  defp maybe_expand(schedule, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(schedule, expand_params)
  end
end
