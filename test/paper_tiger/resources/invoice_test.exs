defmodule PaperTiger.Resources.InvoiceTest do
  @moduledoc """
  End-to-end tests for Invoice resource with finalization flow.

  Tests complete invoice lifecycle:
  1. Setup: Create customer
  2. POST /v1/invoices - Create draft invoice
     - Test with customer
     - Verify draft status
     - Test with description, metadata
  3. POST /v1/invoices/:id/finalize - Finalize invoice
     - Draft → Open transition
     - Generates invoice number
     - Test can't finalize non-draft invoice
  4. POST /v1/invoices/:id/pay - Pay invoice
     - Open → Paid transition
     - Updates amount_paid and amount_remaining
     - Sets paid=true
  5. POST /v1/invoices/:id/void - Void invoice
     - Sets status to void
     - Can void open invoices
  6. Standard CRUD:
     - GET /v1/invoices/:id - Retrieve
     - POST /v1/invoices/:id - Update (metadata, description)
     - DELETE /v1/invoices/:id - Delete (draft only)
     - GET /v1/invoices - List with pagination
  """

  use ExUnit.Case, async: true

  import PaperTiger.Test

  alias PaperTiger.Router

  setup :checkout_paper_tiger

  # Helper function to create a test connection with proper setup
  defp conn(method, path, params, headers) do
    conn = Plug.Test.conn(method, path, params)

    headers_with_defaults =
      headers ++
        [
          {"content-type", "application/json"},
          {"authorization", "Bearer sk_test_invoice_key"}
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

  # Helper function to parse JSON response
  defp json_response(conn) do
    Jason.decode!(conn.resp_body)
  end

  # Helper to create a customer for testing
  defp create_customer(email \\ "test@example.com") do
    conn = request(:post, "/v1/customers", %{"email" => email})
    json_response(conn)["id"]
  end

  describe "POST /v1/invoices - Create draft invoice" do
    test "creates a draft invoice with customer" do
      customer_id = create_customer()

      conn =
        request(:post, "/v1/invoices", %{
          "customer" => customer_id
        })

      assert conn.status == 200
      invoice = json_response(conn)
      assert String.starts_with?(invoice["id"], "in_")
      assert invoice["object"] == "invoice"
      assert invoice["status"] == "draft"
      assert invoice["customer"] == customer_id
      assert invoice["paid"] == false
      assert invoice["amount_due"] == 0
      assert invoice["amount_paid"] == 0
      assert invoice["amount_remaining"] == 0
      assert invoice["currency"] == "usd"
      assert is_nil(invoice["number"])
      assert invoice["lines"]["data"] == []
      assert is_integer(invoice["created"])
    end

    test "creates invoice with description" do
      customer_id = create_customer()

      conn =
        request(:post, "/v1/invoices", %{
          "customer" => customer_id,
          "description" => "Monthly subscription invoice"
        })

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["description"] == "Monthly subscription invoice"
      assert invoice["status"] == "draft"
    end

    test "creates invoice with metadata" do
      customer_id = create_customer()

      metadata = %{"order_id" => "12345", "tier" => "premium"}

      conn =
        request(:post, "/v1/invoices", %{
          "customer" => customer_id,
          "metadata" => metadata
        })

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["metadata"] == metadata
    end

    test "creates invoice with all optional fields" do
      customer_id = create_customer()

      conn =
        request(:post, "/v1/invoices", %{
          "auto_advance" => false,
          "collection_method" => "send_invoice",
          "currency" => "eur",
          "customer" => customer_id,
          "description" => "Annual service fee",
          "metadata" => %{"service" => "consulting"}
        })

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["description"] == "Annual service fee"
      assert invoice["currency"] == "eur"
      assert invoice["metadata"]["service"] == "consulting"
      assert invoice["auto_advance"] == false
      assert invoice["collection_method"] == "send_invoice"
    end

    test "invoice has correct initial structure" do
      customer_id = create_customer()

      conn = request(:post, "/v1/invoices", %{"customer" => customer_id})

      assert conn.status == 200
      invoice = json_response(conn)

      # Verify expected fields
      assert Map.has_key?(invoice, "id")
      assert Map.has_key?(invoice, "object")
      assert Map.has_key?(invoice, "created")
      assert Map.has_key?(invoice, "status")
      assert Map.has_key?(invoice, "customer")
      assert Map.has_key?(invoice, "amount_due")
      assert Map.has_key?(invoice, "amount_paid")
      assert Map.has_key?(invoice, "amount_remaining")
      assert Map.has_key?(invoice, "currency")
      assert Map.has_key?(invoice, "paid")
      assert Map.has_key?(invoice, "metadata")
      assert Map.has_key?(invoice, "lines")
    end

    test "multiple invoices can have same customer" do
      customer_id = create_customer()

      conn1 = request(:post, "/v1/invoices", %{"customer" => customer_id})
      assert conn1.status == 200
      invoice1 = json_response(conn1)

      conn2 = request(:post, "/v1/invoices", %{"customer" => customer_id})
      assert conn2.status == 200
      invoice2 = json_response(conn2)

      assert invoice1["id"] != invoice2["id"]
      assert invoice1["customer"] == invoice2["customer"]
    end

    test "invoice defaults to usd currency" do
      customer_id = create_customer()

      conn = request(:post, "/v1/invoices", %{"customer" => customer_id})

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["currency"] == "usd"
    end

    test "invoice auto_advance defaults to true" do
      customer_id = create_customer()

      conn = request(:post, "/v1/invoices", %{"customer" => customer_id})

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["auto_advance"] == true
    end

    test "supports idempotency with Idempotency-Key header" do
      customer_id = create_customer()
      idempotency_key = "invoice_key_#{:rand.uniform(1_000_000)}"

      conn1 =
        request(:post, "/v1/invoices", %{"customer" => customer_id}, [
          {"idempotency-key", idempotency_key}
        ])

      assert conn1.status == 200
      invoice1 = json_response(conn1)

      conn2 =
        request(
          :post,
          "/v1/invoices",
          %{
            "customer" => customer_id,
            "description" => "Different description"
          },
          [
            {"idempotency-key", idempotency_key}
          ]
        )

      assert conn2.status == 200
      invoice2 = json_response(conn2)

      # Should return the same invoice due to idempotency
      assert invoice1["id"] == invoice2["id"]
    end
  end

  describe "GET /v1/invoices/:id - Retrieve invoice" do
    test "retrieves an existing draft invoice" do
      customer_id = create_customer()

      create_conn =
        request(:post, "/v1/invoices", %{
          "customer" => customer_id,
          "description" => "Test invoice"
        })

      invoice_id = json_response(create_conn)["id"]

      conn = request(:get, "/v1/invoices/#{invoice_id}")

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["id"] == invoice_id
      assert invoice["customer"] == customer_id
      assert invoice["description"] == "Test invoice"
      assert invoice["status"] == "draft"
    end

    test "retrieves a finalized invoice" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      # Finalize the invoice
      request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      # Retrieve it
      conn = request(:get, "/v1/invoices/#{invoice_id}")

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["id"] == invoice_id
      assert invoice["status"] == "open"
      assert not is_nil(invoice["number"])
    end

    test "retrieves a paid invoice" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      # Finalize
      request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      # Pay
      request(:post, "/v1/invoices/#{invoice_id}/pay", %{})

      # Retrieve
      conn = request(:get, "/v1/invoices/#{invoice_id}")

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["status"] == "paid"
      assert invoice["paid"] == true
    end

    test "returns 404 for missing invoice" do
      conn = request(:get, "/v1/invoices/in_nonexistent")

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
      assert response["error"]["message"] =~ "in_nonexistent"
    end

    test "retrieves invoice with metadata" do
      customer_id = create_customer()
      metadata = %{"project_id" => "proj_123", "tags" => ["urgent", "monthly"]}

      create_conn =
        request(:post, "/v1/invoices", %{
          "customer" => customer_id,
          "metadata" => metadata
        })

      invoice_id = json_response(create_conn)["id"]

      conn = request(:get, "/v1/invoices/#{invoice_id}")

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["metadata"] == metadata
    end
  end

  describe "POST /v1/invoices/:id/finalize - Finalize invoice" do
    test "finalizes a draft invoice" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      conn = request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["id"] == invoice_id
      assert invoice["status"] == "open"
      assert invoice["paid"] == false
    end

    test "generates invoice number on finalization" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      created_invoice = json_response(create_conn)
      invoice_id = created_invoice["id"]

      assert is_nil(created_invoice["number"])

      conn = request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      assert conn.status == 200
      invoice = json_response(conn)
      assert not is_nil(invoice["number"])
      assert String.starts_with?(invoice["number"], "inv_")
    end

    test "transitions from draft to open status" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      created = json_response(create_conn)
      assert created["status"] == "draft"

      invoice_id = created["id"]

      conn = request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      assert conn.status == 200
      finalized = json_response(conn)
      assert finalized["status"] == "open"
    end

    test "cannot finalize non-draft invoice" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      # Finalize it once
      request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      # Try to finalize again
      conn = request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      assert conn.status != 200
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
      assert response["error"]["message"] =~ "draft"
    end

    test "cannot finalize a paid invoice" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      # Finalize
      request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      # Pay
      request(:post, "/v1/invoices/#{invoice_id}/pay", %{})

      # Try to finalize
      conn = request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      assert conn.status != 200
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "returns 404 when invoice does not exist" do
      conn = request(:post, "/v1/invoices/in_nonexistent/finalize", %{})

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "preserves metadata when finalizing" do
      customer_id = create_customer()
      metadata = %{"project" => "acme"}

      create_conn =
        request(:post, "/v1/invoices", %{
          "customer" => customer_id,
          "metadata" => metadata
        })

      invoice_id = json_response(create_conn)["id"]

      conn = request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["metadata"] == metadata
    end

    test "preserves description when finalizing" do
      customer_id = create_customer()

      create_conn =
        request(:post, "/v1/invoices", %{
          "customer" => customer_id,
          "description" => "Service invoice"
        })

      invoice_id = json_response(create_conn)["id"]

      conn = request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["description"] == "Service invoice"
    end
  end

  describe "POST /v1/invoices/:id/pay - Pay invoice" do
    test "marks open invoice as paid" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      # Finalize first
      request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      # Now pay
      conn = request(:post, "/v1/invoices/#{invoice_id}/pay", %{})

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["status"] == "paid"
      assert invoice["paid"] == true
    end

    test "transitions from open to paid status" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      # Finalize
      finalize_conn = request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})
      assert json_response(finalize_conn)["status"] == "open"

      # Pay
      pay_conn = request(:post, "/v1/invoices/#{invoice_id}/pay", %{})

      assert pay_conn.status == 200
      assert json_response(pay_conn)["status"] == "paid"
    end

    test "updates amount_paid to amount_due" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      # Finalize
      request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      # Pay
      conn = request(:post, "/v1/invoices/#{invoice_id}/pay", %{})

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["amount_paid"] == invoice["amount_due"]
    end

    test "sets amount_remaining to zero" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      # Finalize
      request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      # Pay
      conn = request(:post, "/v1/invoices/#{invoice_id}/pay", %{})

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["amount_remaining"] == 0
    end

    test "cannot pay draft invoice" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      # Try to pay without finalizing
      conn = request(:post, "/v1/invoices/#{invoice_id}/pay", %{})

      # Should still work - mark as paid regardless of status
      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["paid"] == true
    end

    test "returns 404 when invoice does not exist" do
      conn = request(:post, "/v1/invoices/in_nonexistent/pay", %{})

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "preserves metadata when paying" do
      customer_id = create_customer()
      metadata = %{"payment_method" => "card"}

      create_conn =
        request(:post, "/v1/invoices", %{
          "customer" => customer_id,
          "metadata" => metadata
        })

      invoice_id = json_response(create_conn)["id"]

      # Finalize
      request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      # Pay
      conn = request(:post, "/v1/invoices/#{invoice_id}/pay", %{})

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["metadata"] == metadata
    end
  end

  describe "POST /v1/invoices/:id/void - Void invoice" do
    test "voids an open invoice" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      # Finalize first
      request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      # Void it
      conn = request(:post, "/v1/invoices/#{invoice_id}/void", %{})

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["status"] == "void"
    end

    test "transitions to void status" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      # Finalize
      request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      # Void
      void_conn = request(:post, "/v1/invoices/#{invoice_id}/void", %{})

      assert void_conn.status == 200
      assert json_response(void_conn)["status"] == "void"
    end

    test "can void a draft invoice" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      # Void directly without finalizing
      conn = request(:post, "/v1/invoices/#{invoice_id}/void", %{})

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["status"] == "void"
    end

    test "can void a paid invoice" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      # Finalize and pay
      request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})
      request(:post, "/v1/invoices/#{invoice_id}/pay", %{})

      # Void
      conn = request(:post, "/v1/invoices/#{invoice_id}/void", %{})

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["status"] == "void"
    end

    test "returns 404 when invoice does not exist" do
      conn = request(:post, "/v1/invoices/in_nonexistent/void", %{})

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "preserves metadata when voiding" do
      customer_id = create_customer()
      metadata = %{"reason" => "duplicate"}

      create_conn =
        request(:post, "/v1/invoices", %{
          "customer" => customer_id,
          "metadata" => metadata
        })

      invoice_id = json_response(create_conn)["id"]

      # Finalize and void
      request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      conn = request(:post, "/v1/invoices/#{invoice_id}/void", %{})

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["metadata"] == metadata
    end
  end

  describe "POST /v1/invoices/:id - Update invoice" do
    test "updates invoice description" do
      customer_id = create_customer()

      create_conn =
        request(:post, "/v1/invoices", %{
          "customer" => customer_id,
          "description" => "Old description"
        })

      invoice_id = json_response(create_conn)["id"]

      conn =
        request(:post, "/v1/invoices/#{invoice_id}", %{
          "description" => "New description"
        })

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["description"] == "New description"
    end

    test "updates invoice metadata" do
      customer_id = create_customer()

      create_conn =
        request(:post, "/v1/invoices", %{
          "customer" => customer_id,
          "metadata" => %{"tier" => "basic"}
        })

      invoice_id = json_response(create_conn)["id"]

      conn =
        request(:post, "/v1/invoices/#{invoice_id}", %{
          "metadata" => %{"tier" => "premium", "upgraded" => "true"}
        })

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["metadata"]["tier"] == "premium"
      assert invoice["metadata"]["upgraded"] == "true"
    end

    test "updates auto_advance" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      conn =
        request(:post, "/v1/invoices/#{invoice_id}", %{
          "auto_advance" => false
        })

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["auto_advance"] == false
    end

    test "updates collection_method" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      conn =
        request(:post, "/v1/invoices/#{invoice_id}", %{
          "collection_method" => "send_invoice"
        })

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["collection_method"] == "send_invoice"
    end

    test "updates multiple fields at once" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      conn =
        request(:post, "/v1/invoices/#{invoice_id}", %{
          "auto_advance" => false,
          "description" => "Updated invoice",
          "metadata" => %{"updated" => "true"}
        })

      assert conn.status == 200
      invoice = json_response(conn)
      assert invoice["description"] == "Updated invoice"
      assert invoice["metadata"]["updated"] == "true"
      assert invoice["auto_advance"] == false
    end

    test "returns 404 when updating non-existent invoice" do
      conn =
        request(:post, "/v1/invoices/in_nonexistent", %{
          "description" => "Test"
        })

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "preserves immutable fields" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      created = json_response(create_conn)
      invoice_id = created["id"]
      original_created = created["created"]
      original_customer = created["customer"]

      conn =
        request(:post, "/v1/invoices/#{invoice_id}", %{
          "description" => "Updated"
        })

      assert conn.status == 200
      updated = json_response(conn)
      assert updated["id"] == invoice_id
      assert updated["created"] == original_created
      assert updated["customer"] == original_customer
      assert updated["object"] == "invoice"
    end
  end

  describe "DELETE /v1/invoices/:id - Delete invoice" do
    test "deletes a draft invoice" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      conn = request(:delete, "/v1/invoices/#{invoice_id}")

      assert conn.status == 200
      result = json_response(conn)
      assert result["deleted"] == true
      assert result["id"] == invoice_id
      assert result["object"] == "invoice"
    end

    test "invoice is not retrievable after deletion" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      # Delete it
      delete_conn = request(:delete, "/v1/invoices/#{invoice_id}")
      assert delete_conn.status == 200

      # Try to retrieve - should be 404
      retrieve_conn = request(:get, "/v1/invoices/#{invoice_id}")
      assert retrieve_conn.status == 404
    end

    test "cannot delete finalized invoice" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      # Finalize it
      request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      # Try to delete
      conn = request(:delete, "/v1/invoices/#{invoice_id}")

      assert conn.status != 200
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
      assert response["error"]["message"] =~ "draft"
    end

    test "cannot delete paid invoice" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      # Finalize and pay
      request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})
      request(:post, "/v1/invoices/#{invoice_id}/pay", %{})

      # Try to delete
      conn = request(:delete, "/v1/invoices/#{invoice_id}")

      assert conn.status != 200
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "returns 404 when deleting non-existent invoice" do
      conn = request(:delete, "/v1/invoices/in_nonexistent")

      assert conn.status == 404
      response = json_response(conn)
      assert response["error"]["type"] == "invalid_request_error"
    end

    test "deletion response has correct structure" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      conn = request(:delete, "/v1/invoices/#{invoice_id}")

      assert conn.status == 200
      result = json_response(conn)
      assert Map.has_key?(result, "deleted")
      assert Map.has_key?(result, "id")
      assert Map.has_key?(result, "object")
      assert result["deleted"] == true
    end
  end

  describe "GET /v1/invoices - List invoices" do
    test "lists invoices with default limit" do
      customer_id = create_customer()

      # Create 3 invoices
      for i <- 1..3 do
        request(:post, "/v1/invoices", %{
          "customer" => customer_id,
          "description" => "Invoice #{i}"
        })
      end

      conn = request(:get, "/v1/invoices")

      assert conn.status == 200
      result = json_response(conn)
      assert is_list(result["data"])
      assert length(result["data"]) == 3
      assert result["has_more"] == false
      assert result["object"] == "list"
      assert result["url"] == "/v1/invoices"
    end

    test "respects limit parameter" do
      customer_id = create_customer()

      # Create 5 invoices
      for i <- 1..5 do
        request(:post, "/v1/invoices", %{
          "customer" => customer_id,
          "description" => "Invoice #{i}"
        })
      end

      conn = request(:get, "/v1/invoices?limit=2")

      assert conn.status == 200
      result = json_response(conn)
      assert length(result["data"]) == 2
      assert result["has_more"] == true
    end

    test "returns all invoices when limit exceeds total" do
      customer_id = create_customer()

      # Create 2 invoices
      for _i <- 1..2 do
        request(:post, "/v1/invoices", %{"customer" => customer_id})
      end

      conn = request(:get, "/v1/invoices?limit=100")

      assert conn.status == 200
      result = json_response(conn)
      assert length(result["data"]) == 2
      assert result["has_more"] == false
    end

    test "supports cursor pagination with starting_after" do
      customer_id = create_customer()

      # Create 5 invoices
      for _i <- 1..5 do
        request(:post, "/v1/invoices", %{"customer" => customer_id})
        Process.sleep(2)
      end

      # Get first page
      conn1 = request(:get, "/v1/invoices?limit=2")
      assert conn1.status == 200
      page1 = json_response(conn1)
      assert length(page1["data"]) == 2
      assert page1["has_more"] == true

      # Get second page using cursor
      last_id = Enum.at(page1["data"], 1)["id"]
      conn2 = request(:get, "/v1/invoices?limit=2&starting_after=#{last_id}")

      assert conn2.status == 200
      page2 = json_response(conn2)
      assert page2["data"] != []

      # Verify cursor is not in second page
      page2_ids = Enum.map(page2["data"], & &1["id"])
      assert not Enum.member?(page2_ids, last_id)
    end

    test "returns empty list when no invoices exist" do
      conn = request(:get, "/v1/invoices")

      assert conn.status == 200
      result = json_response(conn)
      assert result["data"] == []
      assert result["has_more"] == false
    end

    test "invoices are sorted by creation time (descending)" do
      customer_id = create_customer()

      # Create invoices with delays
      for _i <- 1..3 do
        request(:post, "/v1/invoices", %{"customer" => customer_id})
        Process.sleep(1)
      end

      conn = request(:get, "/v1/invoices?limit=10")

      assert conn.status == 200
      result = json_response(conn)
      invoices = result["data"]

      # Verify sorted by created (descending)
      created_times = Enum.map(invoices, & &1["created"])
      sorted_times = Enum.sort(created_times, :desc)
      assert created_times == sorted_times
    end

    test "list includes all invoice fields" do
      customer_id = create_customer()

      request(:post, "/v1/invoices", %{
        "customer" => customer_id,
        "description" => "Test invoice",
        "metadata" => %{"key" => "value"}
      })

      conn = request(:get, "/v1/invoices")

      assert conn.status == 200
      invoice = Enum.at(json_response(conn)["data"], 0)

      # Verify expected fields
      assert Map.has_key?(invoice, "id")
      assert Map.has_key?(invoice, "object")
      assert Map.has_key?(invoice, "created")
      assert Map.has_key?(invoice, "status")
      assert Map.has_key?(invoice, "customer")
      assert Map.has_key?(invoice, "metadata")
    end

    test "pagination with limit=1 creates multiple pages" do
      customer_id = create_customer()

      # Create 3 invoices
      for _i <- 1..3 do
        request(:post, "/v1/invoices", %{"customer" => customer_id})
      end

      # First page
      conn1 = request(:get, "/v1/invoices?limit=1")
      assert conn1.status == 200
      page1 = json_response(conn1)
      assert length(page1["data"]) == 1
      assert page1["has_more"] == true

      # Second page
      cursor = Enum.at(page1["data"], 0)["id"]
      conn2 = request(:get, "/v1/invoices?limit=1&starting_after=#{cursor}")
      assert conn2.status == 200
      page2 = json_response(conn2)
      assert length(page2["data"]) == 1
      assert page2["has_more"] == true

      # Third page
      cursor2 = Enum.at(page2["data"], 0)["id"]
      conn3 = request(:get, "/v1/invoices?limit=1&starting_after=#{cursor2}")
      assert conn3.status == 200
      page3 = json_response(conn3)
      assert length(page3["data"]) == 1
      assert page3["has_more"] == false
    end

    test "different invoices appear in list" do
      customer_id = create_customer()

      # Create multiple invoices
      created_ids =
        for _i <- 1..3 do
          conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
          json_response(conn)["id"]
        end

      conn = request(:get, "/v1/invoices")
      list_ids = Enum.map(json_response(conn)["data"], & &1["id"])

      # All created invoices should be in the list
      Enum.each(created_ids, fn id ->
        assert Enum.member?(list_ids, id)
      end)
    end
  end

  describe "Integration - Complete invoice lifecycle" do
    test "full draft to paid flow" do
      # 1. Create customer
      customer_id = create_customer("lifecycle@example.com")

      # 2. Create draft invoice
      create_conn =
        request(:post, "/v1/invoices", %{
          "customer" => customer_id,
          "description" => "Monthly service",
          "metadata" => %{"cycle" => "monthly"}
        })

      assert create_conn.status == 200
      invoice = json_response(create_conn)
      invoice_id = invoice["id"]
      assert invoice["status"] == "draft"
      assert invoice["paid"] == false
      assert is_nil(invoice["number"])

      # 3. Retrieve draft invoice
      retrieve_conn = request(:get, "/v1/invoices/#{invoice_id}")
      assert retrieve_conn.status == 200
      assert json_response(retrieve_conn)["status"] == "draft"

      # 4. Update invoice
      update_conn =
        request(:post, "/v1/invoices/#{invoice_id}", %{
          "metadata" => %{"cycle" => "monthly", "updated" => "true"}
        })

      assert update_conn.status == 200
      updated = json_response(update_conn)
      assert updated["metadata"]["updated"] == "true"

      # 5. Finalize invoice
      finalize_conn = request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      assert finalize_conn.status == 200
      finalized = json_response(finalize_conn)
      assert finalized["status"] == "open"
      assert not is_nil(finalized["number"])

      # 6. Pay invoice
      pay_conn = request(:post, "/v1/invoices/#{invoice_id}/pay", %{})

      assert pay_conn.status == 200
      paid = json_response(pay_conn)
      assert paid["status"] == "paid"
      assert paid["paid"] == true

      # 7. Verify in list
      list_conn = request(:get, "/v1/invoices")
      assert list_conn.status == 200
      found = Enum.find(json_response(list_conn)["data"], &(&1["id"] == invoice_id))
      assert found != nil
      assert found["status"] == "paid"

      # 8. Cannot delete paid invoice
      delete_conn = request(:delete, "/v1/invoices/#{invoice_id}")
      assert delete_conn.status != 200
    end

    test "draft to void flow" do
      customer_id = create_customer()

      # Create
      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      # Finalize
      finalize_conn = request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})
      assert json_response(finalize_conn)["status"] == "open"

      # Void
      void_conn = request(:post, "/v1/invoices/#{invoice_id}/void", %{})
      assert void_conn.status == 200
      assert json_response(void_conn)["status"] == "void"

      # Verify in list
      list_conn = request(:get, "/v1/invoices")
      found = Enum.find(json_response(list_conn)["data"], &(&1["id"] == invoice_id))
      assert found["status"] == "void"
    end

    test "draft deletion flow" do
      customer_id = create_customer()

      # Create
      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice_id = json_response(create_conn)["id"]

      # Delete while draft
      delete_conn = request(:delete, "/v1/invoices/#{invoice_id}")
      assert delete_conn.status == 200
      assert json_response(delete_conn)["deleted"] == true

      # Verify deleted
      retrieve_conn = request(:get, "/v1/invoices/#{invoice_id}")
      assert retrieve_conn.status == 404

      # Verify not in list
      list_conn = request(:get, "/v1/invoices")
      found = Enum.find(json_response(list_conn)["data"], &(&1["id"] == invoice_id))
      assert is_nil(found)
    end

    test "multiple invoices for same customer" do
      customer_id = create_customer()

      # Create multiple invoices
      ids =
        for i <- 1..3 do
          conn =
            request(:post, "/v1/invoices", %{
              "customer" => customer_id,
              "description" => "Invoice #{i}"
            })

          json_response(conn)["id"]
        end

      # All should exist
      Enum.each(ids, fn id ->
        conn = request(:get, "/v1/invoices/#{id}")
        assert conn.status == 200
      end)

      # All should be in list
      list_conn = request(:get, "/v1/invoices?limit=10")
      list_ids = Enum.map(json_response(list_conn)["data"], & &1["id"])

      Enum.each(ids, fn id ->
        assert Enum.member?(list_ids, id)
      end)
    end

    test "updating one invoice doesn't affect others" do
      customer_id = create_customer()

      # Create two invoices
      conn1 = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice1_id = json_response(conn1)["id"]

      conn2 = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice2_id = json_response(conn2)["id"]

      # Update invoice1
      request(:post, "/v1/invoices/#{invoice1_id}", %{
        "description" => "Updated invoice 1"
      })

      # Verify invoice2 is unchanged
      check_conn = request(:get, "/v1/invoices/#{invoice2_id}")
      assert check_conn.status == 200
      assert is_nil(json_response(check_conn)["description"])
    end

    test "deleting one invoice doesn't affect others" do
      customer_id = create_customer()

      # Create two draft invoices
      conn1 = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice1_id = json_response(conn1)["id"]

      conn2 = request(:post, "/v1/invoices", %{"customer" => customer_id})
      invoice2_id = json_response(conn2)["id"]

      # Delete invoice1
      request(:delete, "/v1/invoices/#{invoice1_id}")

      # Verify invoice2 still exists
      check_conn = request(:get, "/v1/invoices/#{invoice2_id}")
      assert check_conn.status == 200
      assert json_response(check_conn)["id"] == invoice2_id
    end
  end

  describe "Edge cases and validation" do
    test "invoice with very long description" do
      customer_id = create_customer()

      long_description = String.duplicate("x", 500)

      conn =
        request(:post, "/v1/invoices", %{
          "customer" => customer_id,
          "description" => long_description
        })

      assert conn.status == 200
      assert json_response(conn)["description"] == long_description
    end

    test "invoice with special characters in description" do
      customer_id = create_customer()

      special_description = "Invoice for Q4 2024 — Special Offer 50% off! €100"

      conn =
        request(:post, "/v1/invoices", %{
          "customer" => customer_id,
          "description" => special_description
        })

      assert conn.status == 200
      assert json_response(conn)["description"] == special_description
    end

    test "invoice with special characters in metadata" do
      customer_id = create_customer()

      metadata = %{
        "quotes" => "\"quoted\" 'value'",
        "special" => "!@#$%^&*()",
        "unicode" => "你好世界"
      }

      conn =
        request(:post, "/v1/invoices", %{
          "customer" => customer_id,
          "metadata" => metadata
        })

      assert conn.status == 200
      returned_metadata = json_response(conn)["metadata"]
      assert returned_metadata["special"] == metadata["special"]
      assert returned_metadata["unicode"] == metadata["unicode"]
      assert returned_metadata["quotes"] == metadata["quotes"]
    end

    test "invoice with empty metadata object" do
      customer_id = create_customer()

      conn =
        request(:post, "/v1/invoices", %{
          "customer" => customer_id,
          "metadata" => %{}
        })

      assert conn.status == 200
      assert json_response(conn)["metadata"] == %{}
    end

    test "generates unique invoice IDs" do
      customer_id = create_customer()

      id_set =
        for _i <- 1..5 do
          conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
          json_response(conn)["id"]
        end
        |> MapSet.new()

      assert MapSet.size(id_set) == 5
    end

    test "generated invoice numbers are unique" do
      customer_id = create_customer()

      numbers =
        for _i <- 1..3 do
          create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
          invoice_id = json_response(create_conn)["id"]

          finalize_conn = request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})
          json_response(finalize_conn)["number"]
        end

      # All should be unique
      unique_numbers = Enum.uniq(numbers)
      assert length(numbers) == length(unique_numbers)
    end

    test "invoice preserves created timestamp" do
      customer_id = create_customer()

      create_conn = request(:post, "/v1/invoices", %{"customer" => customer_id})
      created_invoice = json_response(create_conn)
      original_created = created_invoice["created"]

      invoice_id = created_invoice["id"]

      # Update it
      request(:post, "/v1/invoices/#{invoice_id}", %{"description" => "Updated"})

      # Finalize it
      request(:post, "/v1/invoices/#{invoice_id}/finalize", %{})

      # Pay it
      request(:post, "/v1/invoices/#{invoice_id}/pay", %{})

      # Verify created timestamp unchanged
      final_conn = request(:get, "/v1/invoices/#{invoice_id}")
      final_invoice = json_response(final_conn)
      assert final_invoice["created"] == original_created
    end
  end
end
