defmodule PaperTiger.ChaosCoordinator do
  @moduledoc """
  Unified chaos testing infrastructure for PaperTiger.

  Consolidates all chaos testing capabilities into a single coordinator:
  - Payment chaos (failure rates, decline codes)
  - Event chaos (out-of-order delivery, duplicates, delays)
  - API chaos (timeouts, rate limits, server errors)

  ## Configuration

      PaperTiger.ChaosCoordinator.configure(%{
        payment: %{
          failure_rate: 0.1,
          decline_codes: [:card_declined, :insufficient_funds],
          decline_weights: %{card_declined: 0.7, insufficient_funds: 0.3}
        },
        events: %{
          out_of_order: true,
          duplicate_rate: 0.05,
          buffer_window_ms: 500
        },
        api: %{
          timeout_rate: 0.02,
          timeout_ms: 5000,
          rate_limit_rate: 0.01,
          error_rate: 0.01
        }
      })

  ## Per-Customer Overrides

      # Force specific customer to always fail
      PaperTiger.ChaosCoordinator.simulate_failure("cus_xxx", :card_declined)

      # Clear override
      PaperTiger.ChaosCoordinator.clear_simulation("cus_xxx")

  ## Namespace Isolation

  Uses ETS with namespace isolation for test concurrency.
  Each test process can have its own chaos state.
  """

  use GenServer

  require Logger

  @table :paper_tiger_chaos

  @default_decline_codes [
    :card_declined,
    :insufficient_funds,
    :expired_card,
    :processing_error
  ]

  @extended_decline_codes [
    # Card Issues
    :do_not_honor,
    :lost_card,
    :stolen_card,
    :card_not_supported,
    :currency_not_supported,
    :duplicate_transaction,
    # Fraud
    :fraudulent,
    :merchant_blacklist,
    :security_violation,
    :pickup_card,
    # Limits
    :card_velocity_exceeded,
    :withdrawal_count_limit_exceeded,
    # Authentication
    :authentication_required,
    :incorrect_cvc,
    :incorrect_zip,
    # Generic
    :generic_decline,
    :try_again_later,
    :issuer_not_available
  ]

  @all_decline_codes @default_decline_codes ++ @extended_decline_codes

  @default_config %{
    api: %{
      endpoint_overrides: %{},
      error_rate: 0.0,
      rate_limit_rate: 0.0,
      timeout_ms: 5000,
      timeout_rate: 0.0
    },
    events: %{
      buffer_window_ms: 0,
      duplicate_rate: 0.0,
      out_of_order: false
    },
    payment: %{
      decline_codes: @default_decline_codes,
      decline_weights: nil,
      failure_rate: 0.0
    }
  }

  ## Public API - Configuration

  @doc """
  Returns all available decline codes.
  """
  def all_decline_codes, do: @all_decline_codes

  @doc """
  Returns the default decline codes.
  """
  def default_decline_codes, do: @default_decline_codes

  @doc """
  Starts the ChaosCoordinator.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Configures chaos settings. Merges with existing config.

  ## Examples

      # Enable payment chaos
      configure(%{payment: %{failure_rate: 0.1}})

      # Enable event chaos
      configure(%{events: %{out_of_order: true, buffer_window_ms: 500}})

      # Enable API chaos
      configure(%{api: %{timeout_rate: 0.05}})
  """
  @spec configure(map()) :: :ok
  def configure(config) do
    GenServer.call(__MODULE__, {:configure, config})
  end

  @doc """
  Gets the current chaos configuration.
  """
  @spec get_config() :: map()
  def get_config do
    GenServer.call(__MODULE__, :get_config)
  end

  @doc """
  Resets all chaos configuration to defaults and clears all state.
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc """
  Gets chaos statistics.
  """
  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  ## Public API - Payment Chaos

  @doc """
  Determines if a payment should fail for the given customer.

  Checks customer overrides first, then applies configured chaos rules.

  Returns:
  - `{:ok, :succeed}` - Payment should succeed
  - `{:ok, {:fail, decline_code}}` - Payment should fail with the given code
  """
  @spec should_payment_fail?(String.t()) :: {:ok, :succeed} | {:ok, {:fail, atom()}}
  def should_payment_fail?(customer_id) do
    GenServer.call(__MODULE__, {:should_payment_fail, customer_id})
  end

  @doc """
  Forces payment failures for a specific customer.

  The customer's payments will fail with the given decline code until cleared.
  """
  @spec simulate_failure(String.t(), atom()) :: :ok
  def simulate_failure(customer_id, decline_code) when decline_code in @all_decline_codes do
    GenServer.call(__MODULE__, {:simulate_failure, customer_id, decline_code})
  end

  def simulate_failure(_customer_id, decline_code) do
    raise ArgumentError, "Invalid decline code: #{inspect(decline_code)}. Valid codes: #{inspect(@all_decline_codes)}"
  end

  @doc """
  Clears any payment simulation for a customer.
  """
  @spec clear_simulation(String.t()) :: :ok
  def clear_simulation(customer_id) do
    GenServer.call(__MODULE__, {:clear_simulation, customer_id})
  end

  ## Public API - Event Chaos

  @doc """
  Queues an event for potential chaos processing.

  If event chaos is configured, the event may be:
  - Buffered and delivered out of order
  - Duplicated
  - Delayed

  If no event chaos is configured, delivers immediately.
  """
  @spec queue_event(map(), function()) :: :ok
  def queue_event(event, deliver_fn) do
    GenServer.cast(__MODULE__, {:queue_event, event, deliver_fn})
  end

  @doc """
  Forces all buffered events to be delivered immediately.

  Useful in tests to ensure events are processed before assertions.
  """
  @spec flush_events() :: :ok
  def flush_events do
    GenServer.call(__MODULE__, :flush_events)
  end

  ## Public API - API Chaos

  @doc """
  Determines if an API request should fail.

  Returns:
  - `:ok` - Request should proceed normally
  - `{:timeout, ms}` - Request should timeout after sleeping
  - `:rate_limit` - Request should return 429
  - `:server_error` - Request should return 500/502/503
  """
  @spec should_api_fail?(String.t()) :: :ok | {:timeout, non_neg_integer()} | :rate_limit | :server_error
  def should_api_fail?(path) do
    GenServer.call(__MODULE__, {:should_api_fail, path})
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for namespace-isolated chaos state
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    # Initialize default state for global namespace
    init_namespace_state(nil)

    Logger.info("PaperTiger.ChaosCoordinator started")
    {:ok, %{timers: %{}}}
  end

  defp init_namespace_state(namespace) do
    state = %{
      config: load_config_from_app_env(),
      customer_overrides: %{},
      event_buffer: [],
      stats: %{
        api_errors: 0,
        api_rate_limits: 0,
        api_timeouts: 0,
        events_duplicated: 0,
        events_reordered: 0,
        payments_failed: 0,
        payments_succeeded: 0
      }
    }

    :ets.insert(@table, {{namespace, :state}, state})
    state
  end

  defp get_namespace_state do
    namespace = PaperTiger.Test.current_namespace()

    case :ets.lookup(@table, {namespace, :state}) do
      [{{^namespace, :state}, state}] -> state
      [] -> init_namespace_state(namespace)
    end
  end

  defp put_namespace_state(state) do
    namespace = PaperTiger.Test.current_namespace()
    :ets.insert(@table, {{namespace, :state}, state})
  end

  defp current_namespace do
    PaperTiger.Test.current_namespace()
  end

  @impl true
  def handle_call({:configure, new_config}, _from, genserver_state) do
    state = get_namespace_state()
    merged = deep_merge(state.config, new_config)
    Logger.debug("ChaosCoordinator config updated: #{inspect(merged)}")
    put_namespace_state(%{state | config: merged})
    {:reply, :ok, genserver_state}
  end

  def handle_call(:get_config, _from, genserver_state) do
    state = get_namespace_state()
    {:reply, state.config, genserver_state}
  end

  def handle_call(:reset, _from, genserver_state) do
    namespace = current_namespace()

    # Cancel any pending timer for this namespace
    new_timers =
      case Map.get(genserver_state.timers, namespace) do
        nil ->
          genserver_state.timers

        timer_ref ->
          Process.cancel_timer(timer_ref)
          Map.delete(genserver_state.timers, namespace)
      end

    new_state = %{
      config: @default_config,
      customer_overrides: %{},
      event_buffer: [],
      stats: %{
        api_errors: 0,
        api_rate_limits: 0,
        api_timeouts: 0,
        events_duplicated: 0,
        events_reordered: 0,
        payments_failed: 0,
        payments_succeeded: 0
      }
    }

    put_namespace_state(new_state)
    {:reply, :ok, %{genserver_state | timers: new_timers}}
  end

  def handle_call(:get_stats, _from, genserver_state) do
    state = get_namespace_state()
    {:reply, state.stats, genserver_state}
  end

  # Payment chaos handlers
  def handle_call({:should_payment_fail, customer_id}, _from, genserver_state) do
    state = get_namespace_state()
    {result, new_state} = determine_payment_result(customer_id, state)
    put_namespace_state(new_state)
    {:reply, result, genserver_state}
  end

  def handle_call({:simulate_failure, customer_id, decline_code}, _from, genserver_state) do
    state = get_namespace_state()
    overrides = Map.put(state.customer_overrides, customer_id, decline_code)
    put_namespace_state(%{state | customer_overrides: overrides})
    {:reply, :ok, genserver_state}
  end

  def handle_call({:clear_simulation, customer_id}, _from, genserver_state) do
    state = get_namespace_state()
    overrides = Map.delete(state.customer_overrides, customer_id)
    put_namespace_state(%{state | customer_overrides: overrides})
    {:reply, :ok, genserver_state}
  end

  # Event chaos handlers
  def handle_call(:flush_events, _from, genserver_state) do
    state = get_namespace_state()
    new_state = flush_event_buffer(state)
    put_namespace_state(new_state)
    {:reply, :ok, genserver_state}
  end

  # API chaos handlers
  def handle_call({:should_api_fail, path}, _from, genserver_state) do
    state = get_namespace_state()
    {result, new_state} = determine_api_result(path, state)
    put_namespace_state(new_state)
    {:reply, result, genserver_state}
  end

  @impl true
  def handle_cast({:queue_event, event, deliver_fn}, genserver_state) do
    namespace = current_namespace()
    state = get_namespace_state()
    events_config = state.config.events
    buffer_window = events_config[:buffer_window_ms] || 0

    if buffer_window > 0 do
      # Buffer the event with its delivery function
      new_buffer = [{event, deliver_fn} | state.event_buffer]
      put_namespace_state(%{state | event_buffer: new_buffer})

      # Schedule flush if not already scheduled for this namespace
      new_timers =
        if Map.has_key?(genserver_state.timers, namespace) do
          genserver_state.timers
        else
          timer_ref = Process.send_after(self(), {:flush_buffer, namespace}, buffer_window)
          Map.put(genserver_state.timers, namespace, timer_ref)
        end

      {:noreply, %{genserver_state | timers: new_timers}}
    else
      # No buffering - deliver immediately with possible duplication
      new_state = deliver_event_with_chaos(event, deliver_fn, state)
      put_namespace_state(new_state)
      {:noreply, genserver_state}
    end
  end

  @impl true
  def handle_info({:flush_buffer, namespace}, genserver_state) do
    # Flush the buffer for the specific namespace
    case :ets.lookup(@table, {namespace, :state}) do
      [{{^namespace, :state}, state}] ->
        new_state = flush_event_buffer(state)
        :ets.insert(@table, {{namespace, :state}, new_state})

      [] ->
        :ok
    end

    # Remove the timer reference
    new_timers = Map.delete(genserver_state.timers, namespace)
    {:noreply, %{genserver_state | timers: new_timers}}
  end

  ## Private - Payment Chaos

  defp determine_payment_result(customer_id, state) do
    case Map.get(state.customer_overrides, customer_id) do
      nil ->
        determine_random_payment_result(state)

      decline_code ->
        stats = Map.update!(state.stats, :payments_failed, &(&1 + 1))
        {{:ok, {:fail, decline_code}}, %{state | stats: stats}}
    end
  end

  defp determine_random_payment_result(state) do
    payment_config = state.config.payment
    failure_rate = payment_config[:failure_rate] || 0.0

    if failure_rate > 0.0 and :rand.uniform() < failure_rate do
      decline_code = random_decline_code(payment_config)
      stats = Map.update!(state.stats, :payments_failed, &(&1 + 1))
      {{:ok, {:fail, decline_code}}, %{state | stats: stats}}
    else
      stats = Map.update!(state.stats, :payments_succeeded, &(&1 + 1))
      {{:ok, :succeed}, %{state | stats: stats}}
    end
  end

  defp random_decline_code(%{decline_codes: codes, decline_weights: nil}) do
    Enum.random(codes)
  end

  defp random_decline_code(%{decline_codes: codes, decline_weights: weights}) when is_map(weights) do
    total_weight =
      Enum.reduce(codes, 0.0, fn code, acc ->
        acc + Map.get(weights, code, 0.0)
      end)

    if total_weight == 0.0 do
      Enum.random(codes)
    else
      random_value = :rand.uniform() * total_weight
      select_weighted_code(codes, weights, random_value, 0.0)
    end
  end

  defp random_decline_code(%{decline_codes: codes}) do
    Enum.random(codes)
  end

  defp select_weighted_code([code | rest], weights, target, cumulative) do
    weight = Map.get(weights, code, 0.0)
    new_cumulative = cumulative + weight

    if target <= new_cumulative do
      code
    else
      select_weighted_code(rest, weights, target, new_cumulative)
    end
  end

  defp select_weighted_code([], _weights, _target, _cumulative) do
    :card_declined
  end

  ## Private - API Chaos

  defp determine_api_result(path, state) do
    api_config = state.config.api

    # Check endpoint overrides first
    case Map.get(api_config[:endpoint_overrides] || %{}, path) do
      nil ->
        determine_random_api_result(api_config, state)

      :timeout ->
        timeout_ms = api_config[:timeout_ms] || 5000
        stats = Map.update!(state.stats, :api_timeouts, &(&1 + 1))
        {{:timeout, timeout_ms}, %{state | stats: stats}}

      :rate_limit ->
        stats = Map.update!(state.stats, :api_rate_limits, &(&1 + 1))
        {:rate_limit, %{state | stats: stats}}

      :server_error ->
        stats = Map.update!(state.stats, :api_errors, &(&1 + 1))
        {:server_error, %{state | stats: stats}}
    end
  end

  defp determine_random_api_result(api_config, state) do
    timeout_rate = api_config[:timeout_rate] || 0.0
    rate_limit_rate = api_config[:rate_limit_rate] || 0.0
    error_rate = api_config[:error_rate] || 0.0
    random = :rand.uniform()

    check_api_chaos(random, timeout_rate, rate_limit_rate, error_rate, api_config, state)
  end

  defp check_api_chaos(random, timeout_rate, _rate_limit_rate, _error_rate, api_config, state)
       when timeout_rate > 0.0 and random < timeout_rate do
    timeout_ms = api_config[:timeout_ms] || 5000
    stats = Map.update!(state.stats, :api_timeouts, &(&1 + 1))
    {{:timeout, timeout_ms}, %{state | stats: stats}}
  end

  defp check_api_chaos(random, timeout_rate, rate_limit_rate, _error_rate, _api_config, state)
       when rate_limit_rate > 0.0 and random < timeout_rate + rate_limit_rate do
    stats = Map.update!(state.stats, :api_rate_limits, &(&1 + 1))
    {:rate_limit, %{state | stats: stats}}
  end

  defp check_api_chaos(random, timeout_rate, rate_limit_rate, error_rate, _api_config, state)
       when error_rate > 0.0 and random < timeout_rate + rate_limit_rate + error_rate do
    stats = Map.update!(state.stats, :api_errors, &(&1 + 1))
    {:server_error, %{state | stats: stats}}
  end

  defp check_api_chaos(_random, _timeout_rate, _rate_limit_rate, _error_rate, _api_config, state) do
    {:ok, state}
  end

  ## Private - Event Chaos

  defp flush_event_buffer(state) do
    buffer = state.event_buffer

    if Enum.empty?(buffer) do
      state
    else
      events_config = state.config.events
      out_of_order = events_config[:out_of_order] || false

      # Maybe shuffle events
      events_to_deliver =
        if out_of_order do
          Enum.shuffle(buffer)
        else
          Enum.reverse(buffer)
        end

      # Count reordering if we shuffled
      reorder_count = if out_of_order and length(buffer) > 1, do: length(buffer), else: 0

      # Deliver each event with possible duplication
      new_state =
        Enum.reduce(events_to_deliver, state, fn {event, deliver_fn}, acc ->
          deliver_event_with_chaos(event, deliver_fn, acc)
        end)

      # Update reorder stats and clear buffer
      stats = Map.update!(new_state.stats, :events_reordered, &(&1 + reorder_count))
      %{new_state | event_buffer: [], stats: stats}
    end
  end

  defp deliver_event_with_chaos(event, deliver_fn, state) do
    events_config = state.config.events
    duplicate_rate = events_config[:duplicate_rate] || 0.0

    # Always deliver once
    deliver_fn.(event)

    # Maybe duplicate
    if duplicate_rate > 0.0 and :rand.uniform() < duplicate_rate do
      deliver_fn.(event)
      stats = Map.update!(state.stats, :events_duplicated, &(&1 + 1))
      %{state | stats: stats}
    else
      state
    end
  end

  ## Private - Helpers

  defp load_config_from_app_env do
    # Support legacy billing_mode config
    mode = Application.get_env(:paper_tiger, :billing_mode, :happy_path)
    chaos_config = Application.get_env(:paper_tiger, :chaos_config, %{})

    base_config = @default_config

    if mode == :chaos do
      payment_config =
        base_config.payment
        |> Map.put(:failure_rate, chaos_config[:payment_failure_rate] || 0.1)
        |> Map.put(:decline_codes, chaos_config[:decline_codes] || @default_decline_codes)
        |> Map.put(:decline_weights, chaos_config[:decline_code_weights])

      %{base_config | payment: payment_config}
    else
      base_config
    end
  end

  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn
      _key, base_val, override_val when is_map(base_val) and is_map(override_val) ->
        deep_merge(base_val, override_val)

      _key, _base_val, override_val ->
        override_val
    end)
  end

  defp deep_merge(_base, override), do: override
end
