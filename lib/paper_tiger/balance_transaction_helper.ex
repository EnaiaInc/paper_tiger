defmodule PaperTiger.BalanceTransactionHelper do
  @moduledoc """
  Helper functions for creating balance transactions.

  Balance transactions are created automatically when:
  - A charge is created (type: "charge")
  - A refund is created (type: "refund")
  - A payout is created (type: "payout")

  ## Fee Calculation

  Stripe's standard fee is 2.9% + $0.30 per successful card charge.
  For simplicity, PaperTiger uses this formula for all charges.
  """

  alias PaperTiger.Store.BalanceTransactions

  @stripe_percentage 0.029
  @stripe_fixed_fee 30

  @doc """
  Creates a balance transaction for a charge.

  Returns the balance transaction ID.
  """
  @spec create_for_charge(map()) :: {:ok, String.t()} | {:error, term()}
  def create_for_charge(charge) do
    amount = get_field(charge, :amount, 0)
    currency = get_field(charge, :currency, "usd")
    fee = calculate_fee(amount)

    balance_transaction = %{
      amount: amount,
      available_on: PaperTiger.now() + 172_800,
      created: PaperTiger.now(),
      currency: currency,
      description: get_field(charge, :description, "Charge"),
      fee: fee,
      fee_details: [build_fee_detail(fee, currency)],
      id: PaperTiger.Resource.generate_id("txn"),
      net: amount - fee,
      object: "balance_transaction",
      reporting_category: "charge",
      source: get_field(charge, :id, nil),
      status: "pending",
      type: "charge"
    }

    insert_and_return_id(balance_transaction)
  end

  @doc """
  Creates a balance transaction for a refund.

  Refunds have negative amounts and return fees proportionally.
  """
  @spec create_for_refund(map(), map()) :: {:ok, String.t()} | {:error, term()}
  def create_for_refund(refund, original_charge) do
    refund_amount = get_field(refund, :amount, 0)
    original_amount = get_field(original_charge, :amount, 0)
    currency = get_field(refund, :currency, "usd")
    fee_refund = calculate_proportional_fee_refund(original_amount, refund_amount)

    balance_transaction = %{
      amount: -refund_amount,
      available_on: PaperTiger.now(),
      created: PaperTiger.now(),
      currency: currency,
      description: "Refund",
      fee: -fee_refund,
      fee_details: [build_fee_detail(-fee_refund, currency)],
      id: PaperTiger.Resource.generate_id("txn"),
      net: -refund_amount + fee_refund,
      object: "balance_transaction",
      reporting_category: "refund",
      source: get_field(refund, :id, nil),
      status: "available",
      type: "refund"
    }

    insert_and_return_id(balance_transaction)
  end

  @doc """
  Creates the platform-side balance transaction for a transfer.
  """
  @spec create_for_transfer(map()) :: {:ok, String.t()} | {:error, term()}
  def create_for_transfer(transfer) do
    amount = get_field(transfer, :amount, 0)
    currency = get_field(transfer, :currency, "usd")

    balance_transaction = %{
      amount: -amount,
      available_on: PaperTiger.now(),
      created: PaperTiger.now(),
      currency: currency,
      description: get_field(transfer, :description, "Transfer"),
      fee: 0,
      fee_details: [],
      id: PaperTiger.Resource.generate_id("txn"),
      net: -amount,
      object: "balance_transaction",
      reporting_category: "transfer",
      source: get_field(transfer, :id, nil),
      status: "available",
      type: "transfer"
    }

    PaperTiger.Connect.without_account(fn ->
      insert_and_return_id(balance_transaction)
    end)
  end

  @doc """
  Creates a connected-account balance transaction for funds received by transfer.
  """
  @spec create_for_destination_transfer(map()) :: {:ok, String.t()} | {:error, term()}
  def create_for_destination_transfer(transfer) do
    amount = get_field(transfer, :amount, 0)
    currency = get_field(transfer, :currency, "usd")

    balance_transaction = %{
      amount: amount,
      available_on: PaperTiger.now(),
      created: PaperTiger.now(),
      currency: currency,
      description: get_field(transfer, :description, "Transfer"),
      fee: 0,
      fee_details: [],
      id: PaperTiger.Resource.generate_id("txn"),
      net: amount,
      object: "balance_transaction",
      reporting_category: "transfer",
      source: get_field(transfer, :id, nil),
      status: "available",
      type: "transfer"
    }

    insert_and_return_id(balance_transaction)
  end

  @doc """
  Creates the platform-side balance transaction for a transfer reversal.
  """
  @spec create_for_transfer_reversal(map()) :: {:ok, String.t()} | {:error, term()}
  def create_for_transfer_reversal(reversal) do
    amount = get_field(reversal, :amount, 0)
    currency = get_field(reversal, :currency, "usd")

    balance_transaction = %{
      amount: amount,
      available_on: PaperTiger.now(),
      created: PaperTiger.now(),
      currency: currency,
      description: "Transfer reversal",
      fee: 0,
      fee_details: [],
      id: PaperTiger.Resource.generate_id("txn"),
      net: amount,
      object: "balance_transaction",
      reporting_category: "transfer_reversal",
      source: get_field(reversal, :id, nil),
      status: "available",
      type: "transfer_reversal"
    }

    PaperTiger.Connect.without_account(fn ->
      insert_and_return_id(balance_transaction)
    end)
  end

  @doc """
  Creates the connected-account balance transaction for a transfer reversal.
  """
  @spec create_for_destination_transfer_reversal(map()) :: {:ok, String.t()} | {:error, term()}
  def create_for_destination_transfer_reversal(reversal) do
    amount = get_field(reversal, :amount, 0)
    currency = get_field(reversal, :currency, "usd")

    balance_transaction = %{
      amount: -amount,
      available_on: PaperTiger.now(),
      created: PaperTiger.now(),
      currency: currency,
      description: "Transfer reversal",
      fee: 0,
      fee_details: [],
      id: PaperTiger.Resource.generate_id("txn"),
      net: -amount,
      object: "balance_transaction",
      reporting_category: "transfer_reversal",
      source: get_field(reversal, :id, nil),
      status: "available",
      type: "transfer_reversal"
    }

    insert_and_return_id(balance_transaction)
  end

  @doc """
  Creates a platform-side balance transaction for an application fee.
  """
  @spec create_for_application_fee(map()) :: {:ok, String.t()} | {:error, term()}
  def create_for_application_fee(application_fee) do
    amount = get_field(application_fee, :amount, 0)
    currency = get_field(application_fee, :currency, "usd")

    balance_transaction = %{
      amount: amount,
      available_on: PaperTiger.now(),
      created: PaperTiger.now(),
      currency: currency,
      description: "Application fee",
      fee: 0,
      fee_details: [],
      id: PaperTiger.Resource.generate_id("txn"),
      net: amount,
      object: "balance_transaction",
      reporting_category: "application_fee",
      source: get_field(application_fee, :id, nil),
      status: "available",
      type: "application_fee"
    }

    PaperTiger.Connect.without_account(fn ->
      insert_and_return_id(balance_transaction)
    end)
  end

  @doc """
  Creates a platform-side balance transaction for an application fee refund.
  """
  @spec create_for_application_fee_refund(map()) :: {:ok, String.t()} | {:error, term()}
  def create_for_application_fee_refund(refund) do
    amount = get_field(refund, :amount, 0)
    currency = get_field(refund, :currency, "usd")

    balance_transaction = %{
      amount: -amount,
      available_on: PaperTiger.now(),
      created: PaperTiger.now(),
      currency: currency,
      description: "Application fee refund",
      fee: 0,
      fee_details: [],
      id: PaperTiger.Resource.generate_id("txn"),
      net: -amount,
      object: "balance_transaction",
      reporting_category: "application_fee_refund",
      source: get_field(refund, :id, nil),
      status: "available",
      type: "application_fee_refund"
    }

    PaperTiger.Connect.without_account(fn ->
      insert_and_return_id(balance_transaction)
    end)
  end

  @doc """
  Calculates Stripe's processing fee for a given amount.

  Formula: 2.9% + $0.30 (in cents)
  """
  @spec calculate_fee(integer()) :: integer()
  def calculate_fee(amount) when is_integer(amount) and amount > 0 do
    round(amount * @stripe_percentage) + @stripe_fixed_fee
  end

  def calculate_fee(_), do: 0

  # Helper to get field from map with atom or string key
  defp get_field(map, key, default) do
    Map.get(map, key) || Map.get(map, to_string(key)) || default
  end

  defp build_fee_detail(amount, currency) do
    %{
      amount: amount,
      application: nil,
      currency: currency,
      description: "Stripe processing fees",
      type: "stripe_fee"
    }
  end

  defp calculate_proportional_fee_refund(original_amount, refund_amount) when original_amount > 0 do
    original_fee = calculate_fee(original_amount)
    div(original_fee * refund_amount, original_amount)
  end

  defp calculate_proportional_fee_refund(_, _), do: 0

  defp insert_and_return_id(balance_transaction) do
    {:ok, txn} = BalanceTransactions.insert(balance_transaction)
    {:ok, txn.id}
  end
end
