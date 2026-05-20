defmodule PaperTiger.Resources.BillingPortalTest do
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
          {"authorization", "Bearer sk_test_billing_portal_key"}
        ] ++ sandbox_headers()

    Enum.reduce(headers_with_defaults, conn, fn {key, value}, acc ->
      Plug.Conn.put_req_header(acc, key, value)
    end)
  end

  defp public_conn(method, path) do
    conn = Plug.Test.conn(method, path, nil)

    Enum.reduce(sandbox_headers(), conn, fn {key, value}, acc ->
      Plug.Conn.put_req_header(acc, key, value)
    end)
  end

  defp request(method, path, params \\ nil, headers \\ []) do
    method
    |> conn(path, params, headers)
    |> Router.call([])
  end

  defp public_request(method, path) do
    method
    |> public_conn(path)
    |> Router.call([])
  end

  defp json_response(conn), do: Jason.decode!(conn.resp_body)

  describe "billing portal configurations" do
    test "creates, retrieves, updates, and lists configurations" do
      create_conn =
        request(:post, "/v1/billing_portal/configurations", %{
          "business_profile" => %{"headline" => "Manage billing"},
          "default_return_url" => "https://example.test/account",
          "features" => %{
            "customer_update" => %{"allowed_updates" => ["email"], "enabled" => true},
            "invoice_history" => %{"enabled" => true}
          },
          "metadata" => %{"tier" => "test"}
        })

      assert create_conn.status == 200
      configuration = json_response(create_conn)
      assert String.starts_with?(configuration["id"], "bpc_")
      assert configuration["object"] == "billing_portal.configuration"
      assert configuration["active"] == true
      assert configuration["default_return_url"] == "https://example.test/account"

      retrieve_conn = request(:get, "/v1/billing_portal/configurations/#{configuration["id"]}")
      assert retrieve_conn.status == 200
      assert json_response(retrieve_conn)["id"] == configuration["id"]

      update_conn =
        request(:post, "/v1/billing_portal/configurations/#{configuration["id"]}", %{
          "active" => false,
          "metadata" => %{"tier" => ""}
        })

      assert update_conn.status == 200
      updated = json_response(update_conn)
      assert updated["active"] == false
      assert updated["metadata"] == %{}

      list_conn = request(:get, "/v1/billing_portal/configurations")
      assert list_conn.status == 200
      assert [configuration["id"]] == Enum.map(json_response(list_conn)["data"], & &1["id"])
    end
  end

  describe "POST /v1/billing_portal/sessions" do
    test "creates a session for a customer and redirects browser visits to return_url" do
      customer = create_customer()
      configuration = create_configuration("https://example.test/billing")

      create_conn =
        request(:post, "/v1/billing_portal/sessions", %{
          "configuration" => configuration["id"],
          "customer" => customer["id"],
          "return_url" => "https://example.test/account"
        })

      assert create_conn.status == 200
      session = json_response(create_conn)
      assert String.starts_with?(session["id"], "bps_")
      assert session["object"] == "billing_portal.session"
      assert session["configuration"] == configuration["id"]
      assert session["customer"] == customer["id"]
      assert session["url"] =~ "/billing_portal/sessions/#{session["id"]}"

      browser_conn = public_request(:get, URI.parse(session["url"]).path)

      assert browser_conn.status == 302
      assert Plug.Conn.get_resp_header(browser_conn, "location") == ["https://example.test/account"]
    end

    test "creates a default configuration when no configuration is supplied" do
      customer = create_customer()

      create_conn =
        request(:post, "/v1/billing_portal/sessions", %{
          "customer" => customer["id"],
          "return_url" => "https://example.test/default"
        })

      assert create_conn.status == 200
      session = json_response(create_conn)
      assert String.starts_with?(session["configuration"], "bpc_")
      assert session["return_url"] == "https://example.test/default"
    end

    test "rejects unknown customers and configurations" do
      unknown_customer_conn =
        request(:post, "/v1/billing_portal/sessions", %{"customer" => "cus_missing"})

      assert unknown_customer_conn.status == 404
      assert json_response(unknown_customer_conn)["error"]["code"] == "resource_missing"

      customer = create_customer()

      unknown_configuration_conn =
        request(:post, "/v1/billing_portal/sessions", %{
          "configuration" => "bpc_missing",
          "customer" => customer["id"]
        })

      assert unknown_configuration_conn.status == 404
      assert json_response(unknown_configuration_conn)["error"]["code"] == "resource_missing"
    end
  end

  defp create_customer do
    conn = request(:post, "/v1/customers", %{"email" => "portal@example.test"})
    assert conn.status == 200
    json_response(conn)
  end

  defp create_configuration(return_url) do
    conn =
      request(:post, "/v1/billing_portal/configurations", %{
        "default_return_url" => return_url,
        "features" => %{"invoice_history" => %{"enabled" => true}}
      })

    assert conn.status == 200
    json_response(conn)
  end
end
