defmodule PaperTiger.Store.Invoices do
  @moduledoc """
  ETS-backed storage for Invoice resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_invoices` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, invoice} = PaperTiger.Store.Invoices.get("in_123")

      # Serialized write
      invoice = %{id: "in_123", customer: "cus_123", status: "paid", ...}
      {:ok, invoice} = PaperTiger.Store.Invoices.insert(invoice)

      # Query helpers (direct ETS access)
      invoices = PaperTiger.Store.Invoices.find_by_customer("cus_123")
      invoices = PaperTiger.Store.Invoices.find_by_status("paid")
  """

  use PaperTiger.Store,
    table: :paper_tiger_invoices,
    resource: "invoice",
    prefix: "in"

  @doc """
  Finds invoices by customer ID.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_customer(String.t()) :: [map()]
  def find_by_customer(customer_id) when is_binary(customer_id) do
    :ets.match_object(@table, {:_, %{customer: customer_id}})
    |> Enum.map(fn {_id, invoice} -> invoice end)
  end

  @doc """
  Finds invoices by subscription ID.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_subscription(String.t()) :: [map()]
  def find_by_subscription(subscription_id) when is_binary(subscription_id) do
    :ets.match_object(@table, {:_, %{subscription: subscription_id}})
    |> Enum.map(fn {_id, invoice} -> invoice end)
  end

  @doc """
  Finds invoices by status.

  **Direct ETS access** - does not go through GenServer.

  ## Examples

      # Find all paid invoices
      paid_invoices = PaperTiger.Store.Invoices.find_by_status("paid")

      # Find all open invoices
      open_invoices = PaperTiger.Store.Invoices.find_by_status("open")

      # Find all void invoices
      void_invoices = PaperTiger.Store.Invoices.find_by_status("void")
  """
  @spec find_by_status(String.t()) :: [map()]
  def find_by_status(status) when is_binary(status) do
    :ets.match_object(@table, {:_, %{status: status}})
    |> Enum.map(fn {_id, invoice} -> invoice end)
  end
end
