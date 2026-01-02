defmodule PaperTiger.ChaosCoordinatorTest do
  use ExUnit.Case, async: false

  alias PaperTiger.ChaosCoordinator

  setup do
    ChaosCoordinator.reset()
    :ok
  end

  describe "configuration" do
    test "starts with default config (no chaos)" do
      config = ChaosCoordinator.get_config()

      assert config.payment.failure_rate == 0.0
      assert config.events.out_of_order == false
      assert config.events.duplicate_rate == 0.0
      assert config.api.timeout_rate == 0.0
    end

    test "configure/1 merges with existing config" do
      ChaosCoordinator.configure(%{payment: %{failure_rate: 0.5}})
      config = ChaosCoordinator.get_config()

      assert config.payment.failure_rate == 0.5
      # Other defaults preserved
      assert config.events.out_of_order == false
    end

    test "configure/1 deep merges nested config" do
      ChaosCoordinator.configure(%{payment: %{failure_rate: 0.5}})
      ChaosCoordinator.configure(%{payment: %{decline_codes: [:card_declined]}})
      config = ChaosCoordinator.get_config()

      # Both settings preserved
      assert config.payment.failure_rate == 0.5
      assert config.payment.decline_codes == [:card_declined]
    end

    test "reset/0 clears all config and state" do
      ChaosCoordinator.configure(%{payment: %{failure_rate: 1.0}})
      ChaosCoordinator.simulate_failure("cus_123", :card_declined)

      ChaosCoordinator.reset()
      config = ChaosCoordinator.get_config()

      assert config.payment.failure_rate == 0.0
      assert {:ok, :succeed} = ChaosCoordinator.should_payment_fail?("cus_123")
    end
  end

  describe "payment chaos" do
    test "should_payment_fail?/1 returns succeed with no chaos" do
      assert {:ok, :succeed} = ChaosCoordinator.should_payment_fail?("cus_123")
    end

    test "should_payment_fail?/1 respects failure_rate" do
      ChaosCoordinator.configure(%{payment: %{failure_rate: 1.0}})

      assert {:ok, {:fail, _code}} = ChaosCoordinator.should_payment_fail?("cus_123")
    end

    test "should_payment_fail?/1 uses configured decline codes" do
      ChaosCoordinator.configure(%{
        payment: %{
          decline_codes: [:insufficient_funds],
          failure_rate: 1.0
        }
      })

      assert {:ok, {:fail, :insufficient_funds}} = ChaosCoordinator.should_payment_fail?("cus_123")
    end

    test "should_payment_fail?/1 uses decline_weights for distribution" do
      ChaosCoordinator.configure(%{
        payment: %{
          decline_codes: [:card_declined, :insufficient_funds],
          decline_weights: %{card_declined: 1.0, insufficient_funds: 0.0},
          failure_rate: 1.0
        }
      })

      # With weight 1.0 for card_declined and 0.0 for insufficient_funds,
      # should always be card_declined
      for _ <- 1..10 do
        assert {:ok, {:fail, :card_declined}} = ChaosCoordinator.should_payment_fail?("cus_123")
      end
    end

    test "simulate_failure/2 forces specific customer to fail" do
      ChaosCoordinator.simulate_failure("cus_123", :expired_card)

      assert {:ok, {:fail, :expired_card}} = ChaosCoordinator.should_payment_fail?("cus_123")
      # Other customers unaffected
      assert {:ok, :succeed} = ChaosCoordinator.should_payment_fail?("cus_456")
    end

    test "clear_simulation/1 removes forced failure" do
      ChaosCoordinator.simulate_failure("cus_123", :card_declined)
      ChaosCoordinator.clear_simulation("cus_123")

      assert {:ok, :succeed} = ChaosCoordinator.should_payment_fail?("cus_123")
    end

    test "customer override takes precedence over random chaos" do
      ChaosCoordinator.configure(%{payment: %{decline_codes: [:card_declined], failure_rate: 1.0}})
      ChaosCoordinator.simulate_failure("cus_123", :expired_card)

      # Override wins even with 100% random failure rate
      assert {:ok, {:fail, :expired_card}} = ChaosCoordinator.should_payment_fail?("cus_123")
    end

    test "tracks payment statistics" do
      ChaosCoordinator.configure(%{payment: %{failure_rate: 1.0}})

      for _ <- 1..5 do
        ChaosCoordinator.should_payment_fail?("cus_123")
      end

      stats = ChaosCoordinator.get_stats()
      assert stats.payments_failed == 5
    end
  end

  describe "event chaos" do
    test "queue_event/2 delivers immediately with no chaos" do
      delivered = :ets.new(:delivered, [:set, :public])
      deliver_fn = fn event -> :ets.insert(delivered, {event.id, event}) end

      event = %{id: "evt_123", type: "test.event"}
      ChaosCoordinator.queue_event(event, deliver_fn)

      # Give the cast a moment to process
      Process.sleep(10)

      # Should be delivered immediately
      assert [{_, ^event}] = :ets.lookup(delivered, "evt_123")
    end

    test "queue_event/2 buffers when buffer_window_ms is set" do
      delivered = :ets.new(:delivered, [:set, :public])
      deliver_fn = fn event -> :ets.insert(delivered, {event.id, event}) end

      ChaosCoordinator.configure(%{events: %{buffer_window_ms: 100}})

      event = %{id: "evt_123", type: "test.event"}
      ChaosCoordinator.queue_event(event, deliver_fn)

      # Not delivered yet
      assert [] = :ets.lookup(delivered, "evt_123")

      # Wait for buffer to flush
      Process.sleep(150)
      assert [{_, ^event}] = :ets.lookup(delivered, "evt_123")
    end

    test "flush_events/0 delivers buffered events immediately" do
      delivered = :ets.new(:delivered, [:set, :public])
      deliver_fn = fn event -> :ets.insert(delivered, {event.id, event}) end

      ChaosCoordinator.configure(%{events: %{buffer_window_ms: 10_000}})

      event = %{id: "evt_123", type: "test.event"}
      ChaosCoordinator.queue_event(event, deliver_fn)

      # Not delivered yet
      assert [] = :ets.lookup(delivered, "evt_123")

      # Force flush
      ChaosCoordinator.flush_events()
      assert [{_, ^event}] = :ets.lookup(delivered, "evt_123")
    end

    test "duplicate_rate causes some events to be delivered twice" do
      # Use a counter to track delivery count
      counter = :counters.new(1, [])
      deliver_fn = fn _event -> :counters.add(counter, 1, 1) end

      ChaosCoordinator.configure(%{events: %{duplicate_rate: 1.0}})

      event = %{id: "evt_123", type: "test.event"}
      ChaosCoordinator.queue_event(event, deliver_fn)

      # Give cast time to process
      Process.sleep(10)
      ChaosCoordinator.flush_events()

      # Should be delivered twice (100% duplicate rate)
      delivery_count = :counters.get(counter, 1)
      assert delivery_count == 2
    end

    test "out_of_order shuffles events" do
      delivered = :ets.new(:delivered, [:ordered_set, :public])
      counter = :counters.new(1, [])

      deliver_fn = fn event ->
        :counters.add(counter, 1, 1)
        order = :counters.get(counter, 1)
        :ets.insert(delivered, {order, event.id})
      end

      ChaosCoordinator.configure(%{events: %{buffer_window_ms: 50, out_of_order: true}})

      # Queue many events
      for i <- 1..20 do
        ChaosCoordinator.queue_event(%{id: "evt_#{i}", type: "test"}, deliver_fn)
      end

      # Give casts time to queue
      Process.sleep(20)
      ChaosCoordinator.flush_events()

      # Get delivery order
      delivery_order = :ets.tab2list(delivered) |> Enum.map(fn {_, id} -> id end)

      # With 20 events, extremely unlikely to be in original order
      original_order = for i <- 1..20, do: "evt_#{i}"
      assert delivery_order != original_order
    end

    test "tracks event chaos statistics" do
      ChaosCoordinator.configure(%{events: %{duplicate_rate: 1.0}})

      for i <- 1..3 do
        ChaosCoordinator.queue_event(%{id: "evt_#{i}"}, fn _ -> :ok end)
      end

      ChaosCoordinator.flush_events()

      stats = ChaosCoordinator.get_stats()
      assert stats.events_duplicated == 3
    end
  end

  describe "API chaos" do
    test "should_api_fail?/1 returns :ok with no chaos" do
      assert :ok = ChaosCoordinator.should_api_fail?("/v1/customers")
    end

    test "should_api_fail?/1 respects timeout_rate" do
      ChaosCoordinator.configure(%{api: %{timeout_ms: 100, timeout_rate: 1.0}})

      assert {:timeout, 100} = ChaosCoordinator.should_api_fail?("/v1/customers")
    end

    test "should_api_fail?/1 respects rate_limit_rate" do
      ChaosCoordinator.configure(%{api: %{rate_limit_rate: 1.0}})

      assert :rate_limit = ChaosCoordinator.should_api_fail?("/v1/customers")
    end

    test "should_api_fail?/1 respects error_rate" do
      ChaosCoordinator.configure(%{api: %{error_rate: 1.0}})

      assert :server_error = ChaosCoordinator.should_api_fail?("/v1/customers")
    end

    test "endpoint_overrides force specific endpoints to fail" do
      ChaosCoordinator.configure(%{
        api: %{
          endpoint_overrides: %{
            "/v1/subscriptions" => :rate_limit
          }
        }
      })

      assert :rate_limit = ChaosCoordinator.should_api_fail?("/v1/subscriptions")
      assert :ok = ChaosCoordinator.should_api_fail?("/v1/customers")
    end

    test "tracks API chaos statistics" do
      ChaosCoordinator.configure(%{api: %{timeout_rate: 1.0}})

      for _ <- 1..3 do
        ChaosCoordinator.should_api_fail?("/v1/test")
      end

      stats = ChaosCoordinator.get_stats()
      assert stats.api_timeouts == 3
    end
  end

  describe "decline codes" do
    test "all_decline_codes/0 returns all available codes" do
      codes = ChaosCoordinator.all_decline_codes()

      assert :card_declined in codes
      assert :insufficient_funds in codes
      assert :expired_card in codes
      assert :fraudulent in codes
      assert :authentication_required in codes
      assert length(codes) >= 20
    end

    test "default_decline_codes/0 returns basic codes" do
      codes = ChaosCoordinator.default_decline_codes()

      assert :card_declined in codes
      assert :insufficient_funds in codes
      assert :expired_card in codes
      assert :processing_error in codes
      assert length(codes) == 4
    end

    test "simulate_failure/2 rejects invalid decline codes" do
      assert_raise ArgumentError, ~r/Invalid decline code/, fn ->
        ChaosCoordinator.simulate_failure("cus_123", :not_a_real_code)
      end
    end
  end
end
