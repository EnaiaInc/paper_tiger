defmodule PaperTiger.WebhookSignatureCompatibilityTest do
  use ExUnit.Case, async: false

  import PaperTiger.Test

  alias PaperTiger.Store.Events
  alias PaperTiger.Store.Webhooks
  alias PaperTiger.TestClient
  alias PaperTiger.WebhookDelivery
  alias PaperTiger.WebhookDelivery.Request
  alias PaperTiger.WebhookDelivery.Response

  @secret "whsec_signature_compat_secret"

  defmodule CapturingAdapter do
    @behaviour PaperTiger.WebhookDelivery.Adapter

    @impl true
    def deliver(%Request{} = request) do
      send(:persistent_term.get({__MODULE__, :pid}), {:signed_webhook_request, request})
      {:ok, %Response{body: "accepted", status: 202}}
    end
  end

  setup do
    PaperTiger.flush()

    previous_adapter = Application.get_env(:paper_tiger, :webhook_delivery_adapter)
    previous_mode = Application.get_env(:paper_tiger, :webhook_mode)
    previous_secret = Application.get_env(:stripity_stripe, :webhook_signing_key)

    Application.put_env(:stripity_stripe, :webhook_signing_key, @secret)
    :persistent_term.put({CapturingAdapter, :pid}, self())

    on_exit(fn ->
      restore_env(:paper_tiger, :webhook_delivery_adapter, previous_adapter)
      restore_env(:paper_tiger, :webhook_mode, previous_mode)
      restore_env(:stripity_stripe, :webhook_signing_key, previous_secret)
      :persistent_term.erase({CapturingAdapter, :pid})
    end)

    {:ok, event: event_fixture(), webhook: webhook_fixture()}
  end

  describe "signed request compatibility" do
    test "raw payload and signature verify through Stripity Stripe", %{event: event, webhook: webhook} do
      request = WebhookDelivery.build_signed_request(event, webhook)

      assert {"Stripe-Signature", request.signature_header} in request.headers
      assert {:ok, verified} = verify(request, @secret)
      assert verified["id"] == event.id
      assert verified["type"] == "charge.succeeded"
      assert verified["data"]["object"]["id"] == "ch_signature_compat"
    end

    test "Stripe-style headers accept any matching v1 signature", %{event: event, webhook: webhook} do
      request = WebhookDelivery.build_signed_request(event, webhook)
      valid_signature = request.signature_header |> String.split("v1=") |> List.last()
      bogus_signature = String.duplicate("0", 64)
      header = "t=#{request.timestamp},v1=#{bogus_signature},v1=#{valid_signature}"

      assert {:ok, verified} = Stripe.Webhook.construct_event(request.payload, header, @secret, response_as: :map)
      assert verified["id"] == event.id
    end

    test "modified payload fails verification", %{event: event, webhook: webhook} do
      request = WebhookDelivery.build_signed_request(event, webhook)

      assert {:error, reason} =
               Stripe.Webhook.construct_event(
                 request.payload <> "\n",
                 request.signature_header,
                 @secret,
                 response_as: :map
               )

      assert reason =~ "No signatures found matching"
    end

    test "wrong secret fails verification", %{event: event, webhook: webhook} do
      request = WebhookDelivery.build_signed_request(event, webhook)

      assert {:error, reason} = verify(request, "whsec_wrong_secret")
      assert reason =~ "No signatures found matching"
    end

    test "invalid signature fails verification", %{event: event, webhook: webhook} do
      request = WebhookDelivery.build_signed_request(event, webhook)
      header = "t=#{request.timestamp},v1=#{String.duplicate("f", 64)}"

      assert {:error, reason} =
               Stripe.Webhook.construct_event(request.payload, header, @secret, response_as: :map)

      assert reason =~ "No signatures found matching"
    end

    test "stale timestamp fails tolerance check", %{event: event, webhook: webhook} do
      stale_timestamp = System.system_time(:second) - 3600
      request = WebhookDelivery.build_signed_request(event, webhook, timestamp: stale_timestamp)

      assert {:error, reason} =
               Stripe.Webhook.construct_event(request.payload, request.signature_header, @secret, 300,
                 response_as: :map
               )

      assert reason =~ "Timestamp outside the tolerance zone"
    end
  end

  describe "delivery modes preserve signed bytes" do
    test "collection mode records a raw body and signature header" do
      enable_webhook_collection()

      {:ok, customer} = TestClient.create_customer(%{"email" => "signed-collect@example.com"})
      [delivery] = assert_webhook_delivered("customer.created")
      signed = signed_webhook_request(delivery)

      assert signed.body == delivery.payload
      assert {"Stripe-Signature", signed.signature_header} in signed.headers
      assert {:ok, verified} = verify(signed.body, signed.signature_header, @secret)
      assert verified["data"]["object"]["id"] == customer["id"]
    end

    test "sync adapter delivery hands off Stripe-verifiable bytes", %{event: event, webhook: webhook} do
      insert_delivery_fixture(event, webhook)
      Application.put_env(:paper_tiger, :webhook_delivery_adapter, CapturingAdapter)

      assert {:ok, :delivered} = WebhookDelivery.deliver_event_sync(event.id, webhook.id)
      assert_receive {:signed_webhook_request, %Request{} = request}, 2_000

      signed = signed_webhook_request(request)
      assert {:ok, verified} = verify(signed.body, signed.signature_header, @secret)
      assert verified["id"] == event.id
    end

    test "async adapter delivery hands off the same verifiable request shape", %{event: event, webhook: webhook} do
      insert_delivery_fixture(event, webhook)
      Application.put_env(:paper_tiger, :webhook_delivery_adapter, CapturingAdapter)

      assert {:ok, ref} = WebhookDelivery.deliver_event(event.id, webhook.id)
      assert is_reference(ref)
      assert_receive {:signed_webhook_request, %Request{} = request}, 2_000

      assert {:ok, verified} = verify(request, @secret)
      assert verified["id"] == event.id
    end
  end

  defp verify(%Request{} = request, secret) do
    verify(request.payload, request.signature_header, secret)
  end

  defp verify(body, signature_header, secret) do
    Stripe.Webhook.construct_event(body, signature_header, secret, response_as: :map)
  end

  defp insert_delivery_fixture(event, webhook) do
    {:ok, _} = Events.insert(event)
    {:ok, _} = Webhooks.insert(webhook)
  end

  defp event_fixture do
    %{
      api_version: "2023-10-16",
      created: PaperTiger.now(),
      data: %{
        object: %{
          amount: 4200,
          currency: "usd",
          id: "ch_signature_compat",
          object: "charge"
        }
      },
      delivery_attempts: [],
      id: "evt_signature_compat",
      livemode: false,
      object: "event",
      pending_webhooks: 0,
      request: %{id: nil, idempotency_key: nil},
      type: "charge.succeeded"
    }
  end

  defp webhook_fixture do
    %{
      created: PaperTiger.now(),
      enabled_events: ["charge.succeeded"],
      id: "we_signature_compat",
      metadata: %{},
      object: "webhook_endpoint",
      secret: @secret,
      status: "enabled",
      url: "http://127.0.0.1:1/signature-compat"
    }
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
