defmodule PaperTiger.Contract.PaymentIntentChainTest do
  @moduledoc """
  Contract test: verifies PaymentIntent -> Charge -> BalanceTransaction chain
  works identically against PaperTiger and real Stripe.

  Run against PaperTiger (default):
      mix test test/paper_tiger/contract/payment_intent_chain_test.exs

  Run against real Stripe:
      VALIDATE_AGAINST_STRIPE=true STRIPE_API_KEY=sk_test_xxx mix test test/paper_tiger/contract/payment_intent_chain_test.exs
  """

  use ExUnit.Case, async: true

  import PaperTiger.Test

  alias PaperTiger.TestClient

  setup do
    if !TestClient.real_stripe?() do
      checkout_paper_tiger(%{})
    end

    :ok
  end

  describe "PaymentIntent confirm creates full chain" do
    test "confirm produces Charge with BalanceTransaction" do
      # Create customer
      {:ok, customer} = TestClient.create_customer(%{"email" => "chain-test@example.com"})

      # Create PI with payment method
      # Real Stripe: use pm_card_visa token (avoids raw card number restrictions)
      # PaperTiger: create a PM and attach it
      {pm_id, pi_params} =
        if TestClient.real_stripe?() do
          {"pm_card_visa",
           %{
             "amount" => 2500,
             "currency" => "usd",
             "customer" => customer["id"],
             "payment_method" => "pm_card_visa",
             "payment_method_types" => ["card"]
           }}
        else
          {:ok, pm} =
            TestClient.create_payment_method(%{
              "card" => TestClient.test_card_simple(),
              "type" => "card"
            })

          {:ok, _} =
            TestClient.attach_payment_method(pm["id"], %{"customer" => customer["id"]})

          {pm["id"],
           %{
             "amount" => 2500,
             "currency" => "usd",
             "customer" => customer["id"],
             "payment_method" => pm["id"]
           }}
        end

      {:ok, pi} = TestClient.create_payment_intent(pi_params)

      assert pi["status"] in ["requires_confirmation", "requires_payment_method"]

      # Confirm PI
      {:ok, confirmed} =
        TestClient.confirm_payment_intent(pi["id"], %{"payment_method" => pm_id})

      assert confirmed["status"] == "succeeded"
      assert confirmed["latest_charge"] != nil

      # Retrieve charge
      {:ok, charge} = TestClient.get_charge(confirmed["latest_charge"])
      assert charge["amount"] == 2500
      assert charge["currency"] == "usd"
      assert charge["status"] == "succeeded"
      assert charge["payment_intent"] == pi["id"]
      assert charge["balance_transaction"] != nil

      # Retrieve balance transaction
      {:ok, bt} = TestClient.get_balance_transaction(charge["balance_transaction"])
      assert bt["amount"] == 2500
      assert bt["type"] == "charge"
      assert bt["source"] == charge["id"]
    end
  end
end
