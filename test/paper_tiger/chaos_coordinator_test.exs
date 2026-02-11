defmodule PaperTiger.ChaosCoordinatorTest do
  use ExUnit.Case, async: false

  alias PaperTiger.ChaosCoordinator
  alias PaperTiger.Router

  setup do
    ChaosCoordinator.reset()
    :ok
  end

  defp request(method, path, params) do
    conn =
      Plug.Test.conn(method, path, params)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer sk_test_mock")

    Router.call(conn, [])
  end

  defp json_response(conn) do
    Jason.decode!(conn.resp_body)
  end

  describe "configuration" do
    test "starts with default config (no chaos)" do
      config = ChaosCoordinator.get_config()

      assert config.payment.failure_rate == 0.0
      assert config.events.out_of_order == false
      assert config.events.duplicate_rate == 0.0
      assert config.api.timeout_rate == 0.0
    end

    test "configuration is isolated per namespace" do
      # Simulate two concurrent sandboxes by setting the namespace in the process dictionary.
      # Each sandbox should have independent chaos configuration.
      Process.put(:paper_tiger_namespace, :ns_b)
      ChaosCoordinator.reset()

      task =
        Task.async(fn ->
          Process.put(:paper_tiger_namespace, :ns_a)
          ChaosCoordinator.reset()
          ChaosCoordinator.configure(%{api: %{rate_limit_rate: 1.0}})
          ChaosCoordinator.get_config()
        end)

      config_a = Task.await(task)
      assert config_a.api.rate_limit_rate == 1.0

      # Namespace B should remain at defaults.
      Process.put(:paper_tiger_namespace, :ns_b)
      config_b = ChaosCoordinator.get_config()
      assert config_b.api.rate_limit_rate == 0.0
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
      test_pid = self()

      event = %{id: "evt_123", type: "test.event"}

      ChaosCoordinator.queue_event(event, fn evt ->
        send(test_pid, {:delivered, evt})
      end)

      # Should be delivered almost immediately (no buffering)
      assert_receive {:delivered, ^event}, 100
    end

    test "queue_event/2 buffers when buffer_window_ms is set" do
      test_pid = self()

      # Use a longer buffer window and message-based notification
      ChaosCoordinator.configure(%{events: %{buffer_window_ms: 50}})

      event = %{id: "evt_buf_test", type: "test.event"}

      ChaosCoordinator.queue_event(event, fn evt ->
        send(test_pid, {:delivered, evt})
      end)

      # Ensure cast is processed by making a synchronous call
      _ = ChaosCoordinator.get_config()

      # Should NOT be delivered yet - refute any immediate delivery
      refute_receive {:delivered, _}, 10

      # Now wait for the buffer to actually flush (50ms + some margin)
      # Use assert_receive with a timeout that's long enough
      assert_receive {:delivered, ^event}, 200
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
      test_pid = self()

      ChaosCoordinator.configure(%{events: %{duplicate_rate: 1.0}})

      event = %{id: "evt_123", type: "test.event"}

      ChaosCoordinator.queue_event(event, fn evt ->
        send(test_pid, {:delivered, evt})
      end)

      # Should receive the event twice (100% duplicate rate, immediate delivery)
      assert_receive {:delivered, ^event}, 100
      assert_receive {:delivered, ^event}, 100
    end

    test "out_of_order shuffles events" do
      test_pid = self()
      counter = :counters.new(1, [])

      ChaosCoordinator.configure(%{events: %{buffer_window_ms: 5000, out_of_order: true}})

      # Queue many events (buffer_window is long, so they'll accumulate)
      for i <- 1..20 do
        ChaosCoordinator.queue_event(%{id: "evt_#{i}", type: "test"}, fn event ->
          :counters.add(counter, 1, 1)
          order = :counters.get(counter, 1)
          send(test_pid, {:delivered, order, event.id})
        end)
      end

      # Ensure all casts are queued by making a sync call
      _ = ChaosCoordinator.get_config()

      # Force flush (don't wait for timer)
      ChaosCoordinator.flush_events()

      # Collect all deliveries
      delivery_order =
        for _ <- 1..20 do
          assert_receive {:delivered, _order, event_id}, 100
          event_id
        end

      # With 20 events, extremely unlikely to be in original order after shuffle
      original_order = for i <- 1..20, do: "evt_#{i}"
      assert delivery_order != original_order
    end

    test "tracks event chaos statistics" do
      test_pid = self()

      ChaosCoordinator.configure(%{events: %{duplicate_rate: 1.0}})

      for i <- 1..3 do
        ChaosCoordinator.queue_event(%{id: "evt_#{i}"}, fn evt ->
          send(test_pid, {:delivered, evt.id})
        end)
      end

      # Wait for all deliveries (3 events × 2 each = 6 messages)
      for _ <- 1..6, do: assert_receive({:delivered, _}, 100)

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

    test "endpoint_overrides support custom response bodies" do
      custom_body = %{"id" => "sub_test", "object" => "subscription", "status" => "past_due"}

      ChaosCoordinator.configure(%{
        api: %{
          endpoint_overrides: %{
            "/v1/subscriptions/sub_test" => {:custom_response, 200, custom_body}
          }
        }
      })

      assert {:custom_response, 200, ^custom_body} =
               ChaosCoordinator.should_api_fail?("/v1/subscriptions/sub_test")

      # Other endpoints unaffected
      assert :ok = ChaosCoordinator.should_api_fail?("/v1/customers")
    end

    test "custom response works through HTTP" do
      custom_body = %{"email" => "fake@test.com", "id" => "cus_fake", "object" => "customer"}

      ChaosCoordinator.configure(%{
        api: %{
          endpoint_overrides: %{
            "/v1/customers/cus_fake" => {:custom_response, 200, custom_body}
          }
        }
      })

      conn = request(:get, "/v1/customers/cus_fake", %{})
      assert conn.status == 200
      response = json_response(conn)
      assert response["id"] == "cus_fake"
      assert response["email"] == "fake@test.com"
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
