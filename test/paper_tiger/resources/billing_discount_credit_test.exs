defmodule PaperTiger.Resources.BillingDiscountCreditTest do
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
          {"authorization", "Bearer sk_test_billing_credit_key"}
        ] ++ sandbox_headers()

    Enum.reduce(headers_with_defaults, conn, fn {key, value}, acc ->
      Plug.Conn.put_req_header(acc, key, value)
    end)
  end

  defp request(method, path, params \\ nil, headers \\ []) do
    method
    |> conn(path, params, headers)
    |> Router.call([])
  end

  defp json_response(conn), do: Jason.decode!(conn.resp_body)

  describe "Promotion Codes" do
    test "creates, retrieves, updates, lists, and applies a promotion code to subscription invoices" do
      coupon = create_coupon(%{"id" => "coupon_50", "percent_off" => 50})

      create_conn =
        request(:post, "/v1/promotion_codes", %{
          "code" => "HALF-OFF",
          "promotion" => %{"coupon" => coupon["id"], "type" => "coupon"}
        })

      assert create_conn.status == 200
      promotion_code = json_response(create_conn)
      assert String.starts_with?(promotion_code["id"], "promo_")
      assert promotion_code["object"] == "promotion_code"
      assert promotion_code["active"] == true
      assert promotion_code["promotion"] == %{"coupon" => coupon["id"], "type" => "coupon"}

      retrieve_conn = request(:get, "/v1/promotion_codes/#{promotion_code["id"]}")
      assert retrieve_conn.status == 200
      assert json_response(retrieve_conn)["code"] == "HALF-OFF"

      update_conn =
        request(:post, "/v1/promotion_codes/#{promotion_code["id"]}", %{
          "metadata" => %{"campaign" => "spring"}
        })

      assert update_conn.status == 200
      assert json_response(update_conn)["metadata"] == %{"campaign" => "spring"}

      list_conn = request(:get, "/v1/promotion_codes?code=half-off")
      assert list_conn.status == 200
      assert [promotion_code["id"]] == Enum.map(json_response(list_conn)["data"], & &1["id"])

      customer = create_customer()
      price = create_price(1000)

      subscription_conn =
        request(:post, "/v1/subscriptions", %{
          "customer" => customer["id"],
          "items" => [%{"price" => price["id"], "quantity" => 1}],
          "payment_behavior" => "default_incomplete",
          "promotion_code" => promotion_code["id"]
        })

      assert subscription_conn.status == 200
      subscription = json_response(subscription_conn)
      assert subscription["discount"]["promotion_code"] == promotion_code["id"]
      assert subscription["discount"]["coupon"]["id"] == coupon["id"]

      invoice_conn = request(:get, "/v1/invoices/#{subscription["latest_invoice"]}")
      assert invoice_conn.status == 200
      invoice = json_response(invoice_conn)
      assert invoice["amount_remaining"] == 500
      assert invoice["total"] == 500
      assert invoice["total_details"]["amount_discount"] == 500
    end
  end

  describe "Customer Balance Transactions and Cash Balance" do
    test "mutates customer credit balance and applies it when an invoice is finalized" do
      customer = create_customer()

      transaction_conn =
        request(:post, "/v1/customers/#{customer["id"]}/balance_transactions", %{
          "amount" => -500,
          "currency" => "usd",
          "description" => "Test credit"
        })

      assert transaction_conn.status == 200
      transaction = json_response(transaction_conn)
      assert String.starts_with?(transaction["id"], "cbtxn_")
      assert transaction["amount"] == -500
      assert transaction["ending_balance"] == -500

      retrieve_txn_conn =
        request(:get, "/v1/customers/#{customer["id"]}/balance_transactions/#{transaction["id"]}")

      assert retrieve_txn_conn.status == 200
      assert json_response(retrieve_txn_conn)["id"] == transaction["id"]

      invoice = create_invoice(customer["id"], 1000)
      finalize_conn = request(:post, "/v1/invoices/#{invoice["id"]}/finalize")

      assert finalize_conn.status == 200
      finalized = json_response(finalize_conn)
      assert finalized["amount_due"] == 500
      assert finalized["amount_remaining"] == 500
      assert finalized["starting_balance"] == -500
      assert finalized["ending_balance"] == 0

      customer_conn = request(:get, "/v1/customers/#{customer["id"]}")
      assert json_response(customer_conn)["balance"] == 0
    end

    test "retrieves and updates cash balance settings" do
      customer = create_customer()

      retrieve_conn = request(:get, "/v1/customers/#{customer["id"]}/cash_balance")
      assert retrieve_conn.status == 200
      cash_balance = json_response(retrieve_conn)
      assert cash_balance["object"] == "cash_balance"
      assert cash_balance["available"] == %{}
      assert cash_balance["settings"]["reconciliation_mode"] == "automatic"

      update_conn =
        request(:post, "/v1/customers/#{customer["id"]}/cash_balance", %{
          "settings" => %{"reconciliation_mode" => "manual"}
        })

      assert update_conn.status == 200
      assert json_response(update_conn)["settings"]["reconciliation_mode"] == "manual"
    end
  end

  describe "Credit Notes" do
    test "creates, previews, lists lines, and voids a pre-payment credit note" do
      customer = create_customer()
      invoice = customer["id"] |> create_invoice(1000) |> finalize_invoice()

      preview_conn = request(:get, "/v1/credit_notes/preview?invoice=#{invoice["id"]}&amount=400")
      assert preview_conn.status == 200
      preview = json_response(preview_conn)
      assert preview["object"] == "credit_note"
      assert preview["id"] == nil
      assert preview["amount"] == 400

      create_conn =
        request(:post, "/v1/credit_notes", %{
          "amount" => 400,
          "invoice" => invoice["id"],
          "reason" => "order_change"
        })

      assert create_conn.status == 200
      credit_note = json_response(create_conn)
      assert String.starts_with?(credit_note["id"], "cn_")
      assert credit_note["pre_payment_amount"] == 400
      assert credit_note["post_payment_amount"] == 0
      assert credit_note["status"] == "issued"

      invoice_conn = request(:get, "/v1/invoices/#{invoice["id"]}")
      adjusted_invoice = json_response(invoice_conn)
      assert adjusted_invoice["amount_due"] == 600
      assert adjusted_invoice["amount_remaining"] == 600
      assert adjusted_invoice["pre_payment_credit_notes_amount"] == 400

      lines_conn = request(:get, "/v1/credit_notes/#{credit_note["id"]}/lines")
      assert lines_conn.status == 200
      assert [%{"object" => "credit_note_line_item"}] = json_response(lines_conn)["data"]

      void_conn = request(:post, "/v1/credit_notes/#{credit_note["id"]}/void")
      assert void_conn.status == 200
      assert json_response(void_conn)["status"] == "void"
    end

    test "credits customer balance for post-payment credit notes" do
      customer = create_customer()
      invoice = customer["id"] |> create_invoice(1000) |> finalize_invoice() |> pay_invoice()

      create_conn =
        request(:post, "/v1/credit_notes", %{
          "amount" => 300,
          "credit_amount" => 300,
          "invoice" => invoice["id"]
        })

      assert create_conn.status == 200
      credit_note = json_response(create_conn)
      assert credit_note["pre_payment_amount"] == 0
      assert credit_note["post_payment_amount"] == 300
      assert String.starts_with?(credit_note["customer_balance_transaction"], "cbtxn_")

      customer_conn = request(:get, "/v1/customers/#{customer["id"]}")
      assert json_response(customer_conn)["balance"] == -300
    end
  end

  defp create_customer do
    conn = request(:post, "/v1/customers", %{"email" => "credit@example.test"})
    assert conn.status == 200
    json_response(conn)
  end

  defp create_coupon(attrs) do
    params = Map.merge(%{"duration" => "forever"}, attrs)
    conn = request(:post, "/v1/coupons", params)
    assert conn.status == 200
    json_response(conn)
  end

  defp create_price(amount) do
    product_conn = request(:post, "/v1/products", %{"name" => "Discounted Product"})
    assert product_conn.status == 200
    product = json_response(product_conn)

    price_conn =
      request(:post, "/v1/prices", %{
        "currency" => "usd",
        "product" => product["id"],
        "recurring" => %{"interval" => "month"},
        "unit_amount" => amount
      })

    assert price_conn.status == 200
    json_response(price_conn)
  end

  defp create_invoice(customer_id, amount) do
    conn =
      request(:post, "/v1/invoices", %{
        "amount_due" => amount,
        "amount_remaining" => amount,
        "currency" => "usd",
        "customer" => customer_id,
        "status" => "draft",
        "subtotal" => amount,
        "total" => amount
      })

    assert conn.status == 200
    json_response(conn)
  end

  defp finalize_invoice(invoice) do
    conn = request(:post, "/v1/invoices/#{invoice["id"]}/finalize")
    assert conn.status == 200
    json_response(conn)
  end

  defp pay_invoice(invoice) do
    conn = request(:post, "/v1/invoices/#{invoice["id"]}/pay")
    assert conn.status == 200
    json_response(conn)
  end
end
