defmodule PaperTiger.ChargeHelperTest do
  use ExUnit.Case, async: true

  import PaperTiger.Test

  alias PaperTiger.ChargeHelper
  alias PaperTiger.Store.{BalanceTransactions, Charges, PaymentIntents}

  setup :checkout_paper_tiger

  defp build_payment_intent(overrides \\ %{}) do
    Map.merge(
      %{
        amount: 2000,
        amount_details: nil,
        application: nil,
        application_fee_amount: nil,
        cancellation_reason: nil,
        capture_method: "automatic",
        client_secret: "pi_secret_test",
        confirmation_method: "automatic",
        created: PaperTiger.now(),
        currency: "usd",
        customer: "cus_test123",
        description: nil,
        id: PaperTiger.Resource.generate_id("pi"),
        invoice: nil,
        last_payment_error: nil,
        latest_charge: nil,
        livemode: false,
        mandate: nil,
        metadata: %{},
        next_action: nil,
        object: "payment_intent",
        off_session: nil,
        on_behalf_of: nil,
        payment_method: "pm_test456",
        processing: nil,
        receipt_email: nil,
        review: nil,
        setup_future_usage: nil,
        shipping: nil,
        source: nil,
        statement_descriptor: nil,
        status: "succeeded"
      },
      overrides
    )
  end

  describe "create_for_payment_intent/1" do
    test "creates charge and balance transaction for succeeded PI" do
      pi = build_payment_intent()
      {:ok, pi} = PaymentIntents.insert(pi)

      {:ok, charge} = ChargeHelper.create_for_payment_intent(pi)

      # Charge has correct fields from PI
      assert String.starts_with?(charge.id, "ch_")
      assert charge.object == "charge"
      assert charge.amount == 2000
      assert charge.currency == "usd"
      assert charge.customer == "cus_test123"
      assert charge.payment_method == "pm_test456"
      assert charge.status == "succeeded"
      assert charge.paid == true
      assert charge.captured == true
      assert charge.refunded == false
      assert charge.amount_refunded == 0
      assert charge.livemode == false
      assert charge.metadata == %{}
      assert is_integer(charge.created)

      # Balance transaction was created and linked
      assert charge.balance_transaction != nil
      assert String.starts_with?(charge.balance_transaction, "txn_")

      {:ok, txn} = BalanceTransactions.get(charge.balance_transaction)
      assert txn.amount == 2000
      assert txn.source == charge.id
      assert txn.type == "charge"

      # Charge is persisted in the store
      {:ok, stored_charge} = Charges.get(charge.id)
      assert stored_charge.id == charge.id
      assert stored_charge.balance_transaction == charge.balance_transaction
    end

    test "updates PaymentIntent with latest_charge" do
      pi = build_payment_intent()
      {:ok, pi} = PaymentIntents.insert(pi)

      {:ok, charge} = ChargeHelper.create_for_payment_intent(pi)

      {:ok, updated_pi} = PaymentIntents.get(pi.id)
      assert updated_pi.latest_charge == charge.id
    end

    test "charge inherits invoice field from PI when present" do
      pi = build_payment_intent(%{invoice: "in_test789"})
      {:ok, pi} = PaymentIntents.insert(pi)

      {:ok, charge} = ChargeHelper.create_for_payment_intent(pi)

      assert charge.invoice == "in_test789"
    end
  end
end
