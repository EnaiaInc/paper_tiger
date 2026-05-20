defmodule PaperTiger.Resources.ConnectPlatformTest do
  use ExUnit.Case, async: true

  import PaperTiger.Test

  alias PaperTiger.Router

  setup :checkout_paper_tiger

  defp request(method, path, params \\ nil, headers \\ []) do
    conn = Plug.Test.conn(method, path, params)

    headers_with_defaults =
      headers ++
        [
          {"content-type", "application/json"},
          {"authorization", "Bearer sk_test_connect_key"}
        ] ++ sandbox_headers()

    headers_with_defaults
    |> Enum.reduce(conn, fn {key, value}, acc -> Plug.Conn.put_req_header(acc, key, value) end)
    |> Router.call([])
  end

  defp json_response(conn), do: Jason.decode!(conn.resp_body)
  defp account_header(account_id), do: [{"stripe-account", account_id}]

  describe "Accounts and Account Links" do
    test "creates, updates, lists, retrieves, and deletes legacy connected accounts" do
      create_conn =
        request(:post, "/v1/accounts", %{
          "business_type" => "individual",
          "capabilities" => %{
            "card_payments" => %{"requested" => true},
            "transfers" => %{"requested" => true}
          },
          "country" => "US",
          "email" => "seller@example.test",
          "type" => "express"
        })

      assert create_conn.status == 200
      account = json_response(create_conn)
      assert String.starts_with?(account["id"], "acct_")
      assert account["object"] == "account"
      assert account["capabilities"]["transfers"] == "active"
      assert account["charges_enabled"] == true
      assert account["payouts_enabled"] == true

      update_conn =
        request(:post, "/v1/accounts/#{account["id"]}", %{
          "metadata" => %{"seller_id" => "seller_123"}
        })

      assert update_conn.status == 200
      assert json_response(update_conn)["metadata"] == %{"seller_id" => "seller_123"}

      retrieve_conn = request(:get, "/v1/accounts/#{account["id"]}")
      assert retrieve_conn.status == 200
      assert json_response(retrieve_conn)["email"] == "seller@example.test"

      list_conn = request(:get, "/v1/accounts")
      assert list_conn.status == 200
      assert [account["id"]] == Enum.map(json_response(list_conn)["data"], & &1["id"])

      link_conn =
        request(:post, "/v1/account_links", %{
          "account" => account["id"],
          "refresh_url" => "https://example.test/reauth",
          "return_url" => "https://example.test/return",
          "type" => "account_onboarding"
        })

      assert link_conn.status == 200
      link = json_response(link_conn)
      assert link["object"] == "account_link"
      assert link["account"] == account["id"]
      assert link["type"] == "account_onboarding"
      assert String.starts_with?(link["url"], "https://connect.stripe.com/setup/s/link_")

      delete_conn = request(:delete, "/v1/accounts/#{account["id"]}")
      assert delete_conn.status == 200
      assert json_response(delete_conn) == %{"deleted" => true, "id" => account["id"], "object" => "account"}
    end
  end

  describe "Stripe-Account request scoping" do
    test "isolates ordinary resources per connected account" do
      account = create_account()

      platform_customer =
        request(:post, "/v1/customers", %{
          "email" => "platform@example.test",
          "id" => "cus_connect_shared"
        })
        |> json_response()

      connected_customer =
        request(
          :post,
          "/v1/customers",
          %{"email" => "connected@example.test", "id" => "cus_connect_shared"},
          account_header(account["id"])
        )
        |> json_response()

      assert platform_customer["id"] == connected_customer["id"]

      platform_retrieve =
        request(:get, "/v1/customers/cus_connect_shared")
        |> json_response()

      connected_retrieve =
        request(:get, "/v1/customers/cus_connect_shared", nil, account_header(account["id"]))
        |> json_response()

      assert platform_retrieve["email"] == "platform@example.test"
      assert connected_retrieve["email"] == "connected@example.test"

      connected_list =
        request(:get, "/v1/customers", nil, account_header(account["id"]))
        |> json_response()

      assert ["connected@example.test"] == Enum.map(connected_list["data"], & &1["email"])

      missing_account_conn =
        request(:get, "/v1/customers", nil, account_header("acct_missing"))

      assert missing_account_conn.status == 404
      assert json_response(missing_account_conn)["error"]["code"] == "resource_missing"
    end
  end

  describe "Transfers and Transfer Reversals" do
    test "creates transfers to connected accounts and reverses them coherently" do
      account = create_account()

      transfer_conn =
        request(:post, "/v1/transfers", %{
          "amount" => 1_500,
          "currency" => "usd",
          "description" => "Seller payout",
          "destination" => account["id"],
          "transfer_group" => "order_123"
        })

      assert transfer_conn.status == 200
      transfer = json_response(transfer_conn)
      assert String.starts_with?(transfer["id"], "tr_")
      assert transfer["amount"] == 1_500
      assert transfer["amount_reversed"] == 0
      assert transfer["destination"] == account["id"]
      assert transfer["reversed"] == false
      assert transfer["reversals"]["data"] == []

      reversal_conn =
        request(:post, "/v1/transfers/#{transfer["id"]}/reversals", %{
          "amount" => 500,
          "metadata" => %{"reason" => "partial_refund"}
        })

      assert reversal_conn.status == 200
      reversal = json_response(reversal_conn)
      assert String.starts_with?(reversal["id"], "trr_")
      assert reversal["amount"] == 500
      assert reversal["transfer"] == transfer["id"]
      assert reversal["metadata"] == %{"reason" => "partial_refund"}

      updated_transfer =
        request(:get, "/v1/transfers/#{transfer["id"]}")
        |> json_response()

      assert updated_transfer["amount_reversed"] == 500
      assert updated_transfer["reversed"] == false
      assert [reversal["id"]] == Enum.map(updated_transfer["reversals"]["data"], & &1["id"])

      list_reversals_conn = request(:get, "/v1/transfers/#{transfer["id"]}/reversals")
      assert list_reversals_conn.status == 200
      assert [reversal["id"]] == Enum.map(json_response(list_reversals_conn)["data"], & &1["id"])

      final_reversal_conn = request(:post, "/v1/transfers/#{transfer["id"]}/reversals")
      assert final_reversal_conn.status == 200

      fully_reversed =
        request(:get, "/v1/transfers/#{transfer["id"]}")
        |> json_response()

      assert fully_reversed["amount_reversed"] == 1_500
      assert fully_reversed["reversed"] == true
    end
  end

  describe "Application Fee Refunds" do
    test "creates application fees from destination-charge payment intents and refunds them" do
      account = create_account()

      payment_intent =
        request(:post, "/v1/payment_intents", %{
          "amount" => 2_000,
          "application_fee_amount" => 250,
          "currency" => "usd",
          "payment_method" => "pm_card_visa",
          "transfer_data" => %{"destination" => account["id"]}
        })
        |> json_response()

      confirmed =
        request(:post, "/v1/payment_intents/#{payment_intent["id"]}/confirm")
        |> json_response()

      charge =
        request(:get, "/v1/charges/#{confirmed["latest_charge"]}")
        |> json_response()

      assert String.starts_with?(charge["application_fee"], "fee_")

      fee =
        request(:get, "/v1/application_fees/#{charge["application_fee"]}")
        |> json_response()

      assert fee["account"] == account["id"]
      assert fee["amount"] == 250
      assert fee["amount_refunded"] == 0
      assert fee["refunded"] == false

      refund_conn =
        request(:post, "/v1/application_fees/#{fee["id"]}/refunds", %{
          "amount" => 100,
          "metadata" => %{"reason" => "seller_refund"}
        })

      assert refund_conn.status == 200
      refund = json_response(refund_conn)
      assert String.starts_with?(refund["id"], "fr_")
      assert refund["amount"] == 100
      assert refund["fee"] == fee["id"]
      assert refund["metadata"] == %{"reason" => "seller_refund"}

      partially_refunded_fee =
        request(:get, "/v1/application_fees/#{fee["id"]}")
        |> json_response()

      assert partially_refunded_fee["amount_refunded"] == 100
      assert partially_refunded_fee["refunded"] == false

      final_refund =
        request(:post, "/v1/application_fees/#{fee["id"]}/refunds")
        |> json_response()

      assert final_refund["amount"] == 150

      fully_refunded_fee =
        request(:get, "/v1/application_fees/#{fee["id"]}")
        |> json_response()

      assert fully_refunded_fee["amount_refunded"] == 250
      assert fully_refunded_fee["refunded"] == true

      over_refund_conn =
        request(:post, "/v1/application_fees/#{fee["id"]}/refunds", %{"amount" => 1})

      assert over_refund_conn.status == 400
      assert json_response(over_refund_conn)["error"]["param"] == "amount"
    end
  end

  defp create_account do
    conn =
      request(:post, "/v1/accounts", %{
        "capabilities" => %{"transfers" => %{"requested" => true}},
        "country" => "US",
        "type" => "express"
      })

    assert conn.status == 200
    json_response(conn)
  end
end
