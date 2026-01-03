defmodule PaperTiger.Resources.CheckoutSessionTest do
  @moduledoc """
  Tests for Checkout Session resource including expire and complete endpoints.

  Tests all CRUD operations via the PaperTiger Router:
  1. POST /v1/checkout/sessions - Create checkout session
  2. GET /v1/checkout/sessions/:id - Retrieve checkout session
  3. GET /v1/checkout/sessions - List checkout sessions
  4. POST /v1/checkout/sessions/:id/expire - Expire checkout session
  5. POST /_test/checkout/sessions/:id/complete - Complete checkout session (test helper)
  """

  use ExUnit.Case, async: true

  import PaperTiger.Test

  alias PaperTiger.Router

  setup :checkout_paper_tiger

  defp conn(method, path, params, headers) do
    conn = Plug.Test.conn(method, path, params)

    headers_with_defaults =
      headers ++
        [
          {"content-type", "application/json"},
          {"authorization", "Bearer sk_test_checkout_key"}
        ]

    Enum.reduce(headers_with_defaults, conn, fn {key, value}, acc ->
      Plug.Conn.put_req_header(acc, key, value)
    end)
  end

  defp request(method, path, params \\ nil, headers \\ []) do
    conn = conn(method, path, params, headers)
    Router.call(conn, [])
  end

  defp json_response(conn) do
    Jason.decode!(conn.resp_body)
  end

  describe "POST /v1/checkout/sessions - Create" do
    test "creates a checkout session with required fields" do
      params = %{
        "cancel_url" => "https://example.com/cancel",
        "mode" => "payment",
        "success_url" => "https://example.com/success"
      }

      conn = request(:post, "/v1/checkout/sessions", params)

      assert conn.status == 200
      session = json_response(conn)
      assert String.starts_with?(session["id"], "cs_")
      assert session["object"] == "checkout.session"
      assert session["status"] == "open"
      assert session["payment_status"] == "unpaid"
      assert session["mode"] == "payment"
      assert session["success_url"] == "https://example.com/success"
      assert session["cancel_url"] == "https://example.com/cancel"
    end

    test "creates a subscription mode session" do
      params = %{
        "cancel_url" => "https://example.com/cancel",
        "mode" => "subscription",
        "success_url" => "https://example.com/success"
      }

      conn = request(:post, "/v1/checkout/sessions", params)

      assert conn.status == 200
      session = json_response(conn)
      assert session["mode"] == "subscription"
    end

    test "creates a setup mode session" do
      params = %{
        "cancel_url" => "https://example.com/cancel",
        "mode" => "setup",
        "success_url" => "https://example.com/success"
      }

      conn = request(:post, "/v1/checkout/sessions", params)

      assert conn.status == 200
      session = json_response(conn)
      assert session["mode"] == "setup"
    end

    test "returns error when missing required fields" do
      conn = request(:post, "/v1/checkout/sessions", %{})

      assert conn.status == 400
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end
  end

  describe "GET /v1/checkout/sessions/:id - Retrieve" do
    test "retrieves an existing checkout session" do
      params = %{
        "cancel_url" => "https://example.com/cancel",
        "mode" => "payment",
        "success_url" => "https://example.com/success"
      }

      create_conn = request(:post, "/v1/checkout/sessions", params)
      session_id = json_response(create_conn)["id"]

      conn = request(:get, "/v1/checkout/sessions/#{session_id}")

      assert conn.status == 200
      session = json_response(conn)
      assert session["id"] == session_id
    end

    test "returns 404 for non-existent session" do
      conn = request(:get, "/v1/checkout/sessions/cs_nonexistent")

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end
  end

  describe "POST /v1/checkout/sessions/:id/expire - Expire" do
    test "expires an open checkout session" do
      params = %{
        "cancel_url" => "https://example.com/cancel",
        "mode" => "payment",
        "success_url" => "https://example.com/success"
      }

      create_conn = request(:post, "/v1/checkout/sessions", params)
      session_id = json_response(create_conn)["id"]

      conn = request(:post, "/v1/checkout/sessions/#{session_id}/expire")

      assert conn.status == 200
      session = json_response(conn)
      assert session["id"] == session_id
      assert session["status"] == "expired"
    end

    test "returns error when expiring non-open session" do
      params = %{
        "cancel_url" => "https://example.com/cancel",
        "mode" => "payment",
        "success_url" => "https://example.com/success"
      }

      create_conn = request(:post, "/v1/checkout/sessions", params)
      session_id = json_response(create_conn)["id"]

      # Expire it first
      request(:post, "/v1/checkout/sessions/#{session_id}/expire")

      # Try to expire again
      conn = request(:post, "/v1/checkout/sessions/#{session_id}/expire")

      assert conn.status == 400
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
      assert response["error"]["message"] =~ "not in an expireable state"
    end

    test "returns 404 for non-existent session" do
      conn = request(:post, "/v1/checkout/sessions/cs_nonexistent/expire")

      assert conn.status == 404
    end
  end

  describe "POST /_test/checkout/sessions/:id/complete - Complete (test helper)" do
    test "completes a payment mode session and creates payment intent" do
      # Create customer first
      cust_conn = request(:post, "/v1/customers", %{"email" => "checkout@example.com"})
      customer_id = json_response(cust_conn)["id"]

      params = %{
        "cancel_url" => "https://example.com/cancel",
        "currency" => "usd",
        "customer" => customer_id,
        "line_items" => [%{"amount" => 2000, "quantity" => 1}],
        "mode" => "payment",
        "success_url" => "https://example.com/success"
      }

      create_conn = request(:post, "/v1/checkout/sessions", params)
      session_id = json_response(create_conn)["id"]

      conn = request(:post, "/_test/checkout/sessions/#{session_id}/complete")

      assert conn.status == 200
      session = json_response(conn)
      assert session["id"] == session_id
      assert session["status"] == "complete"
      assert session["payment_status"] == "paid"
      assert String.starts_with?(session["payment_intent"], "pi_")
      assert is_nil(session["subscription"])
      assert is_nil(session["setup_intent"])
      assert is_integer(session["completed_at"])

      # Verify payment intent was created
      pi_conn = request(:get, "/v1/payment_intents/#{session["payment_intent"]}")
      assert pi_conn.status == 200
      pi = json_response(pi_conn)
      assert pi["status"] == "succeeded"
      assert pi["customer"] == customer_id
    end

    test "completes a subscription mode session and creates subscription" do
      # Create customer first
      cust_conn = request(:post, "/v1/customers", %{"email" => "sub@example.com"})
      customer_id = json_response(cust_conn)["id"]

      # Create product and price
      prod_conn = request(:post, "/v1/products", %{"name" => "Test Product"})
      product_id = json_response(prod_conn)["id"]

      price_params = %{
        "currency" => "usd",
        "product" => product_id,
        "recurring" => %{"interval" => "month"},
        "unit_amount" => 2000
      }

      price_conn = request(:post, "/v1/prices", price_params)
      price_id = json_response(price_conn)["id"]

      params = %{
        "cancel_url" => "https://example.com/cancel",
        "customer" => customer_id,
        "line_items" => [%{"price" => price_id, "quantity" => 1}],
        "mode" => "subscription",
        "success_url" => "https://example.com/success"
      }

      create_conn = request(:post, "/v1/checkout/sessions", params)
      session_id = json_response(create_conn)["id"]

      conn = request(:post, "/_test/checkout/sessions/#{session_id}/complete")

      assert conn.status == 200
      session = json_response(conn)
      assert session["id"] == session_id
      assert session["status"] == "complete"
      assert session["payment_status"] == "paid"
      assert String.starts_with?(session["subscription"], "sub_")
      assert is_nil(session["payment_intent"])
      assert is_nil(session["setup_intent"])

      # Verify subscription was created
      sub_conn = request(:get, "/v1/subscriptions/#{session["subscription"]}")
      assert sub_conn.status == 200
      sub = json_response(sub_conn)
      assert sub["status"] == "active"
      assert sub["customer"] == customer_id
    end

    test "completes a setup mode session and creates setup intent" do
      # Create customer first
      cust_conn = request(:post, "/v1/customers", %{"email" => "setup@example.com"})
      customer_id = json_response(cust_conn)["id"]

      params = %{
        "cancel_url" => "https://example.com/cancel",
        "customer" => customer_id,
        "mode" => "setup",
        "success_url" => "https://example.com/success"
      }

      create_conn = request(:post, "/v1/checkout/sessions", params)
      session_id = json_response(create_conn)["id"]

      conn = request(:post, "/_test/checkout/sessions/#{session_id}/complete")

      assert conn.status == 200
      session = json_response(conn)
      assert session["id"] == session_id
      assert session["status"] == "complete"
      assert session["payment_status"] == "paid"
      assert String.starts_with?(session["setup_intent"], "seti_")
      assert is_nil(session["payment_intent"])
      assert is_nil(session["subscription"])

      # Verify setup intent was created
      seti_conn = request(:get, "/v1/setup_intents/#{session["setup_intent"]}")
      assert seti_conn.status == 200
      seti = json_response(seti_conn)
      assert seti["status"] == "succeeded"
      assert seti["customer"] == customer_id
    end

    test "returns error when completing already completed session" do
      params = %{
        "cancel_url" => "https://example.com/cancel",
        "mode" => "payment",
        "success_url" => "https://example.com/success"
      }

      create_conn = request(:post, "/v1/checkout/sessions", params)
      session_id = json_response(create_conn)["id"]

      # Complete it
      request(:post, "/_test/checkout/sessions/#{session_id}/complete")

      # Try to complete again
      conn = request(:post, "/_test/checkout/sessions/#{session_id}/complete")

      assert conn.status == 400
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
      assert response["error"]["message"] =~ "already been completed"
    end

    test "returns error when completing expired session" do
      params = %{
        "cancel_url" => "https://example.com/cancel",
        "mode" => "payment",
        "success_url" => "https://example.com/success"
      }

      create_conn = request(:post, "/v1/checkout/sessions", params)
      session_id = json_response(create_conn)["id"]

      # Expire it
      request(:post, "/v1/checkout/sessions/#{session_id}/expire")

      # Try to complete
      conn = request(:post, "/_test/checkout/sessions/#{session_id}/complete")

      assert conn.status == 400
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
      assert response["error"]["message"] =~ "cannot be completed"
    end

    test "returns 404 for non-existent session" do
      conn = request(:post, "/_test/checkout/sessions/cs_nonexistent/complete")

      assert conn.status == 404
    end
  end

  describe "GET /v1/checkout/sessions - List" do
    test "lists checkout sessions" do
      for _i <- 1..3 do
        request(:post, "/v1/checkout/sessions", %{
          "cancel_url" => "https://example.com/cancel",
          "mode" => "payment",
          "success_url" => "https://example.com/success"
        })
      end

      conn = request(:get, "/v1/checkout/sessions")

      assert conn.status == 200
      result = json_response(conn)
      assert is_list(result["data"])
      assert length(result["data"]) == 3
      assert result["object"] == "list"
    end
  end
end
