defmodule PaperTiger.Store.Payouts do
  @moduledoc """
  ETS-backed storage for Payout resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_payouts` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, payout} = PaperTiger.Store.Payouts.get("po_123")

      # Serialized write
      payout = %{id: "po_123", status: "pending", ...}
      {:ok, payout} = PaperTiger.Store.Payouts.insert(payout)

      # Query helpers (direct ETS access)
      payouts = PaperTiger.Store.Payouts.find_by_status("paid")
  """

  use PaperTiger.Store,
    table: :paper_tiger_payouts,
    resource: "payout",
    prefix: "po"

  @doc """
  Finds payouts by status.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_status(String.t()) :: [map()]
  def find_by_status(status) when is_binary(status) do
    :ets.match_object(@table, {:_, %{status: status}})
    |> Enum.map(fn {_id, payout} -> payout end)
  end
end
