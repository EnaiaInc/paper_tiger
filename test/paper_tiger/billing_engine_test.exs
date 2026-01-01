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

    test "retries existing open invoice instead of creating new one", %{customer: customer} do
      start_supervised!({BillingEngine, []})

      now = PaperTiger.now()
      past = now - 86_400

      {:ok, _sub} =
        Subscriptions.insert(%{
          created: past - 2_592_000,
          current_period_end: past,
          current_period_start: past - 2_592_000,
          customer: customer.id,
          id: "sub_retry",
          items: %{
            data: [%{price: "price_test"}]
          },
          object: "subscription",
          plan: %{interval: "month", interval_count: 1},
          status: "active"
        })

      BillingEngine.simulate_failure(customer.id, :card_declined)

      # First billing attempt
      {:ok, _stats} = BillingEngine.process_billing()

      %{data: invoices_after_first} = Invoices.list(%{})
      assert length(invoices_after_first) == 1
      [first_invoice] = invoices_after_first
      assert first_invoice.attempt_count == 1

      # Second billing attempt - should retry same invoice
      {:ok, _stats} = BillingEngine.process_billing()

      %{data: invoices_after_second} = Invoices.list(%{})
      assert length(invoices_after_second) == 1
      [second_invoice] = invoices_after_second
      assert second_invoice.id == first_invoice.id
      assert second_invoice.attempt_count == 2

      # Third billing attempt
      {:ok, _stats} = BillingEngine.process_billing()

      %{data: invoices_after_third} = Invoices.list(%{})
      assert length(invoices_after_third) == 1
      [third_invoice] = invoices_after_third
      assert third_invoice.attempt_count == 3
    end

    test "marks subscription past_due after 4 failed attempts", %{customer: customer} do
      start_supervised!({BillingEngine, []})

      now = PaperTiger.now()
      past = now - 86_400

      {:ok, _sub} =
        Subscriptions.insert(%{
          created: past - 2_592_000,
          current_period_end: past,
          current_period_start: past - 2_592_000,
          customer: customer.id,
          id: "sub_past_due",
          items: %{
            data: [%{price: "price_test"}]
          },
          object: "subscription",
          plan: %{interval: "month", interval_count: 1},
          status: "active"
        })

      BillingEngine.simulate_failure(customer.id, :card_declined)

      # Run 4 billing attempts
      for attempt <- 1..4 do
        {:ok, _stats} = BillingEngine.process_billing()

        {:ok, sub} = Subscriptions.get("sub_past_due")

        if attempt < 4 do
          assert sub.status == "active", "Expected active after attempt #{attempt}"
        else
          assert sub.status == "past_due", "Expected past_due after attempt #{attempt}"
        end
      end

      # Verify only one invoice was created
      %{data: invoices} = Invoices.list(%{})
      assert length(invoices) == 1
      [invoice] = invoices
      assert invoice.attempt_count == 4
    end
  end

  describe "extended decline codes" do
    test "supports extended decline codes", %{customer: customer} do
      start_supervised!({BillingEngine, []})

      now = PaperTiger.now()
      past = now - 86_400

      {:ok, _sub} =
        Subscriptions.insert(%{
          created: past - 2_592_000,
          current_period_end: past,
          current_period_start: past - 2_592_000,
          customer: customer.id,
          id: "sub_extended_code",
          items: %{
            data: [%{price: "price_test"}]
          },
          object: "subscription",
          plan: %{interval: "month", interval_count: 1},
          status: "active"
        })

      # Test various extended decline codes
      extended_codes = [
        :do_not_honor,
        :lost_card,
        :stolen_card,
        :fraudulent,
        :incorrect_cvc,
        :incorrect_zip,
        :authentication_required,
        :card_velocity_exceeded
      ]

      for code <- extended_codes do
        PaperTiger.flush()

        Products.insert(%{
          active: true,
          created: PaperTiger.now(),
          id: "prod_test",
          name: "Test Product",
          object: "product"
        })

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

        Customers.insert(%{
          created: PaperTiger.now(),
          email: "test@example.com",
          id: customer.id,
          name: "Test Customer",
          object: "customer"
        })

        Subscriptions.insert(%{
          created: past - 2_592_000,
          current_period_end: past,
          current_period_start: past - 2_592_000,
          customer: customer.id,
          id: "sub_extended_code",
          items: %{
            data: [%{price: "price_test"}]
          },
          object: "subscription",
          plan: %{interval: "month", interval_count: 1},
          status: "active"
        })

        BillingEngine.simulate_failure(customer.id, code)
        {:ok, _stats} = BillingEngine.process_billing()

        %{data: charges} = Charges.list(%{})
        assert length(charges) == 1
        [charge] = charges
        assert charge.status == "failed"
        assert charge.failure_code == to_string(code)
        assert is_binary(charge.failure_message)
      end
    end

    test "chaos mode can use extended decline codes" do
      PaperTiger.flush()

      # Create test product and price
      Products.insert(%{
        active: true,
        created: PaperTiger.now(),
        id: "prod_extended",
        name: "Extended Test Product",
        object: "product"
      })

      Prices.insert(%{
        active: true,
        created: PaperTiger.now(),
        currency: "usd",
        id: "price_extended",
        object: "price",
        product: "prod_extended",
        recurring: %{interval: "month", interval_count: 1},
        unit_amount: 2000
      })

      start_supervised!({BillingEngine, []})

      now = PaperTiger.now()
      past = now - 86_400

      # Create 5 subscriptions to test (smaller number for simpler test)
      for i <- 1..5 do
        Customers.insert(%{
          created: PaperTiger.now(),
          email: "extended#{i}@example.com",
          id: "cus_extended_#{i}",
          object: "customer"
        })

        Subscriptions.insert(%{
          created: past - 2_592_000,
          current_period_end: past,
          current_period_start: past - 2_592_000,
          customer: "cus_extended_#{i}",
          id: "sub_extended_#{i}",
          items: %{
            data: [%{price: "price_extended"}]
          },
          object: "subscription",
          plan: %{interval: "month", interval_count: 1},
          status: "active"
        })
      end

      # Set chaos mode with extended decline codes
      :ok =
        BillingEngine.set_mode(:chaos,
          payment_failure_rate: 1.0,
          decline_codes: [:fraudulent, :incorrect_cvc, :authentication_required]
        )

      {:ok, stats} = BillingEngine.process_billing()

      assert stats.processed == 5
      assert stats.failed == 5

      # Verify that charges have the extended codes
      %{data: charges} = Charges.list(%{limit: 10})
      assert length(charges) == 5

      failure_codes =
        charges
        |> Enum.map(& &1.failure_code)
        |> Enum.uniq()

      # Should only see the extended codes we configured
      assert Enum.all?(failure_codes, fn code ->
               code in ["fraudulent", "incorrect_cvc", "authentication_required"]
             end)

      # Verify we see at least 2 different decline codes (with 5 samples and 3 codes, high probability)
      assert length(failure_codes) >= 2
    end

    test "weighted decline codes produce expected distribution" do
      PaperTiger.flush()

      # Create test product and price
      Products.insert(%{
        active: true,
        created: PaperTiger.now(),
        id: "prod_weighted",
        name: "Weighted Test Product",
        object: "product"
      })

      Prices.insert(%{
        active: true,
        created: PaperTiger.now(),
        currency: "usd",
        id: "price_weighted",
        object: "price",
        product: "prod_weighted",
        recurring: %{interval: "month", interval_count: 1},
        unit_amount: 2000
      })

      start_supervised!({BillingEngine, []})

      now = PaperTiger.now()
      past = now - 86_400

      # Create 50 subscriptions for better statistical significance
      for i <- 1..50 do
        Customers.insert(%{
          created: PaperTiger.now(),
          email: "weighted#{i}@example.com",
          id: "cus_weighted_#{i}",
          object: "customer"
        })

        Subscriptions.insert(%{
          created: past - 2_592_000,
          current_period_end: past,
          current_period_start: past - 2_592_000,
          customer: "cus_weighted_#{i}",
          id: "sub_weighted_#{i}",
          items: %{
            data: [%{price: "price_weighted"}]
          },
          object: "subscription",
          plan: %{interval: "month", interval_count: 1},
          status: "active"
        })
      end

      # Set weighted distribution: 70% card_declined, 20% insufficient_funds, 10% expired_card
      :ok =
        BillingEngine.set_mode(:chaos,
          payment_failure_rate: 1.0,
          decline_codes: [:card_declined, :insufficient_funds, :expired_card],
          decline_code_weights: %{
            card_declined: 0.7,
            expired_card: 0.1,
            insufficient_funds: 0.2
          }
        )

      {:ok, stats} = BillingEngine.process_billing()

      assert stats.processed == 50
      assert stats.failed == 50

      # Count occurrences of each code (need to request all 50 charges)
      %{data: charges} = Charges.list(%{limit: 100})
      assert length(charges) == 50

      code_counts = Enum.frequencies_by(charges, & &1.failure_code)

      # With 50 samples, we expect roughly:
      # - card_declined: ~35 (70%)
      # - insufficient_funds: ~10 (20%)
      # - expired_card: ~5 (10%)
      # Allow wider variance for smaller sample size
      card_declined_count = Map.get(code_counts, "card_declined", 0)
      insufficient_funds_count = Map.get(code_counts, "insufficient_funds", 0)
      expired_card_count = Map.get(code_counts, "expired_card", 0)

      # Verify card_declined is clearly the most common
      assert card_declined_count > insufficient_funds_count
      assert card_declined_count > expired_card_count

      # Verify card_declined is roughly 70% (between 50% and 90% to account for randomness)
      assert card_declined_count >= 25 and card_declined_count <= 45

      # All charges should use one of our configured codes
      assert Enum.all?(charges, fn charge ->
               charge.failure_code in ["card_declined", "insufficient_funds", "expired_card"]
             end)
    end
  end
end
