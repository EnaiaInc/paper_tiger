defmodule PaperTiger.Store.Topups do
  @moduledoc """
  ETS-backed storage for Top-up resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_topups` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, topup} = PaperTiger.Store.Topups.get("tu_123")

      # Serialized write
      topup = %{id: "tu_123", status: "pending", ...}
      {:ok, topup} = PaperTiger.Store.Topups.insert(topup)

      # Query helpers (direct ETS access)
      topups = PaperTiger.Store.Topups.find_by_status("succeeded")
  """

  use PaperTiger.Store,
    table: :paper_tiger_topups,
    resource: "topup",
    prefix: "tu"

  @doc """
  Finds top-ups by status.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_status(String.t()) :: [map()]
  def find_by_status(status) when is_binary(status) do
    :ets.match_object(@table, {:_, %{status: status}})
    |> Enum.map(fn {_id, topup} -> topup end)
  end
end
