defmodule PaperTiger.Store.ApplicationFees do
  @moduledoc """
  ETS-backed storage for Application Fee resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_application_fees` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, fee} = PaperTiger.Store.ApplicationFees.get("fee_123")

      # Serialized write
      fee = %{id: "fee_123", charge: "ch_123", ...}
      {:ok, fee} = PaperTiger.Store.ApplicationFees.insert(fee)

      # Query helpers (direct ETS access)
      fees = PaperTiger.Store.ApplicationFees.find_by_charge("ch_123")
  """

  use PaperTiger.Store,
    table: :paper_tiger_application_fees,
    resource: "application_fee"

  @doc """
  Finds application fees by charge ID.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_charge(String.t()) :: [map()]
  def find_by_charge(charge_id) when is_binary(charge_id) do
    :ets.match_object(@table, {:_, %{charge: charge_id}})
    |> Enum.map(fn {_id, fee} -> fee end)
  end
end
