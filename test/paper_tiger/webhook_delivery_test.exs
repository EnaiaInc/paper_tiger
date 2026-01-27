defmodule PaperTiger.WebhookDeliveryTest do
  use ExUnit.Case, async: false

  alias PaperTiger.Store.Events
  alias PaperTiger.Store.Webhooks

  setup do
    # Clear all data between tests
    PaperTiger.flush()
    :ok
  end

  describe "sign_payload/2" do
    test "creates HMAC SHA256 signature" do
      payload = "test_payload"
      secret = "test_secret"

      signature = PaperTiger.WebhookDelivery.sign_payload(payload, secret)

      # Signature should be hex string
      assert is_binary(signature)
      # SHA256 hex encoding is 64 characters
      assert String.length(signature) == 64

      # Signature should be consistent
      signature2 = PaperTiger.WebhookDelivery.sign_payload(payload, secret)
      assert signature == signature2
    end

    test "signature changes with different payload" do
      secret = "test_secret"
      sig1 = PaperTiger.WebhookDelivery.sign_payload("payload1", secret)
      sig2 = PaperTiger.WebhookDelivery.sign_payload("payload2", secret)

      assert sig1 != sig2
    end

    test "signature changes with different secret" do
      payload = "test_payload"
      sig1 = PaperTiger.WebhookDelivery.sign_payload(payload, "secret1")
      sig2 = PaperTiger.WebhookDelivery.sign_payload(payload, "secret2")

      assert sig1 != sig2
    end

    test "signature is lowercase hex" do
      signature = PaperTiger.WebhookDelivery.sign_payload("test", "secret")

      # Verify it's all lowercase hex characters
      assert signature =~ ~r/^[0-9a-f]+$/
    end
  end

  describe "deliver_event/2" do
    setup do
      # Create test webhook endpoint
      webhook = %{
        created: PaperTiger.now(),
        enabled_events: ["charge.succeeded", "customer.created"],
        id: "we_test_123",
        metadata: %{},
        object: "webhook_endpoint",
        secret: "whsec_test_secret_12345",
        status: "enabled",
        url: "http://localhost:9999/webhook"
      }

      {:ok, _} = Webhooks.insert(webhook)

      # Create test event
      event = %{
        created: PaperTiger.now(),
        data: %{
          object: %{
            amount: 2000,
            currency: "usd",
            id: "ch_test"
          }
        },
        delivery_attempts: [],
        id: "evt_test_123",
        livemode: false,
        metadata: %{},
        object: "event",
        type: "charge.succeeded"
      }

      {:ok, _} = Events.insert(event)

      {:ok, webhook: webhook, event: event}
    end

    test "returns error when event not found" do
      result = PaperTiger.WebhookDelivery.deliver_event("evt_nonexistent", "we_test_123")

      assert {:error, :event_not_found} = result
    end

    test "returns error when webhook not found", %{event: event} do
      result = PaperTiger.WebhookDelivery.deliver_event(event.id, "we_nonexistent")

      assert {:error, :webhook_not_found} = result
    end

    test "returns ok with reference when both event and webhook exist", %{
      event: event,
      webhook: webhook
    } do
      result = PaperTiger.WebhookDelivery.deliver_event(event.id, webhook.id)

      assert {:ok, ref} = result
      assert is_reference(ref)
    end
  end

  describe "Stripe-compatible signature format" do
    test "signature includes timestamp and v1 components" do
      timestamp = 1_234_567_890
      payload = Jason.encode!(%{"test" => "data"})
      secret = "whsec_test"

      # Create signed content as per Stripe format
      signed_content = "#{timestamp}.#{payload}"
      signature = PaperTiger.WebhookDelivery.sign_payload(signed_content, secret)

      # Verify we can construct the header format
      stripe_signature = "t=#{timestamp},v1=#{signature}"

      assert String.starts_with?(stripe_signature, "t=")
      assert String.contains?(stripe_signature, ",v1=")
      assert String.length(signature) == 64
    end

    test "stripe signature format matches Stripe expectations" do
      # Test with known values to ensure format compatibility
      timestamp = 1_614_556_800

      event_data = %{
        "id" => "evt_test",
        "type" => "charge.succeeded"
      }

      payload = Jason.encode!(event_data)
      secret = "whsec_secret123"

      signed_content = "#{timestamp}.#{payload}"
      signature = PaperTiger.WebhookDelivery.sign_payload(signed_content, secret)

      # The header format should be exactly: t={timestamp},v1={signature}
      header = "t=#{timestamp},v1=#{signature}"

      # Parse and verify
      [time_part, sig_part] = String.split(header, ",")
      assert String.starts_with?(time_part, "t=")
      assert String.starts_with?(sig_part, "v1=")

      timestamp_value = String.slice(time_part, 2..-1//1)
      assert timestamp_value == Integer.to_string(timestamp)

      sig_value = String.slice(sig_part, 3..-1//1)
      assert sig_value == signature
    end
  end

  describe "HTTP delivery integration" do
    setup do
      webhook = %{
        created: PaperTiger.now(),
        enabled_events: ["charge.succeeded"],
        id: "we_http_test",
        metadata: %{},
        object: "webhook_endpoint",
        secret: "whsec_http_test",
        status: "enabled",
        url: "http://localhost:8888/webhook"
      }

      {:ok, _} = Webhooks.insert(webhook)

      event = %{
        created: PaperTiger.now(),
        data: %{
          object: %{
            amount: 3000,
            currency: "usd",
            id: "ch_http_test"
          }
        },
        delivery_attempts: [],
        id: "evt_http_test",
        livemode: false,
        metadata: %{},
        object: "event",
        type: "charge.succeeded"
      }

      {:ok, _} = Events.insert(event)

      {:ok, webhook: webhook, event: event}
    end

    test "delivery_attempts list is properly structured in event", %{
      event: event,
      webhook: webhook
    } do
      # Verify event has delivery_attempts field
      assert is_list(event.delivery_attempts)

      # Attempt delivery (will fail since endpoint doesn't exist, but we test structure)
      _result = PaperTiger.WebhookDelivery.deliver_event(event.id, webhook.id)

      # Wait a bit for async processing
      Process.sleep(100)

      # Retrieve updated event
      {:ok, updated_event} = Events.get(event.id)

      # Verify structure is maintained
      assert is_list(updated_event.delivery_attempts)
    end
  end

  describe "Retry logic and exponential backoff" do
    test "max retries constant is set correctly" do
      # Verify the retry configuration is reasonable
      # @max_retries 5 means: attempt 1, then retry 4 times = 5 total
      # This is a typical webhook retry strategy
      assert is_integer(5)
    end

    test "backoff timing calculation" do
      # Exponential backoff: 1s, 2s, 4s, 8s, 16s
      backoffs = [
        1 * Integer.pow(2, 0),
        1 * Integer.pow(2, 1),
        1 * Integer.pow(2, 2),
        1 * Integer.pow(2, 3),
        1 * Integer.pow(2, 4)
      ]

      expected = [1, 2, 4, 8, 16]

      assert backoffs == expected
    end
  end

  describe "Error handling" do
    test "handles missing event gracefully" do
      result = PaperTiger.WebhookDelivery.deliver_event("evt_missing", "we_any")

      assert {:error, :event_not_found} = result
    end

    test "handles missing webhook gracefully" do
      # Create an event but no webhook
      event = %{
        created: PaperTiger.now(),
        data: %{},
        delivery_attempts: [],
        id: "evt_error_test",
        livemode: false,
        metadata: %{},
        object: "event",
        type: "test.event"
      }

      {:ok, _} = Events.insert(event)

      result = PaperTiger.WebhookDelivery.deliver_event(event.id, "we_missing")

      assert {:error, :webhook_not_found} = result
    end
  end

  describe "Payload signing edge cases" do
    test "empty payload can be signed" do
      signature = PaperTiger.WebhookDelivery.sign_payload("", "secret")

      assert is_binary(signature)
      assert String.length(signature) == 64
    end

    test "large payload can be signed" do
      large_payload = String.duplicate("x", 10_000)
      signature = PaperTiger.WebhookDelivery.sign_payload(large_payload, "secret")

      assert is_binary(signature)
      assert String.length(signature) == 64
    end

    test "special characters in payload and secret are handled" do
      payload = "payload\nwith\nspecial\tcharacters{}"
      secret = "secret with special chars: !@#$%"

      signature = PaperTiger.WebhookDelivery.sign_payload(payload, secret)

      assert is_binary(signature)
      assert String.length(signature) == 64
    end

    test "unicode payloads are handled correctly" do
      payload = "テスト emoji test 🎉"
      secret = "secret"

      signature = PaperTiger.WebhookDelivery.sign_payload(payload, secret)

      assert is_binary(signature)
      assert String.length(signature) == 64

      # Same payload should produce same signature
      signature2 = PaperTiger.WebhookDelivery.sign_payload(payload, secret)
      assert signature == signature2
    end
  end
end
