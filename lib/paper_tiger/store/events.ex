defmodule PaperTiger.Store.Events do
  @moduledoc """
  ETS-backed storage for Event resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_events` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, event} = PaperTiger.Store.Events.get("evt_123")

      # Serialized write
      event = %{id: "evt_123", type: "payment_intent.succeeded", ...}
      {:ok, event} = PaperTiger.Store.Events.insert(event)

      # Query helpers (direct ETS access)
      events = PaperTiger.Store.Events.find_by_type("payment_intent.succeeded")
  """

  use PaperTiger.Store,
    table: :paper_tiger_events,
    resource: "event",
    prefix: "evt"

  @doc """
  Finds events by type.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_type(String.t()) :: [map()]
  def find_by_type(type) when is_binary(type) do
    :ets.match_object(@table, {:_, %{type: type}})
    |> Enum.map(fn {_id, event} -> event end)
  end
end
