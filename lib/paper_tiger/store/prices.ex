defmodule PaperTiger.Store.Prices do
  @moduledoc """
  ETS-backed storage for Price resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_prices` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, price} = PaperTiger.Store.Prices.get("price_123")

      # Serialized write
      price = %{id: "price_123", product: "prod_123", active: true, ...}
      {:ok, price} = PaperTiger.Store.Prices.insert(price)

      # Query helpers (direct ETS access)
      prices = PaperTiger.Store.Prices.find_by_product("prod_123")
      active_prices = PaperTiger.Store.Prices.find_active()
  """

  use PaperTiger.Store,
    table: :paper_tiger_prices,
    resource: "price",
    prefix: "price"

  @doc """
  Finds prices by product ID.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_product(String.t()) :: [map()]
  def find_by_product(product_id) when is_binary(product_id) do
    :ets.match_object(@table, {:_, %{product: product_id}})
    |> Enum.map(fn {_id, price} -> price end)
  end

  @doc """
  Finds all active prices.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_active() :: [map()]
  def find_active do
    :ets.match_object(@table, {:_, %{active: true}})
    |> Enum.map(fn {_id, price} -> price end)
  end
end
