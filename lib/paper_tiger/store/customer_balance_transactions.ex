defmodule PaperTiger.Store.CustomerBalanceTransactions do
  @moduledoc false

  use PaperTiger.Store,
    table: :paper_tiger_customer_balance_transactions,
    resource: "customer_balance_transaction",
    prefix: "cbtxn",
    plural: "customer_balance_transactions",
    url_path: "/v1/customer_balance_transactions"

  @doc """
  Lists customer balance transactions for a customer.
  """
  @spec find_by_customer(String.t()) :: [map()]
  def find_by_customer(customer_id) when is_binary(customer_id) do
    namespace = PaperTiger.Connect.storage_namespace()

    @table
    |> :ets.match_object({{namespace, :_}, :_})
    |> Enum.map(fn {_key, transaction} -> transaction end)
    |> Enum.filter(fn transaction -> Map.get(transaction, :customer) == customer_id end)
    |> Enum.sort_by(&Map.get(&1, :created), :desc)
  end
end
