defmodule PaperTiger.Store.Customers do
  @moduledoc """
  ETS-backed storage for Customer resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_customers` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, customer} = PaperTiger.Store.Customers.get("cus_123")

      # Serialized write
      customer = %{id: "cus_123", email: "test@example.com", ...}
      {:ok, customer} = PaperTiger.Store.Customers.insert(customer)

      # Custom query helpers
      customers = PaperTiger.Store.Customers.find_by_email("test@example.com")
  """

  use PaperTiger.Store,
    table: :paper_tiger_customers,
    resource: "customer",
    prefix: "cus"

  @doc """
  Finds customers by email address.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_email(String.t()) :: [map()]
  def find_by_email(email) when is_binary(email) do
    :ets.match_object(@table, {:_, %{email: email}})
    |> Enum.map(fn {_id, customer} -> customer end)
  end
end
