defmodule PaperTiger.Resources.PaymentIntentLifecycleTest do
  use ExUnit.Case, async: true

  import PaperTiger.Test

  alias PaperTiger.Router

  setup :checkout_paper_tiger

  defp request(method, path, params \\ %{}) do
    conn = Plug.Test.conn(method, path, params)

    [{"content-type", "application/json"}, {"authorization", "Bearer sk_test_pi_lifecycle_key"}]
    |> Kernel.++(sandbox_headers())
    |> Enum.reduce(conn, fn {key, value}, acc -> Plug.Conn.put_req_header(acc, key, value) end)
    |> Router.call([])
  end

  defp json_response(conn), do: Jason.decode!(conn.resp_body)

  describe "POST /v1/payment_intents/:id/cancel" do
    test "cancels a pre-confirmation payment intent with a cancellation reason" do
      create_conn =
        request(:post, "/v1/payment_intents", %{
          "amount" => 2400,
          "currency" => "usd"
        })

      pi = json_response(create_conn)

      cancel_conn =
        request(:post, "/v1/payment_intents/#{pi["id"]}/cancel", %{
          "cancellation_reason" => "requested_by_customer"
        })

      assert cancel_conn.status == 200
      canceled = json_response(cancel_conn)
      assert canceled["status"] == "canceled"
      assert canceled["cancellation_reason"] == "requested_by_customer"
      assert canceled["amount_capturable"] == 0
      assert is_integer(canceled["canceled_at"])
    end

    test "returns a Stripe-shaped error when canceling a succeeded payment intent" do
      pi =
        request(:post, "/v1/payment_intents", %{"amount" => 2400, "currency" => "usd"})
        |> json_response()

      assert request(:post, "/v1/payment_intents/#{pi["id"]}/confirm").status == 200

      cancel_conn = request(:post, "/v1/payment_intents/#{pi["id"]}/cancel")

      assert cancel_conn.status == 400
      error = json_response(cancel_conn)["error"]
      assert error["type"] == "invalid_request_error"
      assert error["param"] == "status"
      assert error["message"] =~ "does not allow cancellation"
    end
  end

  describe "POST /v1/payment_intents/:id/capture" do
    test "manual confirmation authorizes and full capture succeeds the payment intent" do
      confirmed = create_and_confirm_manual_payment_intent(5000)

      assert confirmed["status"] == "requires_capture"
      assert confirmed["amount_capturable"] == 5000
      assert confirmed["amount_received"] == 0
      assert confirmed["latest_charge"] != nil

      uncaptured_charge =
        request(:get, "/v1/charges/#{confirmed["latest_charge"]}")
        |> json_response()

      assert uncaptured_charge["captured"] == false
      assert uncaptured_charge["amount_captured"] == 0
      assert uncaptured_charge["balance_transaction"] == nil

      capture_conn = request(:post, "/v1/payment_intents/#{confirmed["id"]}/capture")

      assert capture_conn.status == 200
      captured = json_response(capture_conn)
      assert captured["status"] == "succeeded"
      assert captured["amount_capturable"] == 0
      assert captured["amount_received"] == 5000

      captured_charge =
        request(:get, "/v1/charges/#{captured["latest_charge"]}")
        |> json_response()

      assert captured_charge["captured"] == true
      assert captured_charge["amount_captured"] == 5000
      assert captured_charge["balance_transaction"] != nil
    end

    test "supports non-final partial capture followed by final capture" do
      confirmed = create_and_confirm_manual_payment_intent(5000)

      partial_conn =
        request(:post, "/v1/payment_intents/#{confirmed["id"]}/capture", %{
          "amount_to_capture" => 1800,
          "final_capture" => false
        })

      assert partial_conn.status == 200
      partial = json_response(partial_conn)
      assert partial["status"] == "requires_capture"
      assert partial["amount_capturable"] == 3200
      assert partial["amount_received"] == 1800

      partially_captured_charge =
        request(:get, "/v1/charges/#{partial["latest_charge"]}")
        |> json_response()

      assert partially_captured_charge["captured"] == false
      assert partially_captured_charge["amount_captured"] == 1800

      final_conn = request(:post, "/v1/payment_intents/#{confirmed["id"]}/capture")

      assert final_conn.status == 200
      final = json_response(final_conn)
      assert final["status"] == "succeeded"
      assert final["amount_capturable"] == 0
      assert final["amount_received"] == 5000

      captured_charge =
        request(:get, "/v1/charges/#{final["latest_charge"]}")
        |> json_response()

      assert captured_charge["captured"] == true
      assert captured_charge["amount_captured"] == 5000
    end

    test "supports final partial capture and releases the remaining amount" do
      confirmed = create_and_confirm_manual_payment_intent(5000)

      capture_conn =
        request(:post, "/v1/payment_intents/#{confirmed["id"]}/capture", %{
          "amount_to_capture" => 1800
        })

      assert capture_conn.status == 200
      captured = json_response(capture_conn)
      assert captured["status"] == "succeeded"
      assert captured["amount_capturable"] == 0
      assert captured["amount_received"] == 1800

      captured_charge =
        request(:get, "/v1/charges/#{captured["latest_charge"]}")
        |> json_response()

      assert captured_charge["captured"] == true
      assert captured_charge["amount_captured"] == 1800
    end

    test "returns a Stripe-shaped error when capture amount exceeds capturable amount" do
      confirmed = create_and_confirm_manual_payment_intent(5000)

      capture_conn =
        request(:post, "/v1/payment_intents/#{confirmed["id"]}/capture", %{
          "amount_to_capture" => 5001
        })

      assert capture_conn.status == 400
      error = json_response(capture_conn)["error"]
      assert error["type"] == "invalid_request_error"
      assert error["param"] == "amount_to_capture"
      assert error["message"] =~ "exceeds the capturable amount"
    end

    test "returns a Stripe-shaped error when capturing an automatic payment intent" do
      pi =
        request(:post, "/v1/payment_intents", %{"amount" => 5000, "currency" => "usd"})
        |> json_response()

      request(:post, "/v1/payment_intents/#{pi["id"]}/confirm")

      capture_conn = request(:post, "/v1/payment_intents/#{pi["id"]}/capture")

      assert capture_conn.status == 400
      error = json_response(capture_conn)["error"]
      assert error["type"] == "invalid_request_error"
      assert error["param"] == "status"
      assert error["message"] =~ "does not allow capture"
    end
  end

  defp create_and_confirm_manual_payment_intent(amount) do
    pi =
      request(:post, "/v1/payment_intents", %{
        "amount" => amount,
        "capture_method" => "manual",
        "currency" => "usd",
        "payment_method" => "pm_card_visa"
      })
      |> json_response()

    request(:post, "/v1/payment_intents/#{pi["id"]}/confirm")
    |> json_response()
  end
end
