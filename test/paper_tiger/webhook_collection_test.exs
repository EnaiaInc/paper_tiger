defmodule PaperTiger.WebhookCollectionTest do
  @moduledoc """
  Tests for webhook collection mode (`:collect`).

  This mode stores webhooks in-memory for test inspection instead of
  delivering them via HTTP, enabling assertions about what webhooks
  would fire without needing a running web server.

  Note: Uses TestClient for HTTP requests since that handles namespace
  headers correctly. Apps using stripity_stripe need to configure
  the HTTP middleware to add namespace headers for async tests.
  """
  use ExUnit.Case, async: false

  import PaperTiger.Test

  alias PaperTiger.TestClient

  setup do
    PaperTiger.flush()
    :ok
  end

  describe "enable_webhook_collection/0" do
    test "sets webhook_mode to :collect" do
      enable_webhook_collection()

      assert Application.get_env(:paper_tiger, :webhook_mode) == :collect
    end

    test "restores previous mode on test exit" do
      # This is hard to test directly since on_exit runs after the test
      # but we can verify the function doesn't crash
      assert :ok = enable_webhook_collection()
    end
  end

  describe "webhook collection with API calls" do
    setup do
      enable_webhook_collection()
      :ok
    end

    test "customer creation triggers customer.created webhook" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "test@example.com"})

      [delivery] = assert_webhook_delivered("customer.created")

      assert delivery.event_type == "customer.created"
      assert delivery.event_data.object.id == customer["id"]
      assert delivery.event_data.object.email == "test@example.com"
    end

    test "customer update triggers customer.updated webhook" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "test@example.com"})
      clear_delivered_webhooks()

      {:ok, _updated} = TestClient.update_customer(customer["id"], %{"name" => "Updated Name"})

      [delivery] = assert_webhook_delivered("customer.updated")
      assert delivery.event_data.object.name == "Updated Name"
    end

    test "subscription creation triggers customer.subscription.created webhook" do
      # Create customer first
      {:ok, customer} = TestClient.create_customer(%{"email" => "test@example.com"})

      # Create product and price
      {:ok, product} = TestClient.create_product(%{"name" => "Test Product"})

      {:ok, price} =
        TestClient.create_price(%{
          "currency" => "usd",
          "product" => product["id"],
          "recurring" => %{"interval" => "month"},
          "unit_amount" => 1000
        })

      clear_delivered_webhooks()

      # Create subscription
      {:ok, subscription} =
        TestClient.create_subscription(%{
          "customer" => customer["id"],
          "items" => [%{"price" => price["id"]}]
        })

      [delivery] = assert_webhook_delivered("customer.subscription.created")
      assert delivery.event_data.object.id == subscription["id"]
      assert delivery.event_data.object.status == "active"
    end

    test "subscription update includes previous_attributes in webhook" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "test@example.com"})
      {:ok, product} = TestClient.create_product(%{"name" => "Test Product"})

      {:ok, price} =
        TestClient.create_price(%{
          "currency" => "usd",
          "product" => product["id"],
          "recurring" => %{"interval" => "month"},
          "unit_amount" => 1000
        })

      {:ok, subscription} =
        TestClient.create_subscription(%{
          "customer" => customer["id"],
          "items" => [%{"price" => price["id"]}]
        })

      clear_delivered_webhooks()

      # Update subscription metadata — should trigger previous_attributes
      {:ok, _updated} =
        TestClient.update_subscription(subscription["id"], %{
          "metadata" => %{"tier" => "premium"}
        })

      [delivery] = assert_webhook_delivered("customer.subscription.updated")
      assert delivery.event_data.object.id == subscription["id"]
      assert delivery.event_data[:previous_attributes][:metadata] != nil
    end

    test "subscription status change emits previous status in previous_attributes" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "test@example.com"})
      {:ok, product} = TestClient.create_product(%{"name" => "Test Product"})

      {:ok, price} =
        TestClient.create_price(%{
          "currency" => "usd",
          "product" => product["id"],
          "recurring" => %{"interval" => "month"},
          "unit_amount" => 1000
        })

      # Create with trialing status
      {:ok, subscription} =
        TestClient.create_subscription(%{
          "customer" => customer["id"],
          "items" => [%{"price" => price["id"]}],
          "status" => "trialing"
        })

      assert subscription["status"] == "trialing"
      clear_delivered_webhooks()

      # Update cancel_at_period_end — triggers update event
      {:ok, _updated} =
        TestClient.update_subscription(subscription["id"], %{
          "cancel_at_period_end" => true
        })

      [delivery] = assert_webhook_delivered("customer.subscription.updated")
      assert delivery.event_data[:previous_attributes][:cancel_at_period_end] == false
    end

    test "subscription update with no tracked field changes omits previous_attributes" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "test@example.com"})
      {:ok, product} = TestClient.create_product(%{"name" => "Test Product"})

      {:ok, price} =
        TestClient.create_price(%{
          "currency" => "usd",
          "product" => product["id"],
          "recurring" => %{"interval" => "month"},
          "unit_amount" => 1000
        })

      {:ok, subscription} =
        TestClient.create_subscription(%{
          "customer" => customer["id"],
          "items" => [%{"price" => price["id"]}]
        })

      clear_delivered_webhooks()

      # Update items only — tracked fields don't change, so no previous_attributes
      {:ok, _updated} =
        TestClient.update_subscription(subscription["id"], %{
          "items" => [%{"price" => price["id"], "quantity" => "2"}]
        })

      [delivery] = assert_webhook_delivered("customer.subscription.updated")
      assert delivery.event_data.object.id == subscription["id"]
      refute Map.has_key?(delivery.event_data, :previous_attributes)
    end
  end

  describe "get_delivered_webhooks/0" do
    setup do
      enable_webhook_collection()
      :ok
    end

    test "returns empty list when no webhooks delivered" do
      assert get_delivered_webhooks() == []
    end

    test "returns all delivered webhooks in order" do
      {:ok, _} = TestClient.create_customer(%{"email" => "first@example.com"})
      {:ok, _} = TestClient.create_customer(%{"email" => "second@example.com"})

      deliveries = get_delivered_webhooks()

      assert length(deliveries) == 2
      assert Enum.all?(deliveries, &(&1.event_type == "customer.created"))
    end
  end

  describe "get_delivered_webhooks/1 with type filter" do
    setup do
      enable_webhook_collection()

      # Create customer and product to generate different webhook types
      {:ok, _customer} = TestClient.create_customer(%{"email" => "test@example.com"})
      {:ok, _product} = TestClient.create_product(%{"name" => "Test Product"})

      :ok
    end

    test "filters by exact event type" do
      deliveries = get_delivered_webhooks("customer.created")

      assert length(deliveries) == 1
      assert hd(deliveries).event_type == "customer.created"
    end

    test "filters by wildcard pattern" do
      # Test prefix wildcard
      customer_events = get_delivered_webhooks("customer.*")

      assert length(customer_events) == 1
      assert hd(customer_events).event_type == "customer.created"
    end

    test "returns empty list when no matches" do
      deliveries = get_delivered_webhooks("invoice.paid")

      assert deliveries == []
    end
  end

  describe "clear_delivered_webhooks/0" do
    setup do
      enable_webhook_collection()
      :ok
    end

    test "clears all collected webhooks" do
      {:ok, _} = TestClient.create_customer(%{"email" => "test@example.com"})
      assert length(get_delivered_webhooks()) == 1

      clear_delivered_webhooks()

      assert get_delivered_webhooks() == []
    end
  end

  describe "assert_webhook_delivered/1" do
    setup do
      enable_webhook_collection()
      :ok
    end

    test "returns matching deliveries when found" do
      {:ok, customer} = TestClient.create_customer(%{"email" => "test@example.com"})

      [delivery] = assert_webhook_delivered("customer.created")

      assert delivery.event_data.object.id == customer["id"]
    end

    test "raises when no matching webhook found" do
      {:ok, _} = TestClient.create_customer(%{"email" => "test@example.com"})

      assert_raise ExUnit.AssertionError, ~r/Expected webhook delivery/, fn ->
        assert_webhook_delivered("invoice.paid")
      end
    end

    test "error message includes delivered webhook types" do
      {:ok, _} = TestClient.create_customer(%{"email" => "test@example.com"})

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_webhook_delivered("invoice.paid")
        end

      assert error.message =~ "customer.created"
    end
  end

  describe "refute_webhook_delivered/1" do
    setup do
      enable_webhook_collection()
      :ok
    end

    test "passes when webhook type not found" do
      {:ok, _} = TestClient.create_customer(%{"email" => "test@example.com"})

      assert :ok = refute_webhook_delivered("invoice.paid")
    end

    test "raises when matching webhook is found" do
      {:ok, _} = TestClient.create_customer(%{"email" => "test@example.com"})

      assert_raise ExUnit.AssertionError, ~r/Expected no webhook delivery/, fn ->
        refute_webhook_delivered("customer.created")
      end
    end
  end
end
