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
        ] ++ sandbox_headers()

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

  describe "POST /v1/checkout/sessions/:id - Update" do
    test "updates metadata with Stripe merge and delete semantics" do
      session = create_checkout_session(%{"metadata" => %{"keep" => "yes", "remove" => "old"}})

      conn =
        request(:post, "/v1/checkout/sessions/#{session["id"]}", %{
          "metadata" => %{"add" => "new", "remove" => ""}
        })

      assert conn.status == 200
      updated = json_response(conn)
      assert updated["metadata"] == %{"add" => "new", "keep" => "yes"}
    end

    test "replaces line items as a full array and recalculates totals" do
      session =
        create_checkout_session(%{
          "line_items" => [
            price_data_line_item("Original", 1000, 1),
            price_data_line_item("Removed", 500, 2)
          ]
        })

      [existing | _] = session["line_items"]

      conn =
        request(:post, "/v1/checkout/sessions/#{session["id"]}", %{
          "line_items" => [
            %{"id" => existing["id"], "quantity" => 3},
            price_data_line_item("Added", 250, 2)
          ]
        })

      assert conn.status == 200
      updated = json_response(conn)
      assert updated["amount_subtotal"] == 3500
      assert updated["amount_total"] == 3500
      assert length(updated["line_items"]) == 2
      assert Enum.map(updated["line_items"], & &1["description"]) == ["Original", "Added"]
      assert hd(updated["line_items"])["id"] == existing["id"]
      assert hd(updated["line_items"])["quantity"] == 3
    end

    test "updates collected information and shipping options" do
      session = create_checkout_session()

      shipping_options = [
        %{
          "shipping_rate_data" => %{
            "display_name" => "Ground",
            "fixed_amount" => %{"amount" => 500, "currency" => "usd"},
            "type" => "fixed_amount"
          }
        }
      ]

      collected_information = %{
        "shipping_details" => %{
          "address" => %{"country" => "US", "line1" => "1 Main"},
          "name" => "Test Customer"
        }
      }

      conn =
        request(:post, "/v1/checkout/sessions/#{session["id"]}", %{
          "collected_information" => collected_information,
          "shipping_options" => shipping_options
        })

      assert conn.status == 200
      updated = json_response(conn)
      assert updated["collected_information"] == collected_information
      assert updated["shipping_options"] == shipping_options
    end
  end

  describe "GET /v1/checkout/sessions/:id/line_items" do
    test "returns full line items with Stripe list shape and cursor pagination" do
      session =
        create_checkout_session(%{
          "line_items" => [
            price_data_line_item("One", 100, 1),
            price_data_line_item("Two", 200, 2),
            price_data_line_item("Three", 300, 3)
          ]
        })

      page1_conn = request(:get, "/v1/checkout/sessions/#{session["id"]}/line_items?limit=2")

      assert page1_conn.status == 200
      page1 = json_response(page1_conn)
      assert page1["object"] == "list"
      assert page1["url"] == "/v1/checkout/sessions/#{session["id"]}/line_items"
      assert page1["has_more"] == true
      assert Enum.map(page1["data"], & &1["description"]) == ["One", "Two"]

      last_id = List.last(page1["data"])["id"]
      page2_conn = request(:get, "/v1/checkout/sessions/#{session["id"]}/line_items?starting_after=#{last_id}")

      assert page2_conn.status == 200
      page2 = json_response(page2_conn)
      assert page2["has_more"] == false
      assert Enum.map(page2["data"], & &1["description"]) == ["Three"]
    end

    test "line items remain retrievable after checkout completion" do
      session =
        create_checkout_session(%{
          "line_items" => [
            price_data_line_item("Paid item", 1500, 2)
          ]
        })

      complete_conn = request(:post, "/_test/checkout/sessions/#{session["id"]}/complete")
      assert complete_conn.status == 200

      line_items_conn = request(:get, "/v1/checkout/sessions/#{session["id"]}/line_items")
      assert line_items_conn.status == 200

      result = json_response(line_items_conn)
      assert [%{"amount_total" => 3000, "description" => "Paid item", "quantity" => 2}] = result["data"]
    end

    test "supports expand[]=line_items on checkout session retrieval" do
      session =
        create_checkout_session(%{
          "line_items" => [
            price_data_line_item("Expanded item", 1200, 1)
          ]
        })

      conn = request(:get, "/v1/checkout/sessions/#{session["id"]}?expand[]=line_items")

      assert conn.status == 200
      retrieved = json_response(conn)
      assert retrieved["line_items"]["object"] == "list"
      assert [%{"description" => "Expanded item"}] = retrieved["line_items"]["data"]
    end

    test "returns 404 for a missing session" do
      conn = request(:get, "/v1/checkout/sessions/cs_missing/line_items")

      assert conn.status == 404
      assert json_response(conn)["error"]["code"] == "resource_missing"
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

      # Verify payment intent has latest_charge
      assert pi["latest_charge"] != nil
      assert String.starts_with?(pi["latest_charge"], "ch_")

      # Verify charge was created
      ch_conn = request(:get, "/v1/charges/#{pi["latest_charge"]}")
      assert ch_conn.status == 200
      ch = json_response(ch_conn)
      assert ch["amount"] == 2000
      assert ch["currency"] == "usd"
      assert ch["payment_intent"] == pi["id"]
      assert ch["status"] == "succeeded"

      # Verify balance transaction was created
      assert ch["balance_transaction"] != nil
      assert String.starts_with?(ch["balance_transaction"], "txn_")
      bt_conn = request(:get, "/v1/balance_transactions/#{ch["balance_transaction"]}")
      assert bt_conn.status == 200
      bt = json_response(bt_conn)
      assert bt["amount"] == 2000
      assert bt["type"] == "charge"
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

    test "derives currency from line_items price_data when not explicitly set" do
      cust_conn = request(:post, "/v1/customers", %{"email" => "currency@example.com"})
      customer_id = json_response(cust_conn)["id"]

      params = %{
        "cancel_url" => "https://example.com/cancel",
        "customer" => customer_id,
        "line_items" => [
          %{
            "price_data" => %{
              "currency" => "gbp",
              "product_data" => %{"name" => "Test"},
              "unit_amount" => 1500
            },
            "quantity" => 2
          }
        ],
        "mode" => "payment",
        "success_url" => "https://example.com/success"
      }

      create_conn = request(:post, "/v1/checkout/sessions", params)
      session = json_response(create_conn)
      assert session["currency"] == "gbp"

      # Complete and verify PI currency
      complete_conn = request(:post, "/_test/checkout/sessions/#{session["id"]}/complete")
      completed = json_response(complete_conn)
      pi_conn = request(:get, "/v1/payment_intents/#{completed["payment_intent"]}")
      pi = json_response(pi_conn)
      assert pi["currency"] == "gbp"
    end

    test "applies automatic tax to checkout totals and payment intent amount" do
      cust_conn = request(:post, "/v1/customers", %{"email" => "taxed-checkout@example.com"})
      customer_id = json_response(cust_conn)["id"]

      prod_conn = request(:post, "/v1/products", %{"name" => "Taxed Product"})
      product_id = json_response(prod_conn)["id"]

      price_conn =
        request(:post, "/v1/prices", %{
          "currency" => "usd",
          "product" => product_id,
          "unit_amount" => 1000
        })

      price_id = json_response(price_conn)["id"]

      params = %{
        "automatic_tax" => %{"enabled" => true},
        "cancel_url" => "https://example.com/cancel",
        "currency" => "usd",
        "customer" => customer_id,
        "line_items" => [%{"price" => price_id, "quantity" => 2}],
        "metadata" => %{"tax_country" => "US"},
        "mode" => "payment",
        "success_url" => "https://example.com/success"
      }

      create_conn = request(:post, "/v1/checkout/sessions", params)
      session = json_response(create_conn)

      assert session["automatic_tax"]["enabled"] == true
      assert session["automatic_tax"]["status"] == "complete"
      assert session["amount_subtotal"] == 2000
      assert session["total_details"]["amount_tax"] == 150
      assert session["amount_total"] == 2150

      assert [
               %{
                 "amount_tax" => 150,
                 "amount_total" => 2150,
                 "tax_amounts" => [%{"amount" => 150, "taxable_amount" => 2000}],
                 "taxes" => [%{"amount" => 150, "tax_behavior" => "exclusive", "taxable_amount" => 2000}]
               }
             ] = session["line_items"]

      complete_conn = request(:post, "/_test/checkout/sessions/#{session["id"]}/complete")
      completed = json_response(complete_conn)

      pi_conn = request(:get, "/v1/payment_intents/#{completed["payment_intent"]}")
      pi = json_response(pi_conn)
      assert pi["amount"] == 2150
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

  defp create_checkout_session(overrides \\ %{}) do
    params =
      Map.merge(
        %{
          "cancel_url" => "https://example.com/cancel",
          "line_items" => [price_data_line_item("Default", 1000, 1)],
          "mode" => "payment",
          "success_url" => "https://example.com/success"
        },
        overrides
      )

    request(:post, "/v1/checkout/sessions", params)
    |> json_response()
  end

  defp price_data_line_item(name, unit_amount, quantity) do
    %{
      "price_data" => %{
        "currency" => "usd",
        "product_data" => %{"name" => name},
        "unit_amount" => unit_amount
      },
      "quantity" => quantity
    }
  end
end
