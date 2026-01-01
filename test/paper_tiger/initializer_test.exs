defmodule PaperTiger.InitializerTest do
  use ExUnit.Case, async: false

  alias PaperTiger.Initializer
  alias PaperTiger.Store.{Customers, Plans, Prices, Products}

  setup do
    PaperTiger.flush()
    :ok
  end

  describe "load_from_map/1" do
    test "loads products" do
      data = %{
        "products" => [
          %{
            "active" => true,
            "id" => "prod_test_1",
            "metadata" => %{"key" => "value"},
            "name" => "Test Product"
          }
        ]
      }

      assert {:ok, stats} = Initializer.load_from_map(data)
      assert stats.products == 1
      assert stats.prices == 0
      assert stats.plans == 0
      assert stats.customers == 0

      assert {:ok, product} = Products.get("prod_test_1")
      assert product.name == "Test Product"
      assert product.metadata == %{key: "value"}
    end

    test "loads prices" do
      # Create product first
      Products.insert(%{
        active: true,
        created: PaperTiger.now(),
        id: "prod_for_price",
        name: "Product for Price",
        object: "product"
      })

      data = %{
        "prices" => [
          %{
            "currency" => "usd",
            "id" => "price_test_1",
            "product" => "prod_for_price",
            "recurring" => %{"interval" => "month", "interval_count" => 1},
            "unit_amount" => 1000
          }
        ]
      }

      assert {:ok, stats} = Initializer.load_from_map(data)
      assert stats.prices == 1

      assert {:ok, price} = Prices.get("price_test_1")
      assert price.unit_amount == 1000
      assert price.recurring == %{interval: "month", interval_count: 1}
    end

    test "loads plans" do
      # Create product first
      Products.insert(%{
        active: true,
        created: PaperTiger.now(),
        id: "prod_for_plan",
        name: "Product for Plan",
        object: "product"
      })

      data = %{
        "plans" => [
          %{
            "amount" => 4900,
            "currency" => "usd",
            "id" => "plan_test_1",
            "interval" => "month",
            "interval_count" => 1,
            "nickname" => "Test Plan Monthly",
            "product" => "prod_for_plan"
          }
        ]
      }

      assert {:ok, stats} = Initializer.load_from_map(data)
      assert stats.plans == 1

      assert {:ok, plan} = Plans.get("plan_test_1")
      assert plan.amount == 4900
      assert plan.currency == "usd"
      assert plan.interval == "month"
      assert plan.interval_count == 1
      assert plan.nickname == "Test Plan Monthly"
      assert plan.product == "prod_for_plan"
    end

    test "loads customers" do
      data = %{
        "customers" => [
          %{
            "email" => "test@example.com",
            "id" => "cus_test_1",
            "metadata" => %{"source" => "init_data"},
            "name" => "Test Customer"
          }
        ]
      }

      assert {:ok, stats} = Initializer.load_from_map(data)
      assert stats.customers == 1

      assert {:ok, customer} = Customers.get("cus_test_1")
      assert customer.email == "test@example.com"
      assert customer.name == "Test Customer"
      assert customer.metadata == %{source: "init_data"}
    end

    test "loads all entity types together" do
      data = %{
        "customers" => [
          %{"email" => "combo@example.com", "id" => "cus_combo_1"}
        ],
        "plans" => [
          %{
            "amount" => 1000,
            "currency" => "usd",
            "id" => "plan_combo_1",
            "interval" => "month",
            "nickname" => "Combo Plan",
            "product" => "prod_combo_1"
          }
        ],
        "prices" => [
          %{
            "currency" => "usd",
            "id" => "price_combo_1",
            "product" => "prod_combo_1",
            "unit_amount" => 1000
          }
        ],
        "products" => [
          %{"id" => "prod_combo_1", "name" => "Combo Product"}
        ]
      }

      assert {:ok, stats} = Initializer.load_from_map(data)
      assert stats.products == 1
      assert stats.plans == 1
      assert stats.prices == 1
      assert stats.customers == 1
    end

    test "supports atom keys" do
      data = %{
        plans: [
          %{
            amount: 500,
            currency: "usd",
            id: "plan_atom_1",
            interval: "year",
            nickname: "Atom Plan",
            product: "prod_atom_1"
          }
        ],
        products: [
          %{id: "prod_atom_1", name: "Atom Product"}
        ]
      }

      assert {:ok, stats} = Initializer.load_from_map(data)
      assert stats.products == 1
      assert stats.plans == 1

      assert {:ok, plan} = Plans.get("plan_atom_1")
      assert plan.interval == "year"
    end

    test "generates IDs when not provided" do
      data = %{
        "plans" => [
          %{
            "amount" => 999,
            "currency" => "usd",
            "interval" => "month",
            "nickname" => "Auto ID Plan"
          }
        ]
      }

      assert {:ok, stats} = Initializer.load_from_map(data)
      assert stats.plans == 1

      # Verify a plan was created with auto-generated ID
      result = Plans.list(limit: 10)
      assert length(result.data) == 1
      [plan] = result.data
      assert String.starts_with?(plan.id, "plan_")
      assert plan.nickname == "Auto ID Plan"
    end

    test "atomizes nested metadata keys" do
      data = %{
        "plans" => [
          %{
            "amount" => 100,
            "currency" => "usd",
            "id" => "plan_meta_1",
            "interval" => "month",
            "metadata" => %{"credits" => "50", "tier" => "premium"}
          }
        ]
      }

      assert {:ok, _stats} = Initializer.load_from_map(data)

      {:ok, plan} = Plans.get("plan_meta_1")
      assert plan.metadata == %{credits: "50", tier: "premium"}
    end

    test "returns empty stats for empty data" do
      assert {:ok, stats} = Initializer.load_from_map(%{})

      assert stats.products == 0
      assert stats.prices == 0
      assert stats.plans == 0
      assert stats.customers == 0
    end
  end

  describe "load_from_file/1" do
    @tag :tmp_dir
    test "loads data from JSON file", %{tmp_dir: tmp_dir} do
      json_content = """
      {
        "plans": [
          {
            "id": "plan_file_1",
            "amount": 2500,
            "currency": "usd",
            "interval": "month",
            "nickname": "File Plan"
          }
        ],
        "products": [
          {
            "id": "prod_file_1",
            "name": "File Product"
          }
        ]
      }
      """

      file_path = Path.join(tmp_dir, "test_init_data.json")
      File.write!(file_path, json_content)

      assert {:ok, stats} = Initializer.load_from_file(file_path)
      assert stats.plans == 1
      assert stats.products == 1

      {:ok, plan} = Plans.get("plan_file_1")
      assert plan.nickname == "File Plan"
    end

    test "returns error for non-existent file" do
      assert {:error, {:init_data_file_error, :enoent}} =
               Initializer.load_from_file("/nonexistent/file.json")
    end

    @tag :tmp_dir
    test "returns error for invalid JSON", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "invalid.json")
      File.write!(file_path, "not valid json {{{")

      assert {:error, {:init_data_file_error, _reason}} = Initializer.load_from_file(file_path)
    end
  end

  describe "load/0" do
    test "returns message when no init_data configured" do
      # Clear any existing config
      Application.delete_env(:paper_tiger, :init_data)

      assert {:ok, %{message: "No init_data configured"}} = Initializer.load()
    end

    test "returns error for invalid init_data config" do
      Application.put_env(:paper_tiger, :init_data, :invalid)

      assert {:error, {:invalid_init_data_config, :invalid}} = Initializer.load()

      Application.delete_env(:paper_tiger, :init_data)
    end
  end
end
