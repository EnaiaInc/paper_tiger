defmodule PaperTiger.Store.Coupons do
  @moduledoc """
  ETS-backed storage for Coupon resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_coupons` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, coupon} = PaperTiger.Store.Coupons.get("coupon_123")

      # Serialized write
      coupon = %{id: "coupon_123", percent_off: 25, ...}
      {:ok, coupon} = PaperTiger.Store.Coupons.insert(coupon)

      # Query helpers (direct ETS access)
      active_coupons = PaperTiger.Store.Coupons.find_active()
  """

  use PaperTiger.Store,
    table: :paper_tiger_coupons,
    resource: "coupon",
    prefix: "coupon"

  @doc """
  Finds active coupons.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_active() :: [map()]
  def find_active do
    :ets.match_object(@table, {:_, %{valid: true}})
    |> Enum.map(fn {_id, coupon} -> coupon end)
  end
end
