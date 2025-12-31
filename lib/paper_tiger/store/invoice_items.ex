defmodule PaperTiger.Store.InvoiceItems do
  @moduledoc """
  ETS-backed storage for InvoiceItem resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_invoice_items` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, invoice_item} = PaperTiger.Store.InvoiceItems.get("ii_123")

      # Serialized write
      invoice_item = %{id: "ii_123", invoice: "in_123", customer: "cus_123", ...}
      {:ok, invoice_item} = PaperTiger.Store.InvoiceItems.insert(invoice_item)

      # Query helpers (direct ETS access)
      invoice_items = PaperTiger.Store.InvoiceItems.find_by_invoice("in_123")
  """

  use PaperTiger.Store,
    table: :paper_tiger_invoice_items,
    resource: "invoice_item"

  @doc """
  Finds invoice items by invoice ID.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_invoice(String.t()) :: [map()]
  def find_by_invoice(invoice_id) when is_binary(invoice_id) do
    :ets.match_object(@table, {:_, %{invoice: invoice_id}})
    |> Enum.map(fn {_id, invoice_item} -> invoice_item end)
  end

  @doc """
  Finds invoice items by customer ID.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_customer(String.t()) :: [map()]
  def find_by_customer(customer_id) when is_binary(customer_id) do
    :ets.match_object(@table, {:_, %{customer: customer_id}})
    |> Enum.map(fn {_id, invoice_item} -> invoice_item end)
  end
end
