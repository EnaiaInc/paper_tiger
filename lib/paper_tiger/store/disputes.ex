defmodule PaperTiger.Store.Disputes do
  @moduledoc """
  ETS-backed storage for Dispute resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_disputes` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, dispute} = PaperTiger.Store.Disputes.get("dp_123")

      # Serialized write
      dispute = %{id: "dp_123", charge: "ch_123", status: "under_review", ...}
      {:ok, dispute} = PaperTiger.Store.Disputes.insert(dispute)

      # Query helpers (direct ETS access)
      disputes = PaperTiger.Store.Disputes.find_by_charge("ch_123")
      disputes = PaperTiger.Store.Disputes.find_by_status("under_review")
  """

  use PaperTiger.Store,
    table: :paper_tiger_disputes,
    resource: "dispute",
    prefix: "dp"

  @doc """
  Finds disputes by charge ID.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_charge(String.t()) :: [map()]
  def find_by_charge(charge_id) when is_binary(charge_id) do
    :ets.match_object(@table, {:_, %{charge: charge_id}})
    |> Enum.map(fn {_id, dispute} -> dispute end)
  end

  @doc """
  Finds disputes by status.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_status(String.t()) :: [map()]
  def find_by_status(status) when is_binary(status) do
    :ets.match_object(@table, {:_, %{status: status}})
    |> Enum.map(fn {_id, dispute} -> dispute end)
  end
end
