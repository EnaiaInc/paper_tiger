defmodule PaperTiger.ChaosHelpers do
  @moduledoc """
  Test helpers for chaos testing with PaperTiger.

  Provides convenient functions for enabling chaos in tests and
  ensuring cleanup after tests complete.

  ## Usage

      use PaperTiger.ChaosHelpers

      test "handles payment failures gracefully" do
        with_chaos(%{payment: %{failure_rate: 1.0}}, fn ->
          # All payments will fail in this block
          assert {:error, _} = process_payment()
        end)
      end

      test "handles out-of-order events" do
        with_event_chaos(%{out_of_order: true, buffer_window_ms: 100}, fn ->
          # Events may arrive out of order
          create_subscription()
          flush_events()
          assert_received_events_shuffled()
        end)
      end
  """

  alias PaperTiger.ChaosCoordinator

  @doc """
  Runs a function with temporary chaos configuration.

  The chaos configuration is applied before the function runs and
  reset to the original configuration after it completes (even if
  it raises an exception).

  ## Examples

      with_chaos(%{payment: %{failure_rate: 0.5}}, fn ->
        # 50% of payments fail
      end)

      with_chaos(%{
        payment: %{failure_rate: 0.1},
        events: %{duplicate_rate: 0.05},
        api: %{timeout_rate: 0.02}
      }, fn ->
        # Multiple chaos types enabled
      end)
  """
  @spec with_chaos(map(), (-> any())) :: any()
  def with_chaos(config, fun) do
    original = ChaosCoordinator.get_config()
    ChaosCoordinator.configure(config)

    try do
      fun.()
    after
      # Reset to original config
      ChaosCoordinator.reset()
      ChaosCoordinator.configure(original)
    end
  end

  @doc """
  Runs a function with payment chaos enabled.

  Shorthand for `with_chaos(%{payment: config}, fun)`.

  ## Options

  - `:failure_rate` - Probability of payment failure (0.0 - 1.0)
  - `:decline_codes` - List of decline codes to use
  - `:decline_weights` - Map of code to weight for distribution

  ## Examples

      with_payment_chaos(%{failure_rate: 1.0}, fn ->
        # All payments fail with random decline code
      end)

      with_payment_chaos(%{
        failure_rate: 1.0,
        decline_codes: [:card_declined],
        decline_weights: %{card_declined: 1.0}
      }, fn ->
        # All payments fail with card_declined
      end)
  """
  @spec with_payment_chaos(map(), (-> any())) :: any()
  def with_payment_chaos(payment_config, fun) do
    with_chaos(%{payment: payment_config}, fun)
  end

  @doc """
  Runs a function with event chaos enabled.

  Shorthand for `with_chaos(%{events: config}, fun)`.

  ## Options

  - `:out_of_order` - Whether to shuffle events (boolean)
  - `:duplicate_rate` - Probability of duplicating events (0.0 - 1.0)
  - `:buffer_window_ms` - How long to buffer events before delivery

  ## Examples

      with_event_chaos(%{out_of_order: true, buffer_window_ms: 100}, fn ->
        # Events delivered in random order after 100ms buffer
      end)
  """
  @spec with_event_chaos(map(), (-> any())) :: any()
  def with_event_chaos(events_config, fun) do
    with_chaos(%{events: events_config}, fun)
  end

  @doc """
  Runs a function with API chaos enabled.

  Shorthand for `with_chaos(%{api: config}, fun)`.

  ## Options

  - `:timeout_rate` - Probability of request timeout (0.0 - 1.0)
  - `:timeout_ms` - How long to sleep before returning 504
  - `:rate_limit_rate` - Probability of 429 response
  - `:error_rate` - Probability of 500/502/503 response
  - `:endpoint_overrides` - Map of path to forced failure type

  ## Examples

      with_api_chaos(%{timeout_rate: 0.1}, fn ->
        # 10% of API calls timeout
      end)

      with_api_chaos(%{endpoint_overrides: %{"/v1/subscriptions" => :rate_limit}}, fn ->
        # Subscription endpoint always returns 429
      end)
  """
  @spec with_api_chaos(map(), (-> any())) :: any()
  def with_api_chaos(api_config, fun) do
    with_chaos(%{api: api_config}, fun)
  end

  @doc """
  Forces a specific customer's payments to fail.

  Useful for deterministic testing of failure handling.

  ## Examples

      force_payment_failure("cus_123", :card_declined)
      assert {:error, :card_declined} = charge_customer("cus_123")
  """
  @spec force_payment_failure(String.t(), atom()) :: :ok
  def force_payment_failure(customer_id, decline_code) do
    ChaosCoordinator.simulate_failure(customer_id, decline_code)
  end

  @doc """
  Clears a forced payment failure for a customer.
  """
  @spec clear_payment_failure(String.t()) :: :ok
  def clear_payment_failure(customer_id) do
    ChaosCoordinator.clear_simulation(customer_id)
  end

  @doc """
  Forces all buffered events to be delivered immediately.

  Call this after creating resources when event chaos is enabled
  to ensure events are delivered before making assertions.

  ## Examples

      with_event_chaos(%{out_of_order: true, buffer_window_ms: 1000}, fn ->
        create_subscription()
        flush_events()  # Don't wait 1000ms, deliver now
        assert_webhook_received()
      end)
  """
  @spec flush_events() :: :ok
  def flush_events do
    ChaosCoordinator.flush_events()
  end

  @doc """
  Gets chaos statistics.

  Useful for verifying that chaos was actually applied.

  ## Examples

      with_chaos(%{payment: %{failure_rate: 1.0}}, fn ->
        for _ <- 1..10, do: attempt_payment()
      end)

      stats = chaos_stats()
      assert stats.payments_failed == 10
  """
  @spec chaos_stats() :: map()
  def chaos_stats do
    ChaosCoordinator.get_stats()
  end

  @doc """
  Resets all chaos configuration and statistics.

  Typically called in test setup to ensure clean state.
  """
  @spec reset_chaos() :: :ok
  def reset_chaos do
    ChaosCoordinator.reset()
  end

  @doc """
  Cleans up after chaos testing.

  This resets chaos configuration AND flushes all Paper Tiger stores to remove
  any test data that was created during chaos testing. Call this after chaos
  testing to prevent test data from being synced to the host application's
  database.

  ## Examples

      # After running chaos tests in a script
      run_chaos_tests()
      cleanup_chaos()

      # In ExUnit tests, use in on_exit callback
      setup do
        on_exit(fn -> cleanup_chaos() end)
        :ok
      end
  """
  @spec cleanup_chaos() :: :ok
  def cleanup_chaos do
    ChaosCoordinator.cleanup()
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      import PaperTiger.ChaosHelpers
    end
  end
end
