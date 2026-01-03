defmodule PaperTiger.Store.TaxRates do
  @moduledoc """
  ETS-backed storage for TaxRate resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_tax_rates` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, tax_rate} = PaperTiger.Store.TaxRates.get("txr_123")

      # Serialized write
      tax_rate = %{id: "txr_123", percentage: 8.5, ...}
      {:ok, tax_rate} = PaperTiger.Store.TaxRates.insert(tax_rate)

      # Query helpers (direct ETS access)
      active_rates = PaperTiger.Store.TaxRates.find_active()
  """

  use PaperTiger.Store,
    table: :paper_tiger_tax_rates,
    resource: "tax_rate",
    prefix: "txr"

  @doc """
  Finds active tax rates.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_active() :: [map()]
  def find_active do
    :ets.match_object(@table, {:_, %{active: true}})
    |> Enum.map(fn {_id, tax_rate} -> tax_rate end)
  end
end
