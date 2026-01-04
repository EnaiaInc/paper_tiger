defmodule PaperTiger.Store.PaymentMethods do
  @moduledoc """
  ETS-backed storage for PaymentMethod resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_payment_methods` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, payment_method} = PaperTiger.Store.PaymentMethods.get("pm_123")

      # Serialized write
      payment_method = %{id: "pm_123", customer: "cus_123", ...}
      {:ok, payment_method} = PaperTiger.Store.PaymentMethods.insert(payment_method)

      # Query helpers (direct ETS access)
      payment_methods = PaperTiger.Store.PaymentMethods.find_by_customer("cus_123")
  """

  use PaperTiger.Store,
    table: :paper_tiger_payment_methods,
    resource: "payment_method",
    prefix: "pm"

  @doc """
  Retrieves a payment method by ID.

  Overrides the default `get/1` to also check the global namespace
  for pre-defined test tokens (pm_card_visa, pm_card_mastercard, etc.).

  This allows tests running in isolated namespaces to use the standard
  Stripe test tokens without explicitly creating them.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    namespace = PaperTiger.Test.current_namespace()
    key = {namespace, id}

    case :ets.lookup(@table, key) do
      [{^key, item}] ->
        {:ok, item}

      [] ->
        # Fall back to global namespace for pre-defined test tokens
        get_from_global_namespace(namespace, id)
    end
  end

  defp get_from_global_namespace(:global, _id), do: {:error, :not_found}

  defp get_from_global_namespace(_namespace, id) do
    global_key = {:global, id}

    case :ets.lookup(@table, global_key) do
      [{^global_key, item}] -> {:ok, item}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Finds payment methods by customer ID.

  **Direct ETS access** - does not go through GenServer.
  Returns empty list if customer_id is nil (Stripe requires customer param).
  """
  @spec find_by_customer(String.t() | nil) :: [map()]
  def find_by_customer(nil), do: []

  def find_by_customer(customer_id) when is_binary(customer_id) do
    namespace = PaperTiger.Test.current_namespace()

    :ets.match_object(@table, {{namespace, :_}, %{customer: customer_id}})
    |> Enum.map(fn {_key, payment_method} -> payment_method end)
  end
end
