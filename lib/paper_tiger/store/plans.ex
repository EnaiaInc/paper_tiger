defmodule PaperTiger.Store.Plans do
  @moduledoc """
  ETS-backed storage for Plan resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_plans` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, plan} = PaperTiger.Store.Plans.get("plan_123")

      # Serialized write
      plan = %{id: "plan_123", product: "prod_123", ...}
      {:ok, plan} = PaperTiger.Store.Plans.insert(plan)

      # Query helpers (direct ETS access)
      plans = PaperTiger.Store.Plans.find_by_product("prod_123")
      active_plans = PaperTiger.Store.Plans.find_active()
  """

  use PaperTiger.Store,
    table: :paper_tiger_plans,
    resource: "plan"

  @doc """
  Finds plans by product ID.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_product(String.t()) :: [map()]
  def find_by_product(product_id) when is_binary(product_id) do
    :ets.match_object(@table, {:_, %{product: product_id}})
    |> Enum.map(fn {_id, plan} -> plan end)
  end

  @doc """
  Finds active plans.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_active() :: [map()]
  def find_active do
    :ets.match_object(@table, {:_, %{active: true}})
    |> Enum.map(fn {_id, plan} -> plan end)
  end
end
