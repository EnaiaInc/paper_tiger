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
  Finds payment methods by customer ID.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_customer(String.t()) :: [map()]
  def find_by_customer(customer_id) when is_binary(customer_id) do
    :ets.match_object(@table, {:_, %{customer: customer_id}})
    |> Enum.map(fn {_id, payment_method} -> payment_method end)
  end
end
