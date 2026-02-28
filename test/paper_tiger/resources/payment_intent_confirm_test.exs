defmodule PaperTiger.Resources.PaymentIntentConfirmTest do
  @moduledoc """
  Tests for the POST /v1/payment_intents/:id/confirm endpoint.

  Verifies:
  1. Confirming a PI transitions it to "succeeded", creates a charge and balance transaction
  2. Confirming an already-succeeded PI returns 400
  3. Confirming a non-existent PI returns 404
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
          {"authorization", "Bearer sk_test_pi_confirm_key"}
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

  describe "POST /v1/payment_intents/:id/confirm" do
    test "confirms a PI and creates charge + balance transaction" do
      # Create customer
      cust_conn = request(:post, "/v1/customers", %{"email" => "confirm@example.com"})
      customer_id = json_response(cust_conn)["id"]

      # Create payment method
      pm_conn = request(:post, "/v1/payment_methods", %{"type" => "card"})
      pm_id = json_response(pm_conn)["id"]

      # Attach PM to customer
      request(:post, "/v1/payment_methods/#{pm_id}/attach", %{"customer" => customer_id})

      # Create PI with amount/currency/customer/payment_method
      pi_conn =
        request(:post, "/v1/payment_intents", %{
          "amount" => 5000,
          "currency" => "usd",
          "customer" => customer_id,
          "payment_method" => pm_id
        })

      assert pi_conn.status == 200
      pi = json_response(pi_conn)
      pi_id = pi["id"]
      assert pi["status"] == "requires_payment_method"

      # Confirm the PI
      confirm_conn = request(:post, "/v1/payment_intents/#{pi_id}/confirm")

      assert confirm_conn.status == 200
      confirmed = json_response(confirm_conn)
      assert confirmed["id"] == pi_id
      assert confirmed["status"] == "succeeded"
      assert confirmed["latest_charge"] != nil
      assert String.starts_with?(confirmed["latest_charge"], "ch_")

      # Verify charge is retrievable with correct fields
      ch_conn = request(:get, "/v1/charges/#{confirmed["latest_charge"]}")
      assert ch_conn.status == 200
      ch = json_response(ch_conn)
      assert ch["amount"] == 5000
      assert ch["currency"] == "usd"
      assert ch["payment_intent"] == pi_id
      assert ch["status"] == "succeeded"
      assert ch["customer"] == customer_id
      assert ch["payment_method"] == pm_id

      # Verify balance transaction exists
      assert ch["balance_transaction"] != nil
      assert String.starts_with?(ch["balance_transaction"], "txn_")
      bt_conn = request(:get, "/v1/balance_transactions/#{ch["balance_transaction"]}")
      assert bt_conn.status == 200
      bt = json_response(bt_conn)
      assert bt["amount"] == 5000
      assert bt["type"] == "charge"
    end

    test "returns error when confirming already succeeded PI" do
      # Create and confirm a PI
      pi_conn =
        request(:post, "/v1/payment_intents", %{
          "amount" => 1000,
          "currency" => "usd"
        })

      pi_id = json_response(pi_conn)["id"]

      # First confirm
      confirm_conn = request(:post, "/v1/payment_intents/#{pi_id}/confirm")
      assert confirm_conn.status == 200

      # Second confirm should fail
      retry_conn = request(:post, "/v1/payment_intents/#{pi_id}/confirm")
      assert retry_conn.status == 400
      error = json_response(retry_conn)
      assert error["error"]["type"] == "invalid_request_error"
      assert error["error"]["message"] =~ "does not allow confirmation"
    end

    test "returns 404 for non-existent PI" do
      conn = request(:post, "/v1/payment_intents/pi_nonexistent/confirm")

      assert conn.status == 404
      error = json_response(conn)
      assert error["error"]["type"] == "invalid_request_error"
    end
  end
end
