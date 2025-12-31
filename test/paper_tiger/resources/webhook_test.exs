defmodule PaperTiger.Resources.WebhookTest do
  @moduledoc """
  End-to-end tests for Webhook Endpoint resource.

  Tests all CRUD operations via the PaperTiger Router:
  1. POST /v1/webhook_endpoints - Create webhook endpoint
  2. GET /v1/webhook_endpoints/:id - Retrieve webhook endpoint
  3. POST /v1/webhook_endpoints/:id - Update webhook endpoint
  4. DELETE /v1/webhook_endpoints/:id - Delete webhook endpoint
  5. GET /v1/webhook_endpoints - List webhook endpoints
  """

  use ExUnit.Case

  alias PaperTiger.Router

  setup do
    # Clear all data before each test
    PaperTiger.flush()
    :ok
  end

  # Helper function to create a test connection with proper setup
  defp conn(method, path, params, headers) do
    conn = Plug.Test.conn(method, path, params)

    headers_with_defaults =
      headers ++
        [
          {"content-type", "application/json"},
          {"authorization", "Bearer sk_test_webhook_key"}
        ]

    Enum.reduce(headers_with_defaults, conn, fn {key, value}, acc ->
      Plug.Conn.put_req_header(acc, key, value)
    end)
  end

  # Helper function to run a request through the router
  defp request(method, path, params \\ nil, headers \\ []) do
    conn = conn(method, path, params, headers)
    Router.call(conn, [])
  end

  # Helper function to run request without authorization header
  defp request_no_auth(method, path, params) do
    conn = Plug.Test.conn(method, path, params)

    conn_with_headers =
      Enum.reduce([{"content-type", "application/json"}], conn, fn {key, value}, acc ->
        Plug.Conn.put_req_header(acc, key, value)
      end)

    Router.call(conn_with_headers, [])
  end

  # Helper function to parse JSON response
  defp json_response(conn) do
    Jason.decode!(conn.resp_body)
  end

  describe "POST /v1/webhook_endpoints - Create webhook endpoint" do
    test "creates a webhook with required parameters" do
      conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded", "customer.created"],
          "url" => "https://example.com/webhook"
        })

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["object"] == "webhook_endpoint"
      assert webhook["url"] == "https://example.com/webhook"
      assert webhook["enabled_events"] == ["charge.succeeded", "customer.created"]
      assert String.starts_with?(webhook["id"], "we_")
      assert is_integer(webhook["created"])
      assert webhook["status"] == "enabled"
    end

    test "auto-generates webhook secret with whsec_ prefix" do
      conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook"
        })

      assert conn.status == 200
      webhook = json_response(conn)
      assert String.starts_with?(webhook["secret"], "whsec_")
      assert String.length(webhook["secret"]) > 10
    end

    test "creates webhook with single event type" do
      conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook"
        })

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["enabled_events"] == ["charge.succeeded"]
    end

    test "creates webhook with multiple event types" do
      events = [
        "charge.succeeded",
        "charge.failed",
        "customer.created",
        "customer.updated",
        "customer.deleted",
        "invoice.created",
        "invoice.payment_succeeded",
        "payment_intent.succeeded"
      ]

      conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => events,
          "url" => "https://example.com/webhook"
        })

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["enabled_events"] == events
    end

    test "defaults to enabled status" do
      conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook"
        })

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["status"] == "enabled"
    end

    test "accepts initial disabled status" do
      conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "status" => "disabled",
          "url" => "https://example.com/webhook"
        })

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["status"] == "disabled"
    end

    test "creates webhook with metadata" do
      metadata = %{"environment" => "production", "team" => "payments"}

      conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "metadata" => metadata,
          "url" => "https://example.com/webhook"
        })

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["metadata"] == metadata
    end

    test "creates webhook with empty metadata" do
      conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "metadata" => %{},
          "url" => "https://example.com/webhook"
        })

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["metadata"] == %{}
    end

    test "defaults to empty metadata when not provided" do
      conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook"
        })

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["metadata"] == %{}
    end

    test "fails when url is missing" do
      conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"]
        })

      assert conn.status == 400
      error = json_response(conn)
      assert error["error"]["type"] == "invalid_request_error"
      assert error["error"]["message"] =~ "Missing required parameter"
    end

    test "fails when enabled_events is missing" do
      conn =
        request(:post, "/v1/webhook_endpoints", %{
          "url" => "https://example.com/webhook"
        })

      assert conn.status == 400
      error = json_response(conn)
      assert error["error"]["type"] == "invalid_request_error"
      assert error["error"]["message"] =~ "Missing required parameter"
    end

    test "fails when both url and enabled_events are missing" do
      conn = request(:post, "/v1/webhook_endpoints", %{})

      assert conn.status == 400
      error = json_response(conn)
      assert error["error"]["type"] == "invalid_request_error"
    end

    test "secret is not user-provided, always generated" do
      # Try to provide a secret (should be ignored)
      conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "secret" => "custom_secret",
          "url" => "https://example.com/webhook"
        })

      assert conn.status == 200
      webhook = json_response(conn)
      # Secret should still be auto-generated
      assert String.starts_with?(webhook["secret"], "whsec_")
      assert webhook["secret"] != "custom_secret"
    end

    test "creates multiple webhooks with different secrets" do
      conn1 =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook1"
        })

      webhook1 = json_response(conn1)
      secret1 = webhook1["secret"]

      conn2 =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook2"
        })

      webhook2 = json_response(conn2)
      secret2 = webhook2["secret"]

      # Each webhook should have a unique secret
      assert secret1 != secret2
      assert String.starts_with?(secret1, "whsec_")
      assert String.starts_with?(secret2, "whsec_")
    end

    test "returns 401 when missing authorization header" do
      conn =
        request_no_auth(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook"
        })

      assert conn.status == 401
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
      assert response["error"]["message"] =~ "API key"
    end

    test "supports idempotency with Idempotency-Key header" do
      idempotency_key = "webhook_key_#{:rand.uniform(1_000_000)}"

      params = %{
        "enabled_events" => ["charge.succeeded"],
        "url" => "https://example.com/webhook"
      }

      # First request
      conn1 =
        request(:post, "/v1/webhook_endpoints", params, [
          {"idempotency-key", idempotency_key}
        ])

      assert conn1.status == 200
      webhook1 = json_response(conn1)

      # Second request with same key
      conn2 =
        request(:post, "/v1/webhook_endpoints", params, [
          {"idempotency-key", idempotency_key}
        ])

      assert conn2.status == 200
      webhook2 = json_response(conn2)

      # Should return the same webhook
      assert webhook1["id"] == webhook2["id"]
      assert webhook1["secret"] == webhook2["secret"]
      assert webhook1["url"] == webhook2["url"]
    end

    test "generates unique IDs for each webhook" do
      ids =
        for _i <- 1..5 do
          conn =
            request(:post, "/v1/webhook_endpoints", %{
              "enabled_events" => ["charge.succeeded"],
              "url" => "https://example.com/webhook"
            })

          json_response(conn)["id"]
        end
        |> MapSet.new()

      # All IDs should be unique
      assert MapSet.size(ids) == 5
    end

    test "webhook response contains all expected fields" do
      conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook"
        })

      assert conn.status == 200
      webhook = json_response(conn)

      # Verify all expected fields are present
      assert Map.has_key?(webhook, "id")
      assert Map.has_key?(webhook, "object")
      assert Map.has_key?(webhook, "created")
      assert Map.has_key?(webhook, "url")
      assert Map.has_key?(webhook, "secret")
      assert Map.has_key?(webhook, "enabled_events")
      assert Map.has_key?(webhook, "status")
      assert Map.has_key?(webhook, "metadata")
    end
  end

  describe "GET /v1/webhook_endpoints/:id - Retrieve webhook endpoint" do
    test "retrieves an existing webhook" do
      # Create webhook first
      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook"
        })

      webhook_id = json_response(create_conn)["id"]

      # Retrieve it
      conn = request(:get, "/v1/webhook_endpoints/#{webhook_id}")

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["id"] == webhook_id
      assert webhook["url"] == "https://example.com/webhook"
      assert webhook["object"] == "webhook_endpoint"
    end

    test "retrieves webhook secret on retrieve" do
      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook"
        })

      created_webhook = json_response(create_conn)
      webhook_id = created_webhook["id"]
      original_secret = created_webhook["secret"]

      conn = request(:get, "/v1/webhook_endpoints/#{webhook_id}")

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["secret"] == original_secret
      assert String.starts_with?(webhook["secret"], "whsec_")
    end

    test "retrieves webhook enabled_events array" do
      events = ["charge.succeeded", "customer.created", "invoice.payment_succeeded"]

      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => events,
          "url" => "https://example.com/webhook"
        })

      webhook_id = json_response(create_conn)["id"]

      conn = request(:get, "/v1/webhook_endpoints/#{webhook_id}")

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["enabled_events"] == events
    end

    test "returns 404 for missing webhook" do
      conn = request(:get, "/v1/webhook_endpoints/we_nonexistent")

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
      assert response["error"]["message"] =~ "we_nonexistent"
    end

    test "retrieves webhook with metadata" do
      metadata = %{"environment" => "prod", "version" => "2"}

      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "metadata" => metadata,
          "url" => "https://example.com/webhook"
        })

      webhook_id = json_response(create_conn)["id"]

      conn = request(:get, "/v1/webhook_endpoints/#{webhook_id}")

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["metadata"] == metadata
    end

    test "retrieves webhook status" do
      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "status" => "disabled",
          "url" => "https://example.com/webhook"
        })

      webhook_id = json_response(create_conn)["id"]

      conn = request(:get, "/v1/webhook_endpoints/#{webhook_id}")

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["status"] == "disabled"
    end

    test "retrieved webhook contains all fields" do
      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook"
        })

      webhook_id = json_response(create_conn)["id"]

      conn = request(:get, "/v1/webhook_endpoints/#{webhook_id}")

      assert conn.status == 200
      webhook = json_response(conn)

      assert Map.has_key?(webhook, "id")
      assert Map.has_key?(webhook, "object")
      assert Map.has_key?(webhook, "created")
      assert Map.has_key?(webhook, "url")
      assert Map.has_key?(webhook, "secret")
      assert Map.has_key?(webhook, "enabled_events")
      assert Map.has_key?(webhook, "status")
      assert Map.has_key?(webhook, "metadata")
    end
  end

  describe "POST /v1/webhook_endpoints/:id - Update webhook endpoint" do
    test "updates webhook url" do
      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook"
        })

      webhook_id = json_response(create_conn)["id"]

      conn =
        request(:post, "/v1/webhook_endpoints/#{webhook_id}", %{
          "url" => "https://updated.example.com/webhook"
        })

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["id"] == webhook_id
      assert webhook["url"] == "https://updated.example.com/webhook"
    end

    test "updates webhook enabled_events" do
      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook"
        })

      webhook_id = json_response(create_conn)["id"]

      new_events = ["charge.succeeded", "charge.failed", "customer.created"]

      conn =
        request(:post, "/v1/webhook_endpoints/#{webhook_id}", %{
          "enabled_events" => new_events
        })

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["enabled_events"] == new_events
    end

    test "updates webhook status to disabled" do
      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "status" => "enabled",
          "url" => "https://example.com/webhook"
        })

      webhook_id = json_response(create_conn)["id"]

      conn =
        request(:post, "/v1/webhook_endpoints/#{webhook_id}", %{
          "status" => "disabled"
        })

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["status"] == "disabled"
    end

    test "updates webhook status to enabled" do
      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "status" => "disabled",
          "url" => "https://example.com/webhook"
        })

      webhook_id = json_response(create_conn)["id"]

      conn =
        request(:post, "/v1/webhook_endpoints/#{webhook_id}", %{
          "status" => "enabled"
        })

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["status"] == "enabled"
    end

    test "updates webhook metadata" do
      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "metadata" => %{"version" => "1"},
          "url" => "https://example.com/webhook"
        })

      webhook_id = json_response(create_conn)["id"]

      new_metadata = %{"environment" => "production", "version" => "2"}

      conn =
        request(:post, "/v1/webhook_endpoints/#{webhook_id}", %{
          "metadata" => new_metadata
        })

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["metadata"] == new_metadata
    end

    test "updates multiple fields at once" do
      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "metadata" => %{"version" => "1"},
          "status" => "enabled",
          "url" => "https://example.com/webhook"
        })

      webhook_id = json_response(create_conn)["id"]
      original_secret = json_response(create_conn)["secret"]

      conn =
        request(:post, "/v1/webhook_endpoints/#{webhook_id}", %{
          "enabled_events" => ["charge.succeeded", "charge.failed"],
          "metadata" => %{"version" => "2"},
          "status" => "disabled",
          "url" => "https://updated.example.com/webhook"
        })

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["id"] == webhook_id
      assert webhook["url"] == "https://updated.example.com/webhook"
      assert webhook["enabled_events"] == ["charge.succeeded", "charge.failed"]
      assert webhook["status"] == "disabled"
      assert webhook["metadata"]["version"] == "2"
      # Secret should remain unchanged
      assert webhook["secret"] == original_secret
    end

    test "preserves immutable fields (id, object, created, secret)" do
      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook"
        })

      webhook = json_response(create_conn)
      original_id = webhook["id"]
      original_created = webhook["created"]
      original_object = webhook["object"]
      original_secret = webhook["secret"]

      conn =
        request(:post, "/v1/webhook_endpoints/#{original_id}", %{
          "url" => "https://updated.example.com/webhook"
        })

      assert conn.status == 200
      updated = json_response(conn)
      assert updated["id"] == original_id
      assert updated["created"] == original_created
      assert updated["object"] == original_object
      assert updated["secret"] == original_secret
    end

    test "returns 404 when updating non-existent webhook" do
      conn =
        request(:post, "/v1/webhook_endpoints/we_nonexistent", %{
          "url" => "https://example.com/webhook"
        })

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "partial update leaves other fields unchanged" do
      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded", "customer.created"],
          "metadata" => %{"version" => "1"},
          "status" => "enabled",
          "url" => "https://example.com/webhook"
        })

      webhook_id = json_response(create_conn)["id"]
      original_events = json_response(create_conn)["enabled_events"]

      # Update only the url
      conn =
        request(:post, "/v1/webhook_endpoints/#{webhook_id}", %{
          "url" => "https://updated.example.com/webhook"
        })

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["url"] == "https://updated.example.com/webhook"
      assert webhook["enabled_events"] == original_events
      assert webhook["status"] == "enabled"
      assert webhook["metadata"]["version"] == "1"
    end
  end

  describe "DELETE /v1/webhook_endpoints/:id - Delete webhook endpoint" do
    test "deletes an existing webhook" do
      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook"
        })

      webhook_id = json_response(create_conn)["id"]

      conn = request(:delete, "/v1/webhook_endpoints/#{webhook_id}")

      assert conn.status == 200
      result = json_response(conn)
      assert result["deleted"] == true
      assert result["id"] == webhook_id
      assert result["object"] == "webhook_endpoint"
    end

    test "returns 404 when deleting non-existent webhook" do
      conn = request(:delete, "/v1/webhook_endpoints/we_nonexistent")

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "webhook is not retrievable after deletion" do
      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook"
        })

      webhook_id = json_response(create_conn)["id"]

      delete_conn = request(:delete, "/v1/webhook_endpoints/#{webhook_id}")
      assert delete_conn.status == 200

      # Try to retrieve - should be 404
      retrieve_conn = request(:get, "/v1/webhook_endpoints/#{webhook_id}")
      assert retrieve_conn.status == 404
    end

    test "deletion response has correct structure" do
      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook"
        })

      webhook_id = json_response(create_conn)["id"]

      conn = request(:delete, "/v1/webhook_endpoints/#{webhook_id}")

      assert conn.status == 200
      result = json_response(conn)
      assert Map.has_key?(result, "deleted")
      assert Map.has_key?(result, "id")
      assert Map.has_key?(result, "object")
      assert result["deleted"] == true
      assert result["id"] == webhook_id
      assert result["object"] == "webhook_endpoint"
    end

    test "deleting one webhook doesn't affect others" do
      # Create two webhooks
      conn1 =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example1.com/webhook"
        })

      webhook1_id = json_response(conn1)["id"]

      conn2 =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example2.com/webhook"
        })

      webhook2_id = json_response(conn2)["id"]

      # Delete webhook1
      delete_conn = request(:delete, "/v1/webhook_endpoints/#{webhook1_id}")
      assert delete_conn.status == 200

      # Verify webhook2 still exists
      check_conn = request(:get, "/v1/webhook_endpoints/#{webhook2_id}")
      assert check_conn.status == 200
      assert json_response(check_conn)["id"] == webhook2_id
    end

    test "can delete disabled webhook" do
      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "status" => "disabled",
          "url" => "https://example.com/webhook"
        })

      webhook_id = json_response(create_conn)["id"]

      conn = request(:delete, "/v1/webhook_endpoints/#{webhook_id}")

      assert conn.status == 200
      result = json_response(conn)
      assert result["deleted"] == true
      assert result["id"] == webhook_id
    end
  end

  describe "GET /v1/webhook_endpoints - List webhook endpoints" do
    test "lists webhooks with default limit" do
      # Create 3 webhooks
      for i <- 1..3 do
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example#{i}.com/webhook"
        })
      end

      conn = request(:get, "/v1/webhook_endpoints")

      assert conn.status == 200
      result = json_response(conn)
      assert is_list(result["data"])
      assert length(result["data"]) == 3
      assert result["has_more"] == false
      assert result["object"] == "list"
      assert result["url"] == "/v1/webhook_endpoints"
    end

    test "respects limit parameter" do
      # Create 5 webhooks
      for i <- 1..5 do
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example#{i}.com/webhook"
        })
      end

      conn = request(:get, "/v1/webhook_endpoints?limit=2")

      assert conn.status == 200
      result = json_response(conn)
      assert length(result["data"]) == 2
      assert result["has_more"] == true
    end

    test "returns all webhooks when limit is greater than total" do
      # Create 2 webhooks
      for i <- 1..2 do
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example#{i}.com/webhook"
        })
      end

      conn = request(:get, "/v1/webhook_endpoints?limit=100")

      assert conn.status == 200
      result = json_response(conn)
      assert length(result["data"]) == 2
      assert result["has_more"] == false
    end

    test "returns empty list when no webhooks exist" do
      conn = request(:get, "/v1/webhook_endpoints")

      assert conn.status == 200
      result = json_response(conn)
      assert result["data"] == []
      assert result["has_more"] == false
    end

    test "webhooks are sorted by creation time (descending)" do
      # Create webhooks with delays to ensure different timestamps
      for i <- 1..3 do
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example#{i}.com/webhook"
        })

        # Small delay to ensure different timestamps
        Process.sleep(1)
      end

      conn = request(:get, "/v1/webhook_endpoints?limit=10")

      assert conn.status == 200
      result = json_response(conn)
      returned_webhooks = result["data"]

      # Verify they are sorted by created time (descending - newest first)
      created_times = Enum.map(returned_webhooks, & &1["created"])
      sorted_times = Enum.sort(created_times, :desc)
      assert created_times == sorted_times
    end

    test "list includes all webhook fields" do
      request(:post, "/v1/webhook_endpoints", %{
        "enabled_events" => ["charge.succeeded"],
        "metadata" => %{"environment" => "prod"},
        "url" => "https://example.com/webhook"
      })

      conn = request(:get, "/v1/webhook_endpoints")

      assert conn.status == 200
      webhook = Enum.at(json_response(conn)["data"], 0)

      # Verify expected fields are present
      assert Map.has_key?(webhook, "id")
      assert Map.has_key?(webhook, "object")
      assert Map.has_key?(webhook, "created")
      assert Map.has_key?(webhook, "url")
      assert Map.has_key?(webhook, "secret")
      assert Map.has_key?(webhook, "enabled_events")
      assert Map.has_key?(webhook, "status")
      assert Map.has_key?(webhook, "metadata")
    end

    test "supports starting_after cursor pagination" do
      # Create 5 webhooks with delays to ensure different timestamps
      for i <- 1..5 do
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example#{i}.com/webhook"
        })

        # Ensure different timestamps
        Process.sleep(2)
      end

      # Get first page with limit 2
      conn1 = request(:get, "/v1/webhook_endpoints?limit=2")
      assert conn1.status == 200
      page1 = json_response(conn1)
      assert length(page1["data"]) == 2
      assert page1["has_more"] == true

      # Get second page using starting_after
      # Use the LAST webhook from first page as cursor
      last_webhook_id = Enum.at(page1["data"], 1)["id"]
      conn2 = request(:get, "/v1/webhook_endpoints?limit=2&starting_after=#{last_webhook_id}")

      assert conn2.status == 200
      page2 = json_response(conn2)
      assert page2["data"] != []

      # Verify that the cursor webhook is not in second page
      page2_ids = Enum.map(page2["data"], & &1["id"])
      assert not Enum.member?(page2_ids, last_webhook_id)
    end

    test "pagination with limit=1 creates multiple pages" do
      # Create 3 webhooks
      for i <- 1..3 do
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example#{i}.com/webhook"
        })
      end

      # First page
      conn1 = request(:get, "/v1/webhook_endpoints?limit=1")
      assert conn1.status == 200
      page1 = json_response(conn1)
      assert length(page1["data"]) == 1
      assert page1["has_more"] == true

      # Second page using cursor
      cursor = Enum.at(page1["data"], 0)["id"]
      conn2 = request(:get, "/v1/webhook_endpoints?limit=1&starting_after=#{cursor}")
      assert conn2.status == 200
      page2 = json_response(conn2)
      assert length(page2["data"]) == 1
      assert page2["has_more"] == true

      # Third page using cursor
      cursor2 = Enum.at(page2["data"], 0)["id"]
      conn3 = request(:get, "/v1/webhook_endpoints?limit=1&starting_after=#{cursor2}")
      assert conn3.status == 200
      page3 = json_response(conn3)
      assert length(page3["data"]) == 1
      assert page3["has_more"] == false
    end

    test "list does not include deleted webhooks" do
      # Create 3 webhooks
      conn1 =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example1.com/webhook"
        })

      webhook1_id = json_response(conn1)["id"]

      for i <- 2..3 do
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example#{i}.com/webhook"
        })
      end

      # Delete first webhook
      request(:delete, "/v1/webhook_endpoints/#{webhook1_id}")

      # List should now only show 2 webhooks
      conn = request(:get, "/v1/webhook_endpoints")

      assert conn.status == 200
      result = json_response(conn)
      assert length(result["data"]) == 2

      # Verify deleted webhook is not in list
      ids = Enum.map(result["data"], & &1["id"])
      assert not Enum.member?(ids, webhook1_id)
    end

    test "list includes both enabled and disabled webhooks" do
      request(:post, "/v1/webhook_endpoints", %{
        "enabled_events" => ["charge.succeeded"],
        "status" => "enabled",
        "url" => "https://example1.com/webhook"
      })

      request(:post, "/v1/webhook_endpoints", %{
        "enabled_events" => ["charge.succeeded"],
        "status" => "disabled",
        "url" => "https://example2.com/webhook"
      })

      conn = request(:get, "/v1/webhook_endpoints")

      assert conn.status == 200
      result = json_response(conn)
      assert length(result["data"]) == 2

      statuses = Enum.map(result["data"], & &1["status"])
      assert Enum.member?(statuses, "enabled")
      assert Enum.member?(statuses, "disabled")
    end
  end

  describe "Validation and error handling" do
    test "url is required parameter" do
      conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"]
        })

      assert conn.status == 400
      error = json_response(conn)
      assert error["error"]["type"] == "invalid_request_error"
    end

    test "enabled_events is required parameter" do
      conn =
        request(:post, "/v1/webhook_endpoints", %{
          "url" => "https://example.com/webhook"
        })

      assert conn.status == 400
      error = json_response(conn)
      assert error["error"]["type"] == "invalid_request_error"
    end

    test "handles very long webhook urls" do
      long_url = "https://example.com/webhook?" <> String.duplicate("param=value&", 100)

      conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => long_url
        })

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["url"] == long_url
    end

    test "handles special characters in metadata" do
      metadata = %{
        "quotes" => "\"quoted\" 'value'",
        "special" => "!@#$%^&*()",
        "unicode" => "你好世界"
      }

      conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "metadata" => metadata,
          "url" => "https://example.com/webhook"
        })

      assert conn.status == 200
      returned_metadata = json_response(conn)["metadata"]
      assert returned_metadata["special"] == metadata["special"]
      assert returned_metadata["unicode"] == metadata["unicode"]
      assert returned_metadata["quotes"] == metadata["quotes"]
    end

    test "handles empty enabled_events array" do
      conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => [],
          "url" => "https://example.com/webhook"
        })

      # Empty events array is provided, should be accepted
      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["enabled_events"] == []
    end

    test "handles large number of event types" do
      events = [
        "charge.succeeded",
        "charge.failed",
        "charge.dispute.created",
        "charge.dispute.evidence_submitted",
        "charge.dispute.evidence_upload_expires",
        "charge.dispute.closed",
        "charge.dispute.funds_reinstated",
        "charge.refunded",
        "customer.created",
        "customer.updated",
        "customer.deleted",
        "customer.source.created",
        "customer.source.deleted",
        "customer.source.expiring",
        "customer.source.updated",
        "customer.subscription.created",
        "customer.subscription.deleted",
        "customer.subscription.trial_will_end",
        "customer.subscription.updated",
        "invoice.created",
        "invoice.finalized",
        "invoice.marked_uncollectible",
        "invoice.paid",
        "invoice.payment_action_required",
        "invoice.payment_failed",
        "invoice.payment_succeeded",
        "invoice.sent",
        "invoice.updated",
        "invoice.voided"
      ]

      conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => events,
          "url" => "https://example.com/webhook"
        })

      assert conn.status == 200
      webhook = json_response(conn)
      assert webhook["enabled_events"] == events
    end
  end

  describe "Integration - Full CRUD flow" do
    test "complete webhook endpoint lifecycle" do
      # 1. Create
      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "metadata" => %{"version" => "1"},
          "url" => "https://example.com/webhook"
        })

      assert create_conn.status == 200
      webhook = json_response(create_conn)
      webhook_id = webhook["id"]
      assert webhook["url"] == "https://example.com/webhook"
      assert webhook["status"] == "enabled"

      # 2. Retrieve
      retrieve_conn = request(:get, "/v1/webhook_endpoints/#{webhook_id}")

      assert retrieve_conn.status == 200
      retrieved = json_response(retrieve_conn)
      assert retrieved["id"] == webhook_id
      assert retrieved["url"] == "https://example.com/webhook"

      # 3. Update
      update_conn =
        request(:post, "/v1/webhook_endpoints/#{webhook_id}", %{
          "metadata" => %{"version" => "2"},
          "status" => "disabled",
          "url" => "https://updated.example.com/webhook"
        })

      assert update_conn.status == 200
      updated = json_response(update_conn)
      assert updated["url"] == "https://updated.example.com/webhook"
      assert updated["status"] == "disabled"
      assert updated["metadata"]["version"] == "2"

      # 4. List (verify it's in the list)
      list_conn = request(:get, "/v1/webhook_endpoints")

      assert list_conn.status == 200
      webhooks = json_response(list_conn)["data"]
      found = Enum.find(webhooks, &(&1["id"] == webhook_id))
      assert found != nil
      assert found["url"] == "https://updated.example.com/webhook"
      assert found["status"] == "disabled"

      # 5. Delete
      delete_conn = request(:delete, "/v1/webhook_endpoints/#{webhook_id}")

      assert delete_conn.status == 200
      assert json_response(delete_conn)["deleted"] == true

      # 6. Verify deleted (404 on retrieve)
      final_conn = request(:get, "/v1/webhook_endpoints/#{webhook_id}")

      assert final_conn.status == 404
    end

    test "multiple webhooks can coexist and be managed independently" do
      # Create multiple webhooks
      ids =
        for i <- 1..3 do
          response =
            request(:post, "/v1/webhook_endpoints", %{
              "enabled_events" => ["charge.succeeded"],
              "metadata" => %{"index" => "#{i}"},
              "url" => "https://example#{i}.com/webhook"
            })

          json_response(response)["id"]
        end

      # Verify all exist
      Enum.each(ids, fn id ->
        conn = request(:get, "/v1/webhook_endpoints/#{id}")
        assert conn.status == 200
      end)

      # List should show all
      list_conn = request(:get, "/v1/webhook_endpoints?limit=10")
      assert list_conn.status == 200
      list_ids = Enum.map(json_response(list_conn)["data"], & &1["id"])

      Enum.each(ids, fn id ->
        assert Enum.member?(list_ids, id)
      end)

      # Update one, verify others unchanged
      first_id = Enum.at(ids, 0)
      second_id = Enum.at(ids, 1)

      request(:post, "/v1/webhook_endpoints/#{first_id}", %{
        "status" => "disabled"
      })

      # Verify first is disabled
      check1 = request(:get, "/v1/webhook_endpoints/#{first_id}")
      assert json_response(check1)["status"] == "disabled"

      # Verify second is still enabled
      check2 = request(:get, "/v1/webhook_endpoints/#{second_id}")
      assert json_response(check2)["status"] == "enabled"
    end

    test "webhook secret is preserved across updates" do
      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook"
        })

      webhook = json_response(create_conn)
      webhook_id = webhook["id"]
      original_secret = webhook["secret"]

      # Update webhook
      update_conn =
        request(:post, "/v1/webhook_endpoints/#{webhook_id}", %{
          "url" => "https://updated.example.com/webhook"
        })

      assert update_conn.status == 200
      updated = json_response(update_conn)
      assert updated["secret"] == original_secret

      # Retrieve and verify secret is still the same
      retrieve_conn = request(:get, "/v1/webhook_endpoints/#{webhook_id}")
      assert retrieve_conn.status == 200
      retrieved = json_response(retrieve_conn)
      assert retrieved["secret"] == original_secret
    end

    test "updating multiple fields preserves immutable fields" do
      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook"
        })

      webhook = json_response(create_conn)
      webhook_id = webhook["id"]
      original_created = webhook["created"]
      original_secret = webhook["secret"]

      # Update many fields
      update_conn =
        request(:post, "/v1/webhook_endpoints/#{webhook_id}", %{
          "enabled_events" => ["charge.succeeded", "charge.failed", "customer.created"],
          "metadata" => %{"updated" => "true"},
          "status" => "disabled",
          "url" => "https://updated.example.com/webhook"
        })

      assert update_conn.status == 200
      updated = json_response(update_conn)

      # Verify immutable fields are preserved
      assert updated["id"] == webhook_id
      assert updated["created"] == original_created
      assert updated["secret"] == original_secret
      assert updated["object"] == "webhook_endpoint"

      # Verify mutable fields are updated
      assert updated["url"] == "https://updated.example.com/webhook"

      assert updated["enabled_events"] == [
               "charge.succeeded",
               "charge.failed",
               "customer.created"
             ]

      assert updated["status"] == "disabled"
      assert updated["metadata"]["updated"] == "true"
    end
  end

  describe "Secret handling" do
    test "each webhook has a unique secret" do
      secrets =
        for _i <- 1..5 do
          conn =
            request(:post, "/v1/webhook_endpoints", %{
              "enabled_events" => ["charge.succeeded"],
              "url" => "https://example.com/webhook"
            })

          json_response(conn)["secret"]
        end
        |> MapSet.new()

      # All secrets should be unique
      assert MapSet.size(secrets) == 5
    end

    test "secret format is correct (whsec_ prefix and proper length)" do
      conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook"
        })

      webhook = json_response(conn)
      secret = webhook["secret"]

      # Should start with whsec_
      assert String.starts_with?(secret, "whsec_")

      # Should be long enough (whsec_ + 32 hex chars)
      assert String.length(secret) >= 37
    end

    test "secret is returned on retrieve" do
      create_conn =
        request(:post, "/v1/webhook_endpoints", %{
          "enabled_events" => ["charge.succeeded"],
          "url" => "https://example.com/webhook"
        })

      webhook_id = json_response(create_conn)["id"]
      original_secret = json_response(create_conn)["secret"]

      # Retrieve webhook
      retrieve_conn = request(:get, "/v1/webhook_endpoints/#{webhook_id}")

      assert retrieve_conn.status == 200
      webhook = json_response(retrieve_conn)
      assert webhook["secret"] == original_secret
    end

    test "secret is included in list results" do
      request(:post, "/v1/webhook_endpoints", %{
        "enabled_events" => ["charge.succeeded"],
        "url" => "https://example.com/webhook"
      })

      conn = request(:get, "/v1/webhook_endpoints")

      assert conn.status == 200
      webhooks = json_response(conn)["data"]
      webhook = Enum.at(webhooks, 0)

      assert Map.has_key?(webhook, "secret")
      assert String.starts_with?(webhook["secret"], "whsec_")
    end
  end
end
