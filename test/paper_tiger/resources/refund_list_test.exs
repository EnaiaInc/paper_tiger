defmodule PaperTiger.Resources.RefundListTest do
  use ExUnit.Case, async: true

  import PaperTiger.Test

  alias PaperTiger.Router

  setup :checkout_paper_tiger

  defp request(method, path, params) do
    path = maybe_put_query_string(method, path, params)
    body = if method in [:get, :delete], do: "", else: params

    Plug.Test.conn(method, path, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer sk_test_refund_list_key")
    |> put_sandbox_headers()
    |> Router.call([])
  end

  defp maybe_put_query_string(method, path, params) when method in [:get, :delete] and map_size(params) > 0 do
    "#{path}?#{URI.encode_query(params)}"
  end

  defp maybe_put_query_string(_method, path, _params), do: path

  defp put_sandbox_headers(conn) do
    Enum.reduce(sandbox_headers(), conn, fn {key, value}, acc ->
      Plug.Conn.put_req_header(acc, key, value)
    end)
  end

  defp json_response(conn), do: Jason.decode!(conn.resp_body)

  describe "GET /v1/refunds" do
    test "defaults to remaining charge amount and updates charge refund state" do
      charge = create_charge(2_000)

      partial = create_refund(charge["id"], 600)

      assert partial["amount"] == 600

      partially_refunded_charge =
        request(:get, "/v1/charges/#{charge["id"]}", %{})
        |> json_response()

      assert partially_refunded_charge["amount_refunded"] == 600
      assert partially_refunded_charge["refunded"] == false

      full_conn = request(:post, "/v1/refunds", %{"charge" => charge["id"]})

      assert full_conn.status == 200
      final_refund = json_response(full_conn)
      assert final_refund["amount"] == 1_400

      fully_refunded_charge =
        request(:get, "/v1/charges/#{charge["id"]}", %{})
        |> json_response()

      assert fully_refunded_charge["amount_refunded"] == 2_000
      assert fully_refunded_charge["refunded"] == true

      over_refund_conn = request(:post, "/v1/refunds", %{"amount" => 1, "charge" => charge["id"]})

      assert over_refund_conn.status == 400
      assert json_response(over_refund_conn)["error"]["param"] == "amount"
    end

    test "filters refunds by charge and created range before pagination" do
      charge1 = create_charge(2_000)
      charge2 = create_charge(3_000)

      refund1 = create_refund(charge1["id"], 500)
      refund2 = create_refund(charge2["id"], 700)

      conn =
        request(:get, "/v1/refunds", %{
          "charge" => charge1["id"],
          "created[gte]" => refund1["created"],
          "created[lte]" => refund1["created"],
          "limit" => 10
        })

      assert conn.status == 200
      assert json_response(conn)["data"] |> Enum.map(& &1["id"]) == [refund1["id"]]

      conn = request(:get, "/v1/refunds", %{"charge" => charge2["id"], "limit" => 10})

      assert conn.status == 200
      assert json_response(conn)["data"] |> Enum.map(& &1["id"]) == [refund2["id"]]
    end

    test "filters refunds by payment intent" do
      pi =
        request(:post, "/v1/payment_intents", %{
          "amount" => 2_500,
          "currency" => "usd",
          "payment_method" => "pm_card_visa"
        })
        |> json_response()

      confirmed =
        request(:post, "/v1/payment_intents/#{pi["id"]}/confirm", %{})
        |> json_response()

      refund = create_refund(confirmed["latest_charge"], 400)

      conn = request(:get, "/v1/refunds", %{"limit" => 10, "payment_intent" => pi["id"]})

      assert conn.status == 200
      assert json_response(conn)["data"] |> Enum.map(& &1["id"]) == [refund["id"]]
    end

    test "returns Stripe-shaped errors for non-existent list filter references" do
      conn = request(:get, "/v1/refunds", %{"charge" => "ch_missing"})

      assert conn.status == 404
      assert json_response(conn)["error"]["param"] == "charge"

      conn = request(:get, "/v1/refunds", %{"payment_intent" => "pi_missing"})

      assert conn.status == 404
      assert json_response(conn)["error"]["param"] == "intent"
    end
  end

  defp create_charge(amount) do
    conn =
      request(:post, "/v1/charges", %{
        "amount" => amount,
        "currency" => "usd",
        "source" => "tok_visa"
      })

    assert conn.status == 200
    json_response(conn)
  end

  defp create_refund(charge_id, amount) do
    conn =
      request(:post, "/v1/refunds", %{
        "amount" => amount,
        "charge" => charge_id
      })

    assert conn.status == 200
    json_response(conn)
  end
end
