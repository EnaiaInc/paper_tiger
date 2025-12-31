defmodule PaperTiger.Store.Charges do
  @moduledoc """
  ETS-backed storage for Charge resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_charges` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, charge} = PaperTiger.Store.Charges.get("ch_123")

      # Serialized write
      charge = %{id: "ch_123", customer: "cus_123", ...}
      {:ok, charge} = PaperTiger.Store.Charges.insert(charge)

      # Query helpers (direct ETS access)
      charges = PaperTiger.Store.Charges.find_by_customer("cus_123")
  """

  use PaperTiger.Store,
    table: :paper_tiger_charges,
    resource: "charge"

  @doc """
  Finds charges by customer ID.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_customer(String.t()) :: [map()]
  def find_by_customer(customer_id) when is_binary(customer_id) do
    :ets.match_object(@table, {:_, %{customer: customer_id}})
    |> Enum.map(fn {_id, charge} -> charge end)
  end

  @doc """
  Finds charges by payment intent ID.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_payment_intent(String.t()) :: [map()]
  def find_by_payment_intent(payment_intent_id) when is_binary(payment_intent_id) do
    :ets.match_object(@table, {:_, %{payment_intent: payment_intent_id}})
    |> Enum.map(fn {_id, charge} -> charge end)
  end
end
