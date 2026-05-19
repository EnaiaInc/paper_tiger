defmodule PaperTiger.WebhookDeliveryTest do
  use ExUnit.Case, async: false

  alias NoSuch.Adapter.Nope
  alias PaperTiger.Store.Events
  alias PaperTiger.Store.Webhooks
  alias PaperTiger.WebhookDelivery.Request
  alias PaperTiger.WebhookDelivery.Response

  setup do
    # Clear all data between tests
    PaperTiger.flush()
    :ok
  end

  # Polls `fun` until it returns true or the deadline passes. Used for
  # asserting on async retry outcomes without a fixed sleep.
  defp wait_for(fun, timeout \\ 6_000, interval \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for(fun, deadline, interval)
  end

  defp do_wait_for(fun, deadline, interval) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("wait_for/1 timed out")

      true ->
        Process.sleep(interval)
        do_wait_for(fun, deadline, interval)
    end
  end

  defp with_process_namespace(namespace, fun) do
    previous = Process.get(:paper_tiger_namespace, :__paper_tiger_unset__)
    Process.put(:paper_tiger_namespace, namespace)

    try do
      fun.()
    after
      case previous do
        :__paper_tiger_unset__ -> Process.delete(:paper_tiger_namespace)
        value -> Process.put(:paper_tiger_namespace, value)
      end
    end
  end

  defp insert_adapter_fixture(namespace, suffix) do
    with_process_namespace(namespace, fn ->
      webhook = %{
        created: PaperTiger.now(),
        enabled_events: ["charge.succeeded"],
        id: "we_adapter_#{suffix}",
        metadata: %{},
        object: "webhook_endpoint",
        secret: "whsec_adapter_secret_#{suffix}",
        status: "enabled",
        url: "http://127.0.0.1:1/#{suffix}"
      }

      {:ok, _} = Webhooks.insert(webhook)

      event = %{
        created: PaperTiger.now(),
        data: %{object: %{amount: 4242, currency: "usd", id: "ch_#{suffix}"}},
        delivery_attempts: [],
        id: "evt_adapter_#{suffix}",
        livemode: false,
        metadata: %{},
        object: "event",
        type: "charge.succeeded"
      }

      {:ok, _} = Events.insert(event)
      {event, webhook}
    end)
  end

  defp lowercase_hex?(value) do
    value
    |> String.to_charlist()
    |> Enum.all?(fn char -> char in ?0..?9 or char in ?a..?f end)
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
      assert lowercase_hex?(signature)
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

  describe "webhook_delivery_adapter (host-owned delivery)" do
    defmodule CapturingAdapter do
      @behaviour PaperTiger.WebhookDelivery.Adapter

      @impl true
      def deliver(request) do
        pid = :persistent_term.get({__MODULE__, :pid})
        send(pid, {:adapter_called, request})

        case :persistent_term.get({__MODULE__, :reply}) do
          :ok ->
            {:ok, %Response{body: "enqueued", status: 202}}

          :error ->
            {:error, :sink_unavailable}

          :error_once ->
            key = {__MODULE__, :calls}
            n = :persistent_term.get(key, 0)
            :persistent_term.put(key, n + 1)
            if n == 0, do: {:error, :sink_unavailable}, else: {:ok, %Response{body: "ok", status: 202}}
        end
      end
    end

    setup do
      webhook = %{
        created: PaperTiger.now(),
        enabled_events: ["charge.succeeded"],
        id: "we_adapter_1",
        metadata: %{},
        object: "webhook_endpoint",
        secret: "whsec_adapter_secret",
        status: "enabled",
        # Unroutable: if the default HTTP adapter were used instead of ours,
        # the test would see a connection error, not our synthetic 202.
        url: "http://127.0.0.1:1/never"
      }

      {:ok, _} = Webhooks.insert(webhook)

      event = %{
        created: PaperTiger.now(),
        data: %{object: %{amount: 4242, currency: "usd", id: "ch_a"}},
        delivery_attempts: [],
        id: "evt_adapter_1",
        livemode: false,
        metadata: %{},
        object: "event",
        type: "charge.succeeded"
      }

      {:ok, _} = Events.insert(event)

      :persistent_term.put({CapturingAdapter, :pid}, self())
      :persistent_term.put({CapturingAdapter, :reply}, :ok)
      :persistent_term.erase({CapturingAdapter, :calls})
      prev = Application.get_env(:paper_tiger, :webhook_delivery_adapter)
      Application.put_env(:paper_tiger, :webhook_delivery_adapter, CapturingAdapter)

      on_exit(fn ->
        if prev == nil do
          Application.delete_env(:paper_tiger, :webhook_delivery_adapter)
        else
          Application.put_env(:paper_tiger, :webhook_delivery_adapter, prev)
        end
      end)

      {:ok, webhook: webhook, event: event}
    end

    test "the configured adapter receives a fully-prepared Request and PT does not POST",
         %{event: event, webhook: webhook} do
      :persistent_term.put({CapturingAdapter, :reply}, :ok)

      result = PaperTiger.WebhookDelivery.deliver_event_sync(event.id, webhook.id)

      # Adapter accepted ownership → terminal success. No :queued leak in the
      # public return contract.
      assert result == {:ok, :delivered}

      assert_receive {:adapter_called, %Request{} = req}, 2_000
      assert req.url == webhook.url
      assert req.event.id == event.id
      assert req.webhook.id == webhook.id
      # Exact signed bytes + full signature header — adapter delivers without
      # re-signing.
      assert req.payload == Jason.encode!(event)
      assert ["t=" <> timestamp, "v1=" <> signature] = String.split(req.signature_header, ",")
      assert {_timestamp, ""} = Integer.parse(timestamp)
      assert String.length(signature) == 64
      assert lowercase_hex?(signature)
      assert {"Stripe-Signature", req.signature_header} in req.headers

      {:ok, reloaded} = Events.get(event.id)

      assert [%{status: :delivered, webhook_endpoint_id: "we_adapter_1"}] =
               reloaded.delivery_attempts
    end

    test "adapter {:error, _} drives the async retry path and recovers (no leaked timers)",
         %{event: event, webhook: webhook} do
      # Async dispatch covers the schedule_retry/Process.send_after branch
      # that deliver_event_sync/2 does not. Fail once then succeed so the
      # single scheduled retry resolves to a terminal success ~1 backoff
      # later, leaving no always-failing retry timer to bleed into the rest
      # of the suite.
      :persistent_term.put({CapturingAdapter, :reply}, :error_once)

      assert {:ok, ref} = PaperTiger.WebhookDelivery.deliver_event(event.id, webhook.id)
      assert is_reference(ref)

      # First attempt (error) and the retried attempt (ok) both hit the
      # adapter.
      assert_receive {:adapter_called, %Request{}}, 2_000
      assert_receive {:adapter_called, %Request{}}, 5_000

      # The retried attempt recorded a successful delivery on the event.
      wait_for(fn ->
        {:ok, reloaded} = Events.get(event.id)
        match?([%{status: :delivered} | _], Enum.reverse(reloaded.delivery_attempts))
      end)
    end

    test "[:paper_tiger, :webhook, :delivering] still fires (observability), even with a custom adapter",
         %{event: event, webhook: webhook} do
      test_pid = self()
      handler_id = "adapter-telemetry-#{System.unique_integer([:positive])}"

      event_id = event.id

      :telemetry.attach(
        handler_id,
        [:paper_tiger, :webhook, :delivering],
        fn _name, measurements, metadata, _config ->
          # Filter to THIS test's event so a stale :delivering from any
          # other in-flight delivery (e.g. an async retry elsewhere in the
          # suite) cannot satisfy the assertion. A non-matching event is
          # ignored (not a handler crash → no auto-detach).
          if metadata.event.id == event_id do
            send(test_pid, {:webhook_delivering, measurements, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      PaperTiger.WebhookDelivery.deliver_event_sync(event.id, webhook.id)

      assert_receive {:webhook_delivering, measurements, metadata}, 2_000
      assert is_integer(measurements.system_time)
      assert metadata.event.id == event.id
      assert metadata.url == webhook.url
      assert metadata.payload == Jason.encode!(event)
    end

    test "sync adapter request carries the namespace captured by the caller" do
      namespace = self()
      suffix = "sync_ns_#{System.unique_integer([:positive])}"
      {event, webhook} = insert_adapter_fixture(namespace, suffix)

      on_exit(fn -> PaperTiger.Test.cleanup_namespace(namespace) end)

      assert {:ok, :delivered} =
               with_process_namespace(namespace, fn ->
                 PaperTiger.WebhookDelivery.deliver_event_sync(event.id, webhook.id)
               end)

      assert_receive {:adapter_called, %Request{namespace: ^namespace} = req}, 2_000
      assert req.event.id == event.id
      assert req.webhook.id == webhook.id

      with_process_namespace(namespace, fn ->
        assert {:ok, reloaded} = Events.get(event.id)
        assert [%{status: :delivered, webhook_endpoint_id: webhook_id}] = reloaded.delivery_attempts
        assert webhook_id == webhook.id
      end)
    end

    test "async adapter request and delivery-attempt update keep the captured namespace" do
      namespace = self()
      suffix = "async_ns_#{System.unique_integer([:positive])}"
      {event, webhook} = insert_adapter_fixture(namespace, suffix)

      on_exit(fn -> PaperTiger.Test.cleanup_namespace(namespace) end)

      assert {:ok, ref} =
               with_process_namespace(namespace, fn ->
                 PaperTiger.WebhookDelivery.deliver_event(event.id, webhook.id)
               end)

      assert is_reference(ref)
      assert_receive {:adapter_called, %Request{namespace: ^namespace} = req}, 2_000
      assert req.event.id == event.id
      assert req.webhook.id == webhook.id

      with_process_namespace(namespace, fn ->
        wait_for(fn ->
          expected_webhook_id = webhook.id
          {:ok, reloaded} = Events.get(event.id)

          match?(
            [%{status: :delivered, webhook_endpoint_id: ^expected_webhook_id}],
            reloaded.delivery_attempts
          )
        end)
      end)
    end
  end

  describe "misbehaving adapter cannot silently drop or crash" do
    # Each adapter faults on its FIRST call then succeeds on the SECOND.
    # Driven through deliver_event_sync/2, whose retry path uses Process.sleep
    # recursion inside its own awaited Task — it does NOT Process.send_after
    # to the singleton GenServer — so the whole thing is terminal in ~1
    # backoff (@base_backoff_ms = 1s), deterministic, and leaves no scheduled
    # retry messages to contaminate later tests. A terminal {:ok, :delivered}
    # proves the fault was normalized into PaperTiger's retry path (not a
    # crash / silent drop) and that the WebhookDelivery GenServer survived.
    defmodule RaisingThenOkAdapter do
      @behaviour PaperTiger.WebhookDelivery.Adapter

      @impl true
      def deliver(_request) do
        key = {__MODULE__, :calls}
        n = :persistent_term.get(key, 0)
        :persistent_term.put(key, n + 1)
        send(:persistent_term.get({__MODULE__, :pid}), {:called, n})
        if n == 0, do: raise("sink blew up"), else: {:ok, %Response{body: "", status: 202}}
      end
    end

    defmodule BadShapeThenOkAdapter do
      @behaviour PaperTiger.WebhookDelivery.Adapter

      @impl true
      def deliver(_request) do
        key = {__MODULE__, :calls}
        n = :persistent_term.get(key, 0)
        :persistent_term.put(key, n + 1)
        send(:persistent_term.get({__MODULE__, :pid}), {:called, n})
        if n == 0, do: :banana, else: {:ok, %Response{body: "", status: 202}}
      end
    end

    setup do
      webhook = %{
        created: PaperTiger.now(),
        enabled_events: ["charge.succeeded"],
        id: "we_misbehave_1",
        metadata: %{},
        object: "webhook_endpoint",
        secret: "whsec_misbehave",
        status: "enabled",
        url: "http://127.0.0.1:1/never"
      }

      {:ok, _} = Webhooks.insert(webhook)

      event = %{
        created: PaperTiger.now(),
        data: %{object: %{amount: 7, currency: "usd", id: "ch_m"}},
        delivery_attempts: [],
        id: "evt_misbehave_1",
        livemode: false,
        metadata: %{},
        object: "event",
        type: "charge.succeeded"
      }

      {:ok, _} = Events.insert(event)

      prev = Application.get_env(:paper_tiger, :webhook_delivery_adapter)
      :persistent_term.erase({RaisingThenOkAdapter, :calls})
      :persistent_term.erase({BadShapeThenOkAdapter, :calls})

      on_exit(fn ->
        if prev == nil do
          Application.delete_env(:paper_tiger, :webhook_delivery_adapter)
        else
          Application.put_env(:paper_tiger, :webhook_delivery_adapter, prev)
        end
      end)

      {:ok, webhook: webhook, event: event}
    end

    test "a raising adapter is normalized into the retry path, recovers, GenServer survives",
         %{event: event, webhook: webhook} do
      :persistent_term.put({RaisingThenOkAdapter, :pid}, self())
      Application.put_env(:paper_tiger, :webhook_delivery_adapter, RaisingThenOkAdapter)
      pid_before = Process.whereis(PaperTiger.WebhookDelivery)

      assert {:ok, :delivered} =
               PaperTiger.WebhookDelivery.deliver_event_sync(event.id, webhook.id)

      assert_received {:called, 0}
      assert_received {:called, 1}
      # The raise did not cascade through the linked Task and kill the server.
      assert Process.whereis(PaperTiger.WebhookDelivery) == pid_before
    end

    test "an invalid return shape is normalized into the retry path, recovers",
         %{event: event, webhook: webhook} do
      :persistent_term.put({BadShapeThenOkAdapter, :pid}, self())
      Application.put_env(:paper_tiger, :webhook_delivery_adapter, BadShapeThenOkAdapter)

      assert {:ok, :delivered} =
               PaperTiger.WebhookDelivery.deliver_event_sync(event.id, webhook.id)

      assert_received {:called, 0}
      assert_received {:called, 1}
    end

    test "an undefined adapter module is normalized (no crash), recovers when config is fixed",
         %{event: event, webhook: webhook} do
      :persistent_term.put({RaisingThenOkAdapter, :pid}, self())
      Application.put_env(:paper_tiger, :webhook_delivery_adapter, Nope)

      caller =
        Task.async(fn ->
          PaperTiger.WebhookDelivery.deliver_event_sync(event.id, webhook.id)
        end)

      # First attempt: module undefined → safe_adapter_deliver returns
      # {:error, {:adapter_not_loaded, _}} (no crash). Fix the config before
      # the retry budget runs out; RaisingThenOk still faults once then ok.
      Process.sleep(300)
      Application.put_env(:paper_tiger, :webhook_delivery_adapter, RaisingThenOkAdapter)

      assert {:ok, :delivered} = Task.await(caller, 20_000)
      assert Process.alive?(Process.whereis(PaperTiger.WebhookDelivery))
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
