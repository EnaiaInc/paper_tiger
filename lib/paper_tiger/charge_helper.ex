defmodule PaperTiger.ChargeHelper do
  @moduledoc """
  Creates Charge objects from PaymentIntents.

  Handles the PI -> Charge -> BalanceTransaction chain that Stripe performs
  when a PaymentIntent succeeds. This is used by checkout session completion
  and the billing engine to produce the same object graph that real Stripe does.
  """

  import PaperTiger.Resource, only: [generate_id: 1]

  alias PaperTiger.BalanceTransactionHelper
  alias PaperTiger.Store.{Charges, PaymentIntents}

  @doc """
  Creates a Charge (and its BalanceTransaction) for a succeeded PaymentIntent.

  1. Builds a charge map from the PI fields
  2. Inserts into the Charges store
  3. Creates a BalanceTransaction via BalanceTransactionHelper
  4. Updates the charge with the balance_transaction ID
  5. Updates the PI with `latest_charge`
  6. Fires telemetry
  7. Returns `{:ok, charge}`
  """
  @spec create_for_payment_intent(map(), keyword()) :: {:ok, map()}
  def create_for_payment_intent(payment_intent, opts \\ []) do
    captured? = Keyword.get(opts, :captured, true)
    charge = build_charge(payment_intent, captured?)
    {:ok, charge} = Charges.insert(charge)

    {:ok, charge} =
      if captured? do
        create_balance_transaction(charge, Map.get(charge, :amount, 0))
      else
        {:ok, charge}
      end

    # Update the PI with latest_charge
    updated_pi = Map.put(payment_intent, :latest_charge, charge.id)
    PaymentIntents.update(updated_pi)

    :telemetry.execute([:paper_tiger, :charge, :succeeded], %{}, %{object: charge})

    {:ok, charge}
  end

  @doc """
  Captures an authorized PaymentIntent charge and links the resulting balance transaction.
  """
  @spec capture_payment_intent_charge(map(), integer(), boolean()) :: {:ok, map()} | {:error, :not_found}
  def capture_payment_intent_charge(payment_intent, amount_to_capture, final_capture?) do
    with {:ok, charge} <- get_or_create_payment_intent_charge(payment_intent) do
      amount_captured = Map.get(charge, :amount_captured, 0) + amount_to_capture

      charge =
        charge
        |> Map.put(:amount_captured, amount_captured)
        |> Map.put(:captured, final_capture?)
        |> Map.put(:status, "succeeded")

      create_balance_transaction(charge, amount_to_capture)
    end
  end

  defp get_or_create_payment_intent_charge(%{latest_charge: charge_id}) when is_binary(charge_id) do
    Charges.get(charge_id)
  end

  defp get_or_create_payment_intent_charge(payment_intent) do
    create_for_payment_intent(payment_intent, captured: false)
  end

  defp create_balance_transaction(charge, amount) do
    # The stored Charge keeps the authorization amount; the balance transaction
    # records the amount actually captured in this operation.
    {:ok, txn_id} = charge |> Map.put(:amount, amount) |> BalanceTransactionHelper.create_for_charge()

    charge
    |> Map.put(:balance_transaction, txn_id)
    |> Charges.update()
  end

  defp build_charge(pi, captured?) do
    amount = Map.get(pi, :amount, 0)

    %{
      amount: amount,
      amount_captured: if(captured?, do: amount, else: 0),
      amount_refunded: 0,
      balance_transaction: nil,
      billing_details: nil,
      captured: captured?,
      created: PaperTiger.now(),
      currency: Map.get(pi, :currency),
      customer: Map.get(pi, :customer),
      description: Map.get(pi, :description),
      failure_code: nil,
      failure_message: nil,
      fraud_details: nil,
      id: generate_id("ch"),
      invoice: Map.get(pi, :invoice),
      livemode: false,
      metadata: Map.get(pi, :metadata, %{}),
      object: "charge",
      outcome: %{
        network_status: "approved_by_network",
        reason: nil,
        risk_level: "normal",
        type: "authorized"
      },
      paid: true,
      payment_intent: Map.get(pi, :id),
      payment_method: Map.get(pi, :payment_method),
      receipt_email: Map.get(pi, :receipt_email),
      receipt_number: nil,
      receipt_url: nil,
      refunded: false,
      statement_descriptor: Map.get(pi, :statement_descriptor),
      status: "succeeded"
    }
  end
end
