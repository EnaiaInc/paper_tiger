defmodule PaperTiger.BillingEngineTest do
  use ExUnit.Case, async: false

  alias PaperTiger.BillingEngine
  alias PaperTiger.Store.{Charges, Customers, Invoices, Plans, Prices, Products, Subscriptions}

  setup do
    PaperTiger.flush()

    # Create a test product
    {:ok, _product} =
      Products.insert(%{
        active: true,
        created: PaperTiger.now(),
        id: "prod_test",
        name: "Test Product",
        object: "product"
      })

    # Create a test price
    {:ok, _price} =
      Prices.insert(%{
        active: true,
        created: PaperTiger.now(),
        currency: "usd",
        id: "price_test",
        object: "price",
        product: "prod_test",
        recurring: %{interval: "month", interval_count: 1},
        unit_amount: 2000
      })

    # Create a test plan
    {:ok, _plan} =
      Plans.insert(%{
        active: true,
        amount: 2000,
        created: PaperTiger.now(),
        currency: "usd",
        id: "plan_test",
        interval: "month",
        interval_count: 1,
        object: "plan",
        product: "prod_test"
      })

    # Create a test customer
    {:ok, customer} =
      Customers.insert(%{
        created: PaperTiger.now(),
        email: "test@example.com",
        id: "cus_test",
        name: "Test Customer",
        object: "customer"
      })

    %{customer: customer}
  end

  describe "process_billing/0" do
    test "processes subscription that is due", %{customer: customer} do
      now = PaperTiger.now()
      past = now - 86_400

      # Create subscription with period_end in the past
      {:ok, _sub} =
        Subscriptions.insert(%{
          created: past - 2_592_000,
          current_period_end: past,
          current_period_start: past - 2_592_000,
          customer: customer.id,
          id: "sub_due",
          items: %{
            data: [%{price: "price_test"}]
          },
          object: "subscription",
          plan: %{interval: "month", interval_count: 1},
          status: "active"
        })

      # Start billing engine in happy_path mode
      start_supervised!({BillingEngine, []})
      BillingEngine.set_mode(:happy_path)

      # Process billing
      {:ok, stats} = BillingEngine.process_billing()

      assert stats.processed == 1
      assert stats.succeeded == 1
      assert stats.failed == 0

      # Verify invoice was created
      %{data: invoices} = Invoices.list(%{})
      assert length(invoices) == 1
      [invoice] = invoices
      assert invoice.customer == customer.id
      assert invoice.status == "paid"
      assert invoice.amount_due == 2000

      # Verify charge was created
      %{data: charges} = Charges.list(%{})
      assert length(charges) == 1
      [charge] = charges
      assert charge.status == "succeeded"
      assert charge.amount == 2000

      # Verify subscription period was advanced
      {:ok, updated_sub} = Subscriptions.get("sub_due")
      assert updated_sub.current_period_start == past
      assert updated_sub.current_period_end > past
    end

    test "does not process subscription that is not due", %{customer: customer} do
      now = PaperTiger.now()
      future = now + 86_400

      {:ok, _sub} =
        Subscriptions.insert(%{
          created: now,
          current_period_end: future,
          current_period_start: now,
          customer: customer.id,
          id: "sub_not_due",
          items: %{
            data: [%{price: "price_test"}]
          },
          object: "subscription",
          plan: %{interval: "month", interval_count: 1},
          status: "active"
        })

      start_supervised!({BillingEngine, []})
      BillingEngine.set_mode(:happy_path)

      {:ok, stats} = BillingEngine.process_billing()

      assert stats.processed == 0
      assert stats.succeeded == 0
      assert stats.failed == 0

      # No invoices should be created
      %{data: invoices} = Invoices.list(%{})
      assert Enum.empty?(invoices)
    end

    test "does not process inactive subscriptions", %{customer: customer} do
      now = PaperTiger.now()
      past = now - 86_400

      {:ok, _sub} =
        Subscriptions.insert(%{
          created: past - 2_592_000,
          current_period_end: past,
          current_period_start: past - 2_592_000,
          customer: customer.id,
          id: "sub_inactive",
          items: %{
            data: [%{price: "price_test"}]
          },
          object: "subscription",
          plan: %{interval: "month", interval_count: 1},
          status: "canceled"
        })

      start_supervised!({BillingEngine, []})

      {:ok, stats} = BillingEngine.process_billing()

      assert stats.processed == 0
    end
  end

  describe "simulate_failure/2 and clear_simulation/1" do
    test "simulates payment failure for specific customer", %{customer: customer} do
      now = PaperTiger.now()
      past = now - 86_400

      {:ok, _sub} =
        Subscriptions.insert(%{
          created: past - 2_592_000,
          current_period_end: past,
          current_period_start: past - 2_592_000,
          customer: customer.id,
          id: "sub_fail",
          items: %{
            data: [%{price: "price_test"}]
          },
          object: "subscription",
          plan: %{interval: "month", interval_count: 1},
          status: "active"
        })

      start_supervised!({BillingEngine, []})
      BillingEngine.set_mode(:happy_path)

      # Simulate failure for this customer
      :ok = BillingEngine.simulate_failure(customer.id, :card_declined)

      {:ok, stats} = BillingEngine.process_billing()

      assert stats.processed == 1
      assert stats.succeeded == 0
      assert stats.failed == 1

      # Invoice should be created but marked as open (not paid)
      %{data: invoices} = Invoices.list(%{})
      assert length(invoices) == 1
      [invoice] = invoices
      assert invoice.status == "open"

      # Charge should be created but failed
      %{data: charges} = Charges.list(%{})
      assert length(charges) == 1
      [charge] = charges
      assert charge.status == "failed"
      assert charge.failure_code == "card_declined"
    end

    test "clear_simulation allows future payments to succeed", %{customer: customer} do
      start_supervised!({BillingEngine, []})
      BillingEngine.set_mode(:happy_path)

      # Set and then clear failure simulation
      :ok = BillingEngine.simulate_failure(customer.id, :insufficient_funds)
      :ok = BillingEngine.clear_simulation(customer.id)

      now = PaperTiger.now()
      past = now - 86_400

      {:ok, _sub} =
        Subscriptions.insert(%{
          created: past - 2_592_000,
          current_period_end: past,
          current_period_start: past - 2_592_000,
          customer: customer.id,
          id: "sub_clear",
          items: %{
            data: [%{price: "price_test"}]
          },
          object: "subscription",
          plan: %{interval: "month", interval_count: 1},
          status: "active"
        })

      {:ok, stats} = BillingEngine.process_billing()

      # Should succeed since simulation was cleared
      assert stats.succeeded == 1
    end
  end

  describe "set_mode/2 and get_mode/0" do
    test "starts in happy_path mode by default" do
      start_supervised!({BillingEngine, []})

      assert BillingEngine.get_mode() == :happy_path
    end

    test "can switch to chaos mode" do
      start_supervised!({BillingEngine, []})

      :ok = BillingEngine.set_mode(:chaos, payment_failure_rate: 0.5)

      assert BillingEngine.get_mode() == :chaos
    end

    test "can switch back to happy_path mode" do
      start_supervised!({BillingEngine, []})

      :ok = BillingEngine.set_mode(:chaos)
      :ok = BillingEngine.set_mode(:happy_path)

      assert BillingEngine.get_mode() == :happy_path
    end
  end

  describe "chaos mode" do
    test "produces some failures with high failure rate", %{customer: _customer} do
      now = PaperTiger.now()
      past = now - 86_400

      # Create multiple subscriptions to increase chances of seeing both outcomes
      for i <- 1..10 do
        Customers.insert(%{
          created: PaperTiger.now(),
          email: "chaos#{i}@example.com",
          id: "cus_chaos_#{i}",
          object: "customer"
        })

        Subscriptions.insert(%{
          created: past - 2_592_000,
          current_period_end: past,
          current_period_start: past - 2_592_000,
          customer: "cus_chaos_#{i}",
          id: "sub_chaos_#{i}",
          items: %{
            data: [%{price: "price_test"}]
          },
          object: "subscription",
          plan: %{interval: "month", interval_count: 1},
          status: "active"
        })
      end

      start_supervised!({BillingEngine, []})

      # Set very high failure rate
      :ok = BillingEngine.set_mode(:chaos, payment_failure_rate: 1.0)

      {:ok, stats} = BillingEngine.process_billing()

      # All should fail with 100% failure rate
      assert stats.processed == 10
      assert stats.failed == 10
      assert stats.succeeded == 0
    end
  end

  describe "plan-based billing" do
    test "uses plan amount when subscription has plan reference", %{customer: customer} do
      now = PaperTiger.now()
      past = now - 86_400

      {:ok, _sub} =
        Subscriptions.insert(%{
          created: past - 2_592_000,
          current_period_end: past,
          current_period_start: past - 2_592_000,
          customer: customer.id,
          id: "sub_plan",
          items: %{data: []},
          object: "subscription",
          plan: "plan_test",
          status: "active"
        })

      start_supervised!({BillingEngine, []})
      BillingEngine.set_mode(:happy_path)

      {:ok, _stats} = BillingEngine.process_billing()

      %{data: invoices} = Invoices.list(%{})
      [invoice] = invoices
      assert invoice.amount_due == 2000
    end
  end

  describe "subscription period advancement" do
    test "advances monthly subscription by one month", %{customer: customer} do
      now = PaperTiger.now()
      past = now - 86_400

      {:ok, _sub} =
        Subscriptions.insert(%{
          created: past - 2_592_000,
          current_period_end: past,
          current_period_start: past - 2_592_000,
          customer: customer.id,
          id: "sub_monthly",
          items: %{
            data: [%{price: "price_test"}]
          },
          object: "subscription",
          plan: %{interval: "month", interval_count: 1},
          status: "active"
        })

      start_supervised!({BillingEngine, []})
      BillingEngine.set_mode(:happy_path)

      {:ok, _stats} = BillingEngine.process_billing()

      {:ok, updated_sub} = Subscriptions.get("sub_monthly")

      # New period start should be old period end
      assert updated_sub.current_period_start == past

      # New period end should be ~30 days later (2,592,000 seconds)
      expected_end = past + 2_592_000
      assert updated_sub.current_period_end == expected_end
    end
  end

  describe "failed payment handling" do
    test "increments attempt_count on failure", %{customer: customer} do
      start_supervised!({BillingEngine, []})

      now = PaperTiger.now()
      past = now - 86_400

      {:ok, _sub} =
        Subscriptions.insert(%{
          created: past - 2_592_000,
          current_period_end: past,
          current_period_start: past - 2_592_000,
          customer: customer.id,
          id: "sub_fail_attempt",
          items: %{
            data: [%{price: "price_test"}]
          },
          object: "subscription",
          plan: %{interval: "month", interval_count: 1},
          status: "active"
        })

      BillingEngine.simulate_failure(customer.id, :card_declined)
      {:ok, _stats} = BillingEngine.process_billing()

      # Verify invoice has attempt_count set
      %{data: invoices} = Invoices.list(%{})
      [invoice] = invoices
      assert invoice.attempt_count == 1
      assert invoice.status == "open"
    end
  end
end
