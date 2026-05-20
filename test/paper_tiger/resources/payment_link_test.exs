defmodule PaperTiger.Resources.PaymentLinkTest do
  use ExUnit.Case, async: true

  import PaperTiger.Test

  alias PaperTiger.Router
  alias PaperTiger.Store.CheckoutSessions

  setup :checkout_paper_tiger

  defp conn(method, path, params, headers) do
    conn = Plug.Test.conn(method, path, params)

    headers_with_defaults =
      headers ++
        [
          {"content-type", "application/json"},
          {"authorization", "Bearer sk_test_payment_link_key"}
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

  describe "POST /v1/payment_links" do
    test "creates a payment link with hosted URL and normalized line items" do
      conn =
        request(:post, "/v1/payment_links", %{
          "line_items" => [
            price_data_line_item("Hosted product", 1500, 2)
          ],
          "metadata" => %{"source" => "test"}
        })

      assert conn.status == 200
      payment_link = json_response(conn)
      assert String.starts_with?(payment_link["id"], "plink_")
      assert payment_link["object"] == "payment_link"
      assert payment_link["active"] == true
      assert payment_link["amount_subtotal"] == 3000
      assert payment_link["amount_total"] == 3000
      assert payment_link["currency"] == "usd"
      assert payment_link["metadata"] == %{"source" => "test"}
      assert payment_link["url"] =~ "/payment_links/#{payment_link["id"]}"

      assert [
               %{
                 "amount_total" => 3000,
                 "description" => "Hosted product",
                 "payment_link" => payment_link_id,
                 "quantity" => 2
               }
             ] = payment_link["line_items"]

      assert payment_link_id == payment_link["id"]
    end

    test "requires at least one line item" do
      conn = request(:post, "/v1/payment_links", %{"line_items" => []})

      assert conn.status == 400
      assert json_response(conn)["error"]["param"] == "line_items"
    end
  end

  describe "GET /v1/payment_links/:id/line_items" do
    test "returns payment link line items with cursor pagination" do
      payment_link =
        create_payment_link(%{
          "line_items" => [
            price_data_line_item("One", 100, 1),
            price_data_line_item("Two", 200, 1),
            price_data_line_item("Three", 300, 1)
          ]
        })

      page1_conn = request(:get, "/v1/payment_links/#{payment_link["id"]}/line_items?limit=2")

      assert page1_conn.status == 200
      page1 = json_response(page1_conn)
      assert page1["object"] == "list"
      assert page1["url"] == "/v1/payment_links/#{payment_link["id"]}/line_items"
      assert page1["has_more"] == true
      assert Enum.map(page1["data"], & &1["description"]) == ["One", "Two"]

      last_id = List.last(page1["data"])["id"]
      page2_conn = request(:get, "/v1/payment_links/#{payment_link["id"]}/line_items?starting_after=#{last_id}")

      assert page2_conn.status == 200
      page2 = json_response(page2_conn)
      assert page2["has_more"] == false
      assert Enum.map(page2["data"], & &1["description"]) == ["Three"]
    end

    test "supports expand[]=line_items on retrieve" do
      payment_link =
        create_payment_link(%{
          "line_items" => [price_data_line_item("Expanded", 700, 1)]
        })

      conn = request(:get, "/v1/payment_links/#{payment_link["id"]}?expand[]=line_items")

      assert conn.status == 200
      retrieved = json_response(conn)
      assert retrieved["line_items"]["object"] == "list"
      assert [%{"description" => "Expanded"}] = retrieved["line_items"]["data"]
    end
  end

  describe "POST /v1/payment_links/:id" do
    test "updates metadata, active state, and line items" do
      payment_link =
        create_payment_link(%{
          "line_items" => [price_data_line_item("Original", 1000, 1)],
          "metadata" => %{"keep" => "yes", "remove" => "old"}
        })

      conn =
        request(:post, "/v1/payment_links/#{payment_link["id"]}", %{
          "active" => false,
          "line_items" => [price_data_line_item("Replacement", 400, 3)],
          "metadata" => %{"add" => "new", "remove" => ""}
        })

      assert conn.status == 200
      updated = json_response(conn)
      assert updated["active"] == false
      assert updated["amount_total"] == 1200
      assert updated["metadata"] == %{"add" => "new", "keep" => "yes"}
      assert [%{"description" => "Replacement", "quantity" => 3}] = updated["line_items"]
    end
  end

  describe "browser Payment Link flow" do
    test "creates a checkout session and uses the existing checkout completion path" do
      payment_link =
        create_payment_link(%{
          "after_completion" => %{
            "redirect" => %{"url" => "https://example.test/success"},
            "type" => "redirect"
          },
          "line_items" => [price_data_line_item("Browser", 2500, 1)]
        })

      payment_link_path = URI.parse(payment_link["url"]).path
      payment_link_conn = public_request(:get, payment_link_path)

      assert payment_link_conn.status == 302
      [checkout_url] = Plug.Conn.get_resp_header(payment_link_conn, "location")
      assert checkout_url =~ "/checkout/"

      [_, session_id] = Regex.run(~r{/checkout/([^/]+)/complete}, checkout_url)
      checkout_conn = public_request(:get, URI.parse(checkout_url).path)

      assert checkout_conn.status == 302
      assert Plug.Conn.get_resp_header(checkout_conn, "location") == ["https://example.test/success"]

      assert {:ok, session} = CheckoutSessions.get(session_id)
      assert session.status == "complete"
      assert session.payment_status == "paid"
      assert session.payment_link == payment_link["id"]
    end

    test "rejects inactive payment links" do
      payment_link =
        create_payment_link(%{
          "active" => false,
          "line_items" => [price_data_line_item("Inactive", 100, 1)]
        })

      conn = public_request(:get, URI.parse(payment_link["url"]).path)

      assert conn.status == 400
      assert json_response(conn)["error"]["param"] == "active"
    end
  end

  defp create_payment_link(params) do
    conn = request(:post, "/v1/payment_links", params)
    assert conn.status == 200
    json_response(conn)
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
