defmodule PaperTiger.Contract.PaymentIntentChainTest do
  @moduledoc """
  Contract test: verifies PaymentIntent -> Charge -> BalanceTransaction chain
  works identically against PaperTiger and real Stripe.

  Run against PaperTiger (default):
      mix test test/paper_tiger/contract/payment_intent_chain_test.exs

  Run against real Stripe:
      VALIDATE_AGAINST_STRIPE=true STRIPE_API_KEY=sk_test_xxx mix test test/paper_tiger/contract/payment_intent_chain_test.exs
  """

  use ExUnit.Case, async: false

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
      pm_id = "pm_card_visa"

      pi_params = %{
        "amount" => 2500,
        "currency" => "usd",
        "payment_method" => pm_id,
        "payment_method_types" => ["card"]
      }

      {:ok, pi} = TestClient.create_payment_intent(pi_params)

      assert pi["status"] == "requires_confirmation"

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

  describe "PaymentIntent lifecycle endpoints" do
    test "cancel transitions a pre-confirmation intent to canceled" do
      {:ok, pi} =
        TestClient.create_payment_intent(%{
          "amount" => 1300,
          "currency" => "usd"
        })

      {:ok, canceled} =
        TestClient.cancel_payment_intent(pi["id"], %{
          "cancellation_reason" => "requested_by_customer"
        })

      assert canceled["id"] == pi["id"]
      assert canceled["status"] == "canceled"
      assert canceled["cancellation_reason"] == "requested_by_customer"
      assert canceled["amount_capturable"] == 0
      assert is_integer(canceled["canceled_at"])
    end

    test "manual capture supports final partial capture and captured charge state" do
      {:ok, pi} =
        TestClient.create_payment_intent(%{
          "amount" => 2500,
          "capture_method" => "manual",
          "currency" => "usd",
          "payment_method" => "pm_card_visa",
          "payment_method_types" => ["card"]
        })

      {:ok, authorized} =
        TestClient.confirm_payment_intent(pi["id"], %{
          "payment_method" => "pm_card_visa"
        })

      assert authorized["status"] == "requires_capture"
      assert authorized["amount_capturable"] == 2500
      assert authorized["amount_received"] == 0
      assert authorized["latest_charge"] != nil

      {:ok, captured} =
        TestClient.capture_payment_intent(pi["id"], %{
          "amount_to_capture" => 1800
        })

      assert captured["status"] == "succeeded"
      assert captured["amount_capturable"] == 0
      assert captured["amount_received"] == 1800

      {:ok, charge} = TestClient.get_charge(captured["latest_charge"])
      assert charge["captured"] == true
      assert charge["amount_captured"] == 1800
    end
  end
end
