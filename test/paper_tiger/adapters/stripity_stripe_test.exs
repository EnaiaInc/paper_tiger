defmodule PaperTiger.Adapters.StripityStripeTest do
  use ExUnit.Case, async: true

  import PaperTiger.Test

  alias PaperTiger.Adapters.StripityStripe
  alias PaperTiger.Store.{Customers, PaymentMethods, Plans, Prices, Products, Subscriptions}

  setup :checkout_paper_tiger

  # Mock Repo for testing
  defmodule MockRepo do
    def query(sql, params \\ [])

    def query(sql, _params) do
      cond do
        # Check most specific queries first (ones with multiple JOINs)
        String.contains?(sql, "billing_subscriptions") ->
          {:ok,
           %{
             columns: [
               "id",
               "stripe_id",
               "status",
               "current_period_start_at",
               "current_period_end_at",
               "cancel_at",
               "customer_id",
               "customer_stripe_id",
               "plan_id",
               "plan_stripe_id",
               "inserted_at",
               "updated_at"
             ],
             rows: [
               [
                 1,
                 "sub_test1",
                 "active",
                 ~N[2024-01-01 00:00:00],
                 ~N[2024-02-01 00:00:00],
                 nil,
                 1,
                 "cus_test1",
                 1,
                 "plan_test1",
                 ~N[2024-01-01 00:00:00],
                 ~N[2024-01-01 00:00:00]
               ]
             ]
           }}

        String.contains?(sql, "billing_prices") ->
          {:ok,
           %{
             columns: [
               "id",
               "stripe_id",
               "unit_amount",
               "currency",
               "recurring_interval",
               "recurring_interval_count",
               "product_id",
               "product_stripe_id",
               "active",
               "metadata",
               "inserted_at",
               "updated_at"
             ],
             rows: [
               [
                 1,
                 "price_test1",
                 1000,
                 "usd",
                 "month",
                 1,
                 1,
                 "prod_test1",
                 true,
                 "{}",
                 ~N[2024-01-01 00:00:00],
                 ~N[2024-01-01 00:00:00]
               ]
             ]
           }}

        String.contains?(sql, "billing_plans") ->
          {:ok,
           %{
             columns: [
               "id",
               "stripe_id",
               "amount",
               "currency",
               "interval",
               "interval_count",
               "product_id",
               "product_stripe_id",
               "active",
               "metadata",
               "inserted_at",
               "updated_at"
             ],
             rows: [
               [
                 1,
                 "plan_test1",
                 2000,
                 "usd",
                 "month",
                 1,
                 1,
                 "prod_test1",
                 true,
                 "{}",
                 ~N[2024-01-01 00:00:00],
                 ~N[2024-01-01 00:00:00]
               ]
             ]
           }}

        String.contains?(sql, "billing_payment_methods") ->
          {:ok,
           %{
             columns: [
               "id",
               "stripe_id",
               "customer_id",
               "customer_stripe_id",
               "card_brand",
               "card_last4",
               "card_exp_month",
               "card_exp_year",
               "card_fingerprint",
               "metadata",
               "inserted_at",
               "updated_at"
             ],
             rows: [
               [
                 1,
                 "pm_test1",
                 1,
                 "cus_test1",
                 "visa",
                 "4242",
                 12,
                 2030,
                 "pm_test1_fingerprint",
                 "{}",
                 ~N[2024-01-01 00:00:00],
                 ~N[2024-01-01 00:00:00]
               ]
             ]
           }}

        String.contains?(sql, "billing_customers") ->
          {:ok,
           %{
             columns: [
               "id",
               "stripe_id",
               "user_id",
               "default_source",
               "inserted_at",
               "updated_at"
             ],
             rows: [
               [1, "cus_test1", 1, "pm_card_visa", ~N[2024-01-01 00:00:00], ~N[2024-01-01 00:00:00]]
             ]
           }}

        String.contains?(sql, "billing_products") ->
          {:ok,
           %{
             columns: [
               "id",
               "stripe_id",
               "name",
               "active",
               "metadata",
               "inserted_at",
               "updated_at"
             ],
             rows: [
               [
                 1,
                 "prod_test1",
                 "Test Product",
                 true,
                 ~s({"key":"value"}),
                 ~N[2024-01-01 00:00:00],
                 ~N[2024-01-01 00:00:00]
               ]
             ]
           }}

        true ->
          {:ok, %{columns: [], rows: []}}
      end
    end
  end

  # Mock User Adapter
  defmodule MockUserAdapter do
    def get_user_info(_repo, 1) do
      {:ok, %{email: "test@example.com", name: "Test User"}}
    end

    def get_user_info(_repo, _user_id) do
      {:error, :user_not_found}
    end
  end

  describe "sync_all/0 with repo configured" do
    setup do
      # Configure mock repo
      Application.put_env(:paper_tiger, :repo, MockRepo)
      Application.put_env(:paper_tiger, :user_adapter, MockUserAdapter)

      on_exit(fn ->
        Application.delete_env(:paper_tiger, :repo)
        Application.delete_env(:paper_tiger, :user_adapter)
      end)

      :ok
    end

    test "syncs products from database" do
      {:ok, _} = StripityStripe.sync_all()
      {:ok, product} = Products.get("prod_test1")
      assert product.name == "Test Product"
      assert product.active == true
      assert product.metadata == %{"key" => "value"}
    end

    test "syncs prices from database" do
      {:ok, _} = StripityStripe.sync_all()
      {:ok, price} = Prices.get("price_test1")
      assert price.unit_amount == 1000
      assert price.currency == "usd"
      assert price.recurring.interval == "month"
      assert price.product == "prod_test1"
    end

    test "syncs plans from database" do
      {:ok, _} = StripityStripe.sync_all()
      {:ok, plan} = Plans.get("plan_test1")
      assert plan.amount == 2000
      assert plan.currency == "usd"
      assert plan.interval == "month"
      assert plan.product == "prod_test1"
    end

    test "syncs customers with user info from database" do
      {:ok, _} = StripityStripe.sync_all()
      {:ok, customer} = Customers.get("cus_test1")
      assert customer.name == "Test User"
      assert customer.email == "test@example.com"
      assert customer.default_source == "pm_card_visa"
    end

    test "syncs subscriptions from database" do
      {:ok, _} = StripityStripe.sync_all()
      {:ok, subscription} = Subscriptions.get("sub_test1")
      assert subscription.status == "active"
      assert subscription.customer == "cus_test1"
      assert subscription.items.data |> List.first() |> Map.get(:plan) == "plan_test1"
    end

    test "syncs payment methods from database" do
      {:ok, _} = StripityStripe.sync_all()
      {:ok, pm} = PaymentMethods.get("pm_test1")
      assert pm.id == "pm_test1"
      assert pm.customer == "cus_test1"
      assert pm.card.last4 == "4242"
    end

    test "returns stats for all synced entities" do
      {:ok, stats} = StripityStripe.sync_all()

      assert stats.products == 1
      assert stats.prices == 1
      assert stats.plans == 1
      assert stats.customers == 1
      assert stats.subscriptions == 1
      # 2 payment methods: 1 from DB (pm_test1) + 1 fake for customer's default_source (pm_card_visa)
      assert stats.payment_methods == 2
    end

    test "creates fake payment method for customer's default_source when missing" do
      defmodule MockRepoNoPaymentMethods do
        def query(sql, params \\ [])

        def query(sql, _params) do
          cond do
            String.contains?(sql, "billing_subscriptions") ->
              {:ok, %{columns: [], rows: []}}

            String.contains?(sql, "billing_prices") ->
              {:ok, %{columns: [], rows: []}}

            String.contains?(sql, "billing_plans") ->
              {:ok, %{columns: [], rows: []}}

            String.contains?(sql, "billing_products") ->
              {:ok, %{columns: [], rows: []}}

            String.contains?(sql, "billing_payment_methods") ->
              {:ok, %{columns: [], rows: []}}

            String.contains?(sql, "billing_customers") ->
              {:ok,
               %{
                 columns: ["id", "stripe_id", "user_id", "default_source", "inserted_at", "updated_at"],
                 rows: [[1, "cus_test2", 1, "pm_missing", ~N[2024-01-01 00:00:00], ~N[2024-01-01 00:00:00]]]
               }}

            true ->
              {:ok, %{columns: [], rows: []}}
          end
        end
      end

      Application.put_env(:paper_tiger, :repo, MockRepoNoPaymentMethods)
      Application.put_env(:paper_tiger, :user_adapter, MockUserAdapter)

      on_exit(fn ->
        Application.put_env(:paper_tiger, :repo, MockRepo)
        Application.put_env(:paper_tiger, :user_adapter, MockUserAdapter)
      end)

      {:ok, _} = StripityStripe.sync_all()
      {:ok, pm} = PaymentMethods.get("pm_missing")
      assert pm.id == "pm_missing"
      assert pm.customer == "cus_test2"
    end
  end

  describe "sync_all/0 without repo configured" do
    test "returns error when repo not configured" do
      Application.delete_env(:paper_tiger, :repo)

      assert {:error, :no_repo_configured} = StripityStripe.sync_all()
    end
  end

  describe "sync_all/0 without stripity_stripe tables" do
    defmodule EmptyRepo do
      def query(sql, params \\ [])
      def query(_, _), do: {:ok, %{columns: [], rows: []}}
    end

    setup do
      # Configure repo that returns empty results (tables don't exist)
      Application.put_env(:paper_tiger, :repo, EmptyRepo)
      Application.put_env(:paper_tiger, :user_adapter, MockUserAdapter)

      on_exit(fn ->
        Application.delete_env(:paper_tiger, :repo)
        Application.delete_env(:paper_tiger, :user_adapter)
      end)
    end

    test "handles missing tables gracefully" do
      assert {:ok, stats} = StripityStripe.sync_all()

      # Should succeed but with zero entities
      assert stats.products == 0
      assert stats.prices == 0
      assert stats.plans == 0
      assert stats.customers == 0
      assert stats.subscriptions == 0
    end
  end
end
