defmodule PaperTiger.Resources.SearchTest do
  use ExUnit.Case, async: true

  import PaperTiger.Test

  alias PaperTiger.Router

  setup :checkout_paper_tiger

  defp request(method, path, params) do
    path = maybe_put_query_string(method, path, params)
    body = if method in [:get, :delete], do: "", else: params
    conn = Plug.Test.conn(method, path, body)

    [{"content-type", "application/json"}, {"authorization", "Bearer sk_test_search_key"}]
    |> Kernel.++(sandbox_headers())
    |> Enum.reduce(conn, fn {key, value}, acc -> Plug.Conn.put_req_header(acc, key, value) end)
    |> Router.call([])
  end

  defp maybe_put_query_string(method, path, params) when method in [:get, :delete] and map_size(params) > 0 do
    "#{path}?#{URI.encode_query(params)}"
  end

  defp maybe_put_query_string(_method, path, _params), do: path

  defp json_response(conn), do: Jason.decode!(conn.resp_body)

  describe "GET /v1/customers/search" do
    test "filters by string, metadata, numeric clauses, and negation" do
      target =
        create_customer(%{
          "created" => 2_000,
          "email" => "search-target@example.com",
          "metadata" => %{"batch" => "search-suite", "tier" => "gold"},
          "name" => "Search Target"
        })

      _other =
        create_customer(%{
          "created" => 1_500,
          "email" => "other@example.com",
          "metadata" => %{"batch" => "search-suite", "tier" => "gold"},
          "name" => "Other Person"
        })

      conn =
        request(:get, "/v1/customers/search", %{
          "query" => "email:'search-target@example.com' AND metadata['tier']:'gold' AND created>=2000"
        })

      assert conn.status == 200
      result = json_response(conn)
      assert result["object"] == "search_result"
      assert result["url"] == "/v1/customers/search"
      assert result["has_more"] == false
      assert result["next_page"] == nil
      assert Enum.map(result["data"], & &1["id"]) == [target["id"]]

      conn =
        request(:get, "/v1/customers/search", %{
          "query" => "metadata['batch']:'search-suite' AND -email:'other@example.com'"
        })

      assert conn.status == 200
      assert json_response(conn)["data"] |> Enum.map(& &1["id"]) == [target["id"]]
    end

    test "supports substring matching and search pagination" do
      customers =
        for created <- [10, 20, 30] do
          create_customer(%{
            "created" => created,
            "email" => "page-#{created}@example.com",
            "metadata" => %{"batch" => "page"},
            "name" => "Page Target #{created}"
          })
        end

      expected_ids =
        customers
        |> Enum.sort_by(& &1["created"], :desc)
        |> Enum.map(& &1["id"])

      first =
        request(:get, "/v1/customers/search", %{
          "limit" => "2",
          "query" => "name~'target' AND metadata['batch']:'page'"
        })
        |> json_response()

      assert first["has_more"] == true
      assert is_binary(first["next_page"])
      assert Enum.map(first["data"], & &1["id"]) == Enum.take(expected_ids, 2)

      second =
        request(:get, "/v1/customers/search", %{
          "limit" => "2",
          "page" => first["next_page"],
          "query" => "name~'target' AND metadata['batch']:'page'"
        })
        |> json_response()

      assert second["has_more"] == false
      assert second["next_page"] == nil
      assert Enum.map(second["data"], & &1["id"]) == Enum.drop(expected_ids, 2)
    end

    test "supports OR queries without mixing boolean connectors" do
      first = create_customer(%{"email" => "or-one@example.com", "metadata" => %{"group" => "or-test"}})
      second = create_customer(%{"email" => "or-two@example.com", "metadata" => %{"group" => "or-test"}})

      conn =
        request(:get, "/v1/customers/search", %{
          "query" => "email:'or-one@example.com' OR email:'or-two@example.com'"
        })

      assert conn.status == 200
      ids = conn |> json_response() |> Map.fetch!("data") |> Enum.map(& &1["id"])
      assert Enum.sort(ids) == Enum.sort([first["id"], second["id"]])
    end
  end

  describe "search endpoints across resources" do
    test "searches payment intents, charges, invoices, and subscriptions with resource schemas" do
      customer = create_customer(%{"email" => "resource-search@example.com"})
      product = create_product(%{"name" => "Resource Search"})

      price =
        create_price(%{
          "currency" => "usd",
          "product" => product["id"],
          "recurring" => %{"interval" => "month"},
          "unit_amount" => 1200
        })

      payment_intent =
        create_payment_intent(%{
          "amount" => 2_500,
          "currency" => "usd",
          "customer" => customer["id"],
          "metadata" => %{"case" => "pi"}
        })

      charge =
        create_charge(%{
          "amount" => 800,
          "currency" => "usd",
          "customer" => customer["id"],
          "metadata" => %{"case" => "charge"}
        })

      invoice =
        create_invoice(%{
          "customer" => customer["id"],
          "metadata" => %{"case" => "invoice"},
          "total" => 1_200
        })

      subscription =
        create_subscription(%{
          "customer" => customer["id"],
          "items" => [%{"price" => price["id"]}],
          "metadata" => %{"case" => "subscription"}
        })

      assert one_result_id("/v1/payment_intents/search", "customer:'#{customer["id"]}' AND amount>=2500") ==
               payment_intent["id"]

      assert one_result_id("/v1/charges/search", "customer:'#{customer["id"]}' AND amount=800") == charge["id"]

      assert one_result_id("/v1/invoices/search", "customer:'#{customer["id"]}' AND total>=1200") == invoice["id"]

      assert one_result_id("/v1/subscriptions/search", "metadata['case']:'subscription' AND status:'active'") ==
               subscription["id"]
    end
  end

  describe "search errors" do
    test "returns Stripe-shaped errors for unsupported fields and operators" do
      conn = request(:get, "/v1/customers/search", %{"query" => "customer:'cus_123'"})

      assert conn.status == 400
      error = json_response(conn)["error"]
      assert error["type"] == "invalid_request_error"
      assert error["param"] == "query"
      assert error["message"] =~ "Unsupported search field"

      conn = request(:get, "/v1/customers/search", %{"query" => "email:'a' AND email:'b' OR email:'c'"})

      assert conn.status == 400
      assert json_response(conn)["error"]["message"] =~ "cannot mix AND and OR"

      conn = request(:get, "/v1/customers/search", %{"query" => "metadata['tier']~'gold'"})

      assert conn.status == 400
      assert json_response(conn)["error"]["message"] =~ "Substring search is only supported"
    end
  end

  defp create_customer(params), do: create(:post, "/v1/customers", params)
  defp create_payment_intent(params), do: create(:post, "/v1/payment_intents", params)
  defp create_charge(params), do: create(:post, "/v1/charges", params)
  defp create_invoice(params), do: create(:post, "/v1/invoices", params)
  defp create_product(params), do: create(:post, "/v1/products", params)
  defp create_price(params), do: create(:post, "/v1/prices", params)
  defp create_subscription(params), do: create(:post, "/v1/subscriptions", params)

  defp create(method, path, params) do
    conn = request(method, path, params)
    assert conn.status == 200
    json_response(conn)
  end

  defp one_result_id(path, query) do
    conn = request(:get, path, %{"query" => query})
    assert conn.status == 200

    result = json_response(conn)
    assert result["object"] == "search_result"
    assert length(result["data"]) == 1

    result["data"] |> List.first() |> Map.fetch!("id")
  end
end
