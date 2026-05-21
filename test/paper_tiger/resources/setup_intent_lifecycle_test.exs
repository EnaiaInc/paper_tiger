defmodule PaperTiger.Resources.SetupIntentLifecycleTest do
  use ExUnit.Case, async: true

  import PaperTiger.Test

  alias PaperTiger.Router

  setup :checkout_paper_tiger

  defp request(method, path, params \\ %{}) do
    conn = Plug.Test.conn(method, path, params)

    [{"content-type", "application/json"}, {"authorization", "Bearer sk_test_setup_intent_key"}]
    |> Kernel.++(sandbox_headers())
    |> Enum.reduce(conn, fn {key, value}, acc -> Plug.Conn.put_req_header(acc, key, value) end)
    |> Router.call([])
  end

  defp json_response(conn), do: Jason.decode!(conn.resp_body)

  describe "POST /v1/setup_intents/:id/confirm" do
    test "succeeds a card setup intent, attaches the payment method, and records an attempt" do
      customer_id = create_customer_id()

      setup_intent =
        request(:post, "/v1/setup_intents", %{
          "customer" => customer_id,
          "payment_method" => "pm_card_visa"
        })
        |> json_response()

      conn = request(:post, "/v1/setup_intents/#{setup_intent["id"]}/confirm")

      assert conn.status == 200
      confirmed = json_response(conn)
      assert confirmed["status"] == "succeeded"
      assert confirmed["customer"] == customer_id
      assert confirmed["payment_method"] != "pm_card_visa"
      assert String.starts_with?(confirmed["payment_method"], "pm_")
      assert String.starts_with?(confirmed["latest_attempt"], "setatt_")
      assert is_nil(confirmed["last_setup_error"])
      assert is_nil(confirmed["next_action"])

      payment_method =
        request(:get, "/v1/payment_methods/#{confirmed["payment_method"]}")
        |> json_response()

      assert payment_method["customer"] == customer_id

      attempts = list_attempts(confirmed["id"])
      assert attempts["object"] == "list"
      assert attempts["has_more"] == false

      assert [
               %{
                 "object" => "setup_attempt",
                 "status" => "succeeded"
               }
             ] = attempts["data"]

      assert hd(attempts["data"])["payment_method"] == confirmed["payment_method"]
      assert hd(attempts["data"])["payment_method_details"]["type"] == "card"
    end

    test "declined cards leave the setup intent retryable and record a failed attempt" do
      setup_intent =
        request(:post, "/v1/setup_intents", %{
          "payment_method" => "pm_card_chargeDeclinedInsufficientFunds"
        })
        |> json_response()

      conn = request(:post, "/v1/setup_intents/#{setup_intent["id"]}/confirm")

      assert conn.status == 402
      error = json_response(conn)["error"]
      assert error["type"] == "card_error"
      assert error["decline_code"] == "insufficient_funds"

      retrieved =
        request(:get, "/v1/setup_intents/#{setup_intent["id"]}")
        |> json_response()

      assert retrieved["status"] == "requires_payment_method"
      assert retrieved["last_setup_error"]["type"] == "card_error"
      assert String.starts_with?(retrieved["latest_attempt"], "setatt_")

      attempts = list_attempts(setup_intent["id"])
      assert [%{"setup_error" => %{"type" => "card_error"}, "status" => "failed"}] = attempts["data"]
    end

    test "bank-account setup requires microdeposit verification before succeeding" do
      customer_id = create_customer_id()
      payment_method = create_bank_payment_method()

      setup_intent =
        request(:post, "/v1/setup_intents", %{
          "customer" => customer_id,
          "payment_method" => payment_method["id"],
          "payment_method_types" => ["us_bank_account"]
        })
        |> json_response()

      conn = request(:post, "/v1/setup_intents/#{setup_intent["id"]}/confirm")

      assert conn.status == 200
      confirmed = json_response(conn)
      assert confirmed["status"] == "requires_action"
      assert confirmed["next_action"]["type"] == "verify_with_microdeposits"

      attempts = list_attempts(setup_intent["id"])
      assert [%{"status" => "requires_action"}] = attempts["data"]
    end
  end

  describe "POST /v1/setup_intents/:id/verify_microdeposits" do
    test "verifies bank-account microdeposits and attaches the payment method" do
      customer_id = create_customer_id()
      payment_method = create_bank_payment_method()
      setup_intent = create_confirmed_bank_setup_intent(customer_id, payment_method["id"])

      conn =
        request(:post, "/v1/setup_intents/#{setup_intent["id"]}/verify_microdeposits", %{
          "amounts" => [32, 45]
        })

      assert conn.status == 200
      verified = json_response(conn)
      assert verified["status"] == "succeeded"
      assert String.starts_with?(verified["mandate"], "mandate_")
      assert is_nil(verified["next_action"])

      payment_method =
        request(:get, "/v1/payment_methods/#{payment_method["id"]}")
        |> json_response()

      assert payment_method["customer"] == customer_id

      attempts = list_attempts(setup_intent["id"])
      assert [%{"status" => "succeeded"}] = attempts["data"]
    end

    test "also accepts the Stripe test descriptor code" do
      customer_id = create_customer_id()
      payment_method = create_bank_payment_method()
      setup_intent = create_confirmed_bank_setup_intent(customer_id, payment_method["id"])

      conn =
        request(:post, "/v1/setup_intents/#{setup_intent["id"]}/verify_microdeposits", %{
          "descriptor_code" => "SM11AA"
        })

      assert conn.status == 200
      assert json_response(conn)["status"] == "succeeded"
    end

    test "returns a Stripe-shaped error for incorrect verification values" do
      payment_method = create_bank_payment_method()
      setup_intent = create_confirmed_bank_setup_intent(nil, payment_method["id"])

      conn =
        request(:post, "/v1/setup_intents/#{setup_intent["id"]}/verify_microdeposits", %{
          "amounts" => [1, 2]
        })

      assert conn.status == 400
      error = json_response(conn)["error"]
      assert error["type"] == "invalid_request_error"
      assert error["param"] == "amounts"
    end
  end

  describe "POST /v1/setup_intents/:id/cancel" do
    test "cancels a pre-confirmation setup intent with a cancellation reason" do
      setup_intent =
        request(:post, "/v1/setup_intents")
        |> json_response()

      conn =
        request(:post, "/v1/setup_intents/#{setup_intent["id"]}/cancel", %{
          "cancellation_reason" => "requested_by_customer"
        })

      assert conn.status == 200
      canceled = json_response(conn)
      assert canceled["status"] == "canceled"
      assert canceled["cancellation_reason"] == "requested_by_customer"
    end

    test "abandons the latest attempt when canceling a setup intent that requires action" do
      payment_method = create_bank_payment_method()
      setup_intent = create_confirmed_bank_setup_intent(nil, payment_method["id"])

      conn =
        request(:post, "/v1/setup_intents/#{setup_intent["id"]}/cancel", %{
          "cancellation_reason" => "duplicate"
        })

      assert conn.status == 200
      assert json_response(conn)["status"] == "canceled"

      attempts = list_attempts(setup_intent["id"])
      assert [%{"status" => "abandoned"}] = attempts["data"]
    end

    test "returns a Stripe-shaped error when canceling a succeeded setup intent" do
      setup_intent =
        request(:post, "/v1/setup_intents", %{"payment_method" => "pm_card_visa"})
        |> json_response()

      request(:post, "/v1/setup_intents/#{setup_intent["id"]}/confirm")

      conn = request(:post, "/v1/setup_intents/#{setup_intent["id"]}/cancel")

      assert conn.status == 400
      error = json_response(conn)["error"]
      assert error["type"] == "invalid_request_error"
      assert error["param"] == "status"
      assert error["message"] =~ "does not allow cancellation"
    end
  end

  defp create_customer_id do
    request(:post, "/v1/customers", %{"email" => "setup-intent@example.com"})
    |> json_response()
    |> Map.fetch!("id")
  end

  defp create_bank_payment_method do
    request(:post, "/v1/payment_methods", %{
      "billing_details" => %{"name" => "Bank Customer"},
      "type" => "us_bank_account"
    })
    |> json_response()
  end

  defp create_confirmed_bank_setup_intent(customer_id, payment_method_id) do
    params = %{
      "payment_method" => payment_method_id,
      "payment_method_types" => ["us_bank_account"]
    }

    params = if customer_id, do: Map.put(params, "customer", customer_id), else: params

    setup_intent =
      request(:post, "/v1/setup_intents", params)
      |> json_response()

    request(:post, "/v1/setup_intents/#{setup_intent["id"]}/confirm")
    |> json_response()
  end

  defp list_attempts(setup_intent_id) do
    request(:get, "/v1/setup_attempts?setup_intent=#{setup_intent_id}")
    |> json_response()
  end
end
