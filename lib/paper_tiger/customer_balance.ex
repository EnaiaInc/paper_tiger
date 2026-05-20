defmodule PaperTiger.CustomerBalance do
  @moduledoc false

  import PaperTiger.Resource, only: [generate_id: 1, to_integer: 1]

  alias PaperTiger.Store.CustomerBalanceTransactions
  alias PaperTiger.Store.Customers

  @doc """
  Creates a customer balance transaction and mutates the customer's balance.
  """
  @spec create_transaction(String.t(), map()) ::
          {:ok, map()} | {:error, :not_found}
  def create_transaction(customer_id, params) when is_binary(customer_id) and is_map(params) do
    with {:ok, customer} <- Customers.get(customer_id) do
      amount = params |> value(:amount) |> to_integer()
      currency = value(params, :currency) || Map.get(customer, :currency) || "usd"
      ending_balance = Map.get(customer, :balance, 0) + amount
      now = PaperTiger.now()

      transaction = %{
        amount: amount,
        created: now,
        credit_note: value(params, :credit_note),
        currency: currency,
        customer: customer.id,
        description: value(params, :description),
        ending_balance: ending_balance,
        id: generate_id("cbtxn"),
        invoice: value(params, :invoice),
        livemode: false,
        metadata: value(params, :metadata) || %{},
        object: "customer_balance_transaction",
        type: value(params, :type) || "adjustment"
      }

      updated_customer =
        customer
        |> Map.put(:balance, ending_balance)
        |> Map.put(:currency, currency)

      with {:ok, _customer} <- Customers.update(updated_customer) do
        CustomerBalanceTransactions.insert(transaction)
      end
    end
  end

  @doc """
  Applies an existing customer credit balance to an invoice.
  """
  @spec apply_to_invoice(map()) :: map()
  def apply_to_invoice(%{customer: customer_id} = invoice) when is_binary(customer_id) do
    case Customers.get(customer_id) do
      {:ok, customer} ->
        apply_customer_credit(invoice, customer)

      {:error, :not_found} ->
        invoice
    end
  end

  def apply_to_invoice(invoice), do: invoice

  @doc false
  @spec value(term(), atom()) :: term()
  def value(nil, _key), do: nil

  def value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  def value(_other, _key), do: nil

  defp apply_customer_credit(invoice, %{balance: balance} = customer) when is_integer(balance) and balance < 0 do
    amount_remaining = Map.get(invoice, :amount_remaining, Map.get(invoice, :amount_due, 0))
    applied_amount = min(amount_remaining, abs(balance))
    ending_balance = balance + applied_amount

    {:ok, _customer} =
      customer
      |> Map.put(:balance, ending_balance)
      |> Customers.update()

    invoice
    |> Map.put(:starting_balance, balance)
    |> Map.put(:ending_balance, ending_balance)
    |> Map.put(:amount_due, max(Map.get(invoice, :amount_due, 0) - applied_amount, 0))
    |> Map.put(:amount_remaining, max(amount_remaining - applied_amount, 0))
    |> maybe_mark_paid()
  end

  defp apply_customer_credit(invoice, %{balance: balance}) do
    invoice
    |> Map.put(:starting_balance, balance || 0)
    |> Map.put(:ending_balance, balance || 0)
  end

  defp maybe_mark_paid(%{amount_remaining: 0} = invoice) do
    invoice
    |> Map.put(:paid, true)
    |> Map.put(:status, "paid")
  end

  defp maybe_mark_paid(invoice), do: invoice
end
