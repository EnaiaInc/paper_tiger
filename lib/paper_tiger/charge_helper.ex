defmodule PaperTiger.ChargeHelper do
  @moduledoc """
  Creates Charge objects from PaymentIntents.

  Handles the PI -> Charge -> BalanceTransaction chain that Stripe performs
  when a PaymentIntent succeeds. This is used by checkout session completion
  and the billing engine to produce the same object graph that real Stripe does.
  """

  import PaperTiger.Resource, only: [generate_id: 1]

  alias PaperTiger.BalanceTransactionHelper
  alias PaperTiger.Store.{ApplicationFees, Charges, PaymentIntents}

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
        charge
        |> create_balance_transaction(Map.get(charge, :amount, 0))
        |> maybe_create_application_fee()
      else
        {:ok, charge}
      end

    # Update the PI with latest_charge
    # The stored Charge keeps the authorization amount; the balance transaction
    # records the amount actually captured in this operation.
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

      charge
      |> create_balance_transaction(amount_to_capture)
      |> maybe_create_application_fee()
    end
  end

  defp get_or_create_payment_intent_charge(%{latest_charge: charge_id}) when is_binary(charge_id) do
    Charges.get(charge_id)
  end

  defp get_or_create_payment_intent_charge(payment_intent) do
    create_for_payment_intent(payment_intent, captured: false)
  end

  defp create_balance_transaction(charge, amount) do
    {:ok, txn_id} = charge |> Map.put(:amount, amount) |> BalanceTransactionHelper.create_for_charge()

    charge
    |> Map.put(:balance_transaction, txn_id)
    |> Charges.update()
  end

  defp maybe_create_application_fee({:ok, charge}) do
    amount = Map.get(charge, :application_fee_amount)

    cond do
      not is_integer(amount) or amount <= 0 ->
        {:ok, charge}

      is_binary(Map.get(charge, :application_fee)) ->
        {:ok, charge}

      true ->
        create_application_fee(charge, amount)
    end
  end

  defp create_application_fee(charge, amount) do
    fee = build_application_fee(charge, amount)

    {:ok, balance_transaction_id} = BalanceTransactionHelper.create_for_application_fee(fee)
    fee = Map.put(fee, :balance_transaction, balance_transaction_id)

    {:ok, _fee} =
      PaperTiger.Connect.without_account(fn ->
        ApplicationFees.insert(fee)
      end)

    charge
    |> Map.put(:application_fee, fee.id)
    |> Charges.update()
  end

  defp build_charge(pi, captured?) do
    amount = Map.get(pi, :amount, 0)

    %{
      amount: amount,
      amount_captured: if(captured?, do: amount, else: 0),
      amount_refunded: 0,
      application_fee: nil,
      application_fee_amount: Map.get(pi, :application_fee_amount),
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
      on_behalf_of: Map.get(pi, :on_behalf_of),
      outcome: %{network_status: "approved_by_network", reason: nil, risk_level: "normal", type: "authorized"},
      paid: true,
      payment_intent: Map.get(pi, :id),
      payment_method: Map.get(pi, :payment_method),
      receipt_email: Map.get(pi, :receipt_email),
      receipt_number: nil,
      receipt_url: nil,
      refunded: false,
      statement_descriptor: Map.get(pi, :statement_descriptor),
      status: "succeeded",
      transfer_data: Map.get(pi, :transfer_data)
    }
  end

  defp build_application_fee(charge, amount) do
    %{
      account: connected_account_for_fee(charge),
      amount: amount,
      amount_refunded: 0,
      application: nil,
      balance_transaction: nil,
      charge: charge.id,
      created: PaperTiger.now(),
      currency: Map.get(charge, :currency),
      id: generate_id("fee"),
      livemode: false,
      metadata: %{},
      object: "application_fee",
      originating_transaction: nil,
      refunded: false,
      refunds: %{
        data: [],
        has_more: false,
        object: "list",
        total_count: 0,
        url: "/v1/application_fees/pending/refunds"
      }
    }
    |> then(fn fee ->
      put_in(fee, [:refunds, :url], "/v1/application_fees/#{fee.id}/refunds")
    end)
  end

  defp connected_account_for_fee(charge) do
    case Map.get(charge, :transfer_data) do
      %{destination: destination} when is_binary(destination) -> destination
      %{"destination" => destination} when is_binary(destination) -> destination
      _ -> Map.get(charge, :on_behalf_of) || PaperTiger.Connect.current_account()
    end
  end
end
