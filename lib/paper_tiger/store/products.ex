defmodule PaperTiger.Store.Products do
  @moduledoc """
  ETS-backed storage for Product resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_products` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, product} = PaperTiger.Store.Products.get("prod_123")

      # Serialized write
      product = %{id: "prod_123", name: "Premium Plan", ...}
      {:ok, product} = PaperTiger.Store.Products.insert(product)

      # Query helpers (direct ETS access)
      products = PaperTiger.Store.Products.find_active()
  """

  use PaperTiger.Store,
    table: :paper_tiger_products,
    resource: "product",
    prefix: "prod"

  @doc """
  Finds all active products.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_active() :: [map()]
  def find_active do
    :ets.match_object(@table, {:_, %{active: true}})
    |> Enum.map(fn {_id, product} -> product end)
  end
end
