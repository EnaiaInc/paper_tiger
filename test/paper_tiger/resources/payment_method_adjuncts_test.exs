defmodule PaperTiger.Resources.PaymentMethodAdjunctsTest do
  use ExUnit.Case, async: true

  import PaperTiger.Test

  alias PaperTiger.Router

  setup :checkout_paper_tiger

  defp request(method, path, params \\ %{}) do
    conn = Plug.Test.conn(method, path, params)

    [{"content-type", "application/json"}, {"authorization", "Bearer sk_test_payment_adjunct_key"}]
    |> Kernel.++(sandbox_headers())
    |> Enum.reduce(conn, fn {key, value}, acc -> Plug.Conn.put_req_header(acc, key, value) end)
    |> Router.call([])
  end

  defp json_response(conn), do: Jason.decode!(conn.resp_body)

  describe "POST /v1/customer_sessions" do
    test "creates a customer session with a client secret" do
      customer_id = create_customer_id()

      conn =
        request(:post, "/v1/customer_sessions", %{
          "components" => %{
            "payment_element" => %{
              "enabled" => true,
              "features" => %{"payment_method_redisplay" => "enabled"}
            }
          },
          "customer" => customer_id
        })

      assert conn.status == 200
      customer_session = json_response(conn)
      assert customer_session["object"] == "customer_session"
      assert customer_session["customer"] == customer_id
      assert String.starts_with?(customer_session["client_secret"], "_")
      assert is_integer(customer_session["created"])
      assert is_integer(customer_session["expires_at"])
      assert customer_session["components"]["payment_element"]["enabled"] == true
    end

    test "requires an enabled component" do
      customer_id = create_customer_id()

      conn =
        request(:post, "/v1/customer_sessions", %{
          "components" => %{"payment_element" => %{"enabled" => false}},
          "customer" => customer_id
        })

      assert conn.status == 400
      assert json_response(conn)["error"]["param"] == "components"
    end
  end

  describe "PaymentMethodDomain endpoints" do
    test "create retrieve update and list payment method domains" do
      create_conn =
        request(:post, "/v1/payment_method_domains", %{
          "domain_name" => "checkout.example.com"
        })

      assert create_conn.status == 200
      domain = json_response(create_conn)
      assert domain["object"] == "payment_method_domain"
      assert String.starts_with?(domain["id"], "pmd_")
      assert domain["domain_name"] == "checkout.example.com"
      assert domain["enabled"] == true
      assert domain["apple_pay"]["status"] == "active"
      assert domain["google_pay"]["status"] == "active"
      assert domain["link"]["status"] == "active"

      retrieved =
        request(:get, "/v1/payment_method_domains/#{domain["id"]}")
        |> json_response()

      assert retrieved["id"] == domain["id"]

      update_conn =
        request(:post, "/v1/payment_method_domains/#{domain["id"]}", %{
          "enabled" => false
        })

      assert update_conn.status == 200
      updated = json_response(update_conn)
      assert updated["enabled"] == false
      assert updated["apple_pay"]["status"] == "inactive"
      assert updated["link"]["status"] == "inactive"

      list =
        request(:get, "/v1/payment_method_domains")
        |> json_response()

      assert Enum.any?(list["data"], &(&1["id"] == domain["id"]))
    end
  end

  describe "PaymentMethodConfiguration endpoints" do
    test "create retrieve update and list payment method configurations" do
      create_conn =
        request(:post, "/v1/payment_method_configurations", %{
          "card" => %{"display_preference" => %{"preference" => "off"}},
          "link" => %{"display_preference" => %{"preference" => "on"}},
          "name" => "Elements checkout"
        })

      assert create_conn.status == 200
      configuration = json_response(create_conn)
      assert configuration["object"] == "payment_method_configuration"
      assert String.starts_with?(configuration["id"], "pmc_")
      assert configuration["name"] == "Elements checkout"
      assert configuration["active"] == true
      assert configuration["card"]["available"] == false
      assert configuration["card"]["display_preference"]["preference"] == "off"
      assert configuration["link"]["available"] == true
      assert configuration["apple_pay"]["available"] == true

      retrieved =
        request(:get, "/v1/payment_method_configurations/#{configuration["id"]}")
        |> json_response()

      assert retrieved["id"] == configuration["id"]

      update_conn =
        request(:post, "/v1/payment_method_configurations/#{configuration["id"]}", %{
          "active" => false,
          "card" => %{"display_preference" => %{"preference" => "on"}},
          "name" => "Updated checkout"
        })

      assert update_conn.status == 200
      updated = json_response(update_conn)
      assert updated["active"] == false
      assert updated["name"] == "Updated checkout"
      assert updated["card"]["available"] == true
      assert updated["card"]["display_preference"]["preference"] == "on"

      list =
        request(:get, "/v1/payment_method_configurations")
        |> json_response()

      assert Enum.any?(list["data"], &(&1["id"] == configuration["id"]))
    end
  end

  describe "ConfirmationToken endpoints" do
    test "creates and retrieves a test confirmation token" do
      token =
        request(:post, "/v1/test_helpers/confirmation_tokens", %{
          "payment_method_data" => %{
            "billing_details" => %{"email" => "buyer@example.com"},
            "card" => %{"last4" => "4242"},
            "type" => "card"
          },
          "setup_future_usage" => "off_session"
        })
        |> json_response()

      assert token["object"] == "confirmation_token"
      assert String.starts_with?(token["id"], "ctoken_")
      assert token["setup_future_usage"] == "off_session"
      assert token["payment_method_preview"]["type"] == "card"
      assert token["payment_method_preview"]["billing_details"]["email"] == "buyer@example.com"

      retrieved =
        request(:get, "/v1/confirmation_tokens/#{token["id"]}")
        |> json_response()

      assert retrieved["id"] == token["id"]
    end

    test "confirms a payment intent with a confirmation token and marks the token used" do
      token =
        request(:post, "/v1/test_helpers/confirmation_tokens", %{
          "payment_method_data" => %{"type" => "card"}
        })
        |> json_response()

      payment_intent =
        request(:post, "/v1/payment_intents", %{
          "amount" => 2500,
          "currency" => "usd"
        })
        |> json_response()

      confirmed =
        request(:post, "/v1/payment_intents/#{payment_intent["id"]}/confirm", %{
          "confirmation_token" => token["id"]
        })
        |> json_response()

      assert confirmed["status"] == "succeeded"
      assert String.starts_with?(confirmed["payment_method"], "pm_")

      used_token =
        request(:get, "/v1/confirmation_tokens/#{token["id"]}")
        |> json_response()

      assert used_token["payment_intent"] == confirmed["id"]
      assert used_token["payment_method"] == confirmed["payment_method"]

      second_payment_intent =
        request(:post, "/v1/payment_intents", %{
          "amount" => 2600,
          "currency" => "usd"
        })
        |> json_response()

      reuse_conn =
        request(:post, "/v1/payment_intents/#{second_payment_intent["id"]}/confirm", %{
          "confirmation_token" => token["id"]
        })

      assert reuse_conn.status == 400
      assert json_response(reuse_conn)["error"]["param"] == "confirmation_token"
    end
  end

  describe "Mandate endpoints" do
    test "stores and retrieves a mandate after bank-account setup succeeds" do
      customer_id = create_customer_id()
      payment_method = create_bank_payment_method()

      setup_intent =
        request(:post, "/v1/setup_intents", %{
          "customer" => customer_id,
          "payment_method" => payment_method["id"],
          "payment_method_types" => ["us_bank_account"]
        })
        |> json_response()

      request(:post, "/v1/setup_intents/#{setup_intent["id"]}/confirm")

      verified =
        request(:post, "/v1/setup_intents/#{setup_intent["id"]}/verify_microdeposits", %{
          "amounts" => [32, 45]
        })
        |> json_response()

      assert String.starts_with?(verified["mandate"], "mandate_")

      mandate =
        request(:get, "/v1/mandates/#{verified["mandate"]}")
        |> json_response()

      assert mandate["object"] == "mandate"
      assert mandate["payment_method"] == payment_method["id"]
      assert mandate["status"] == "active"
      assert mandate["type"] == "multi_use"
      assert mandate["payment_method_details"]["type"] == "us_bank_account"
    end

    test "stores and retrieves a mandate when a bank-account payment intent succeeds" do
      payment_method = create_bank_payment_method()

      payment_intent =
        request(:post, "/v1/payment_intents", %{
          "amount" => 4800,
          "currency" => "usd",
          "payment_method" => payment_method["id"],
          "setup_future_usage" => "off_session"
        })
        |> json_response()

      confirmed =
        request(:post, "/v1/payment_intents/#{payment_intent["id"]}/confirm")
        |> json_response()

      assert confirmed["status"] == "succeeded"
      assert String.starts_with?(confirmed["mandate"], "mandate_")

      mandate =
        request(:get, "/v1/mandates/#{confirmed["mandate"]}")
        |> json_response()

      assert mandate["payment_method"] == payment_method["id"]
      assert mandate["type"] == "multi_use"
    end
  end

  defp create_customer_id do
    request(:post, "/v1/customers", %{"email" => "payment-adjuncts@example.com"})
    |> json_response()
    |> Map.fetch!("id")
  end

  defp create_bank_payment_method do
    request(:post, "/v1/payment_methods", %{
      "billing_details" => %{"name" => "Bank Customer"},
      "type" => "us_bank_account",
      "us_bank_account" => %{
        "account_holder_type" => "individual",
        "account_type" => "checking",
        "last4" => "6789",
        "routing_number" => "110000000"
      }
    })
    |> json_response()
  end
end
