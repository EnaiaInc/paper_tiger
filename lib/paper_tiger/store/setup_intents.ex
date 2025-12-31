defmodule PaperTiger.Store.SetupIntents do
  @moduledoc """
  ETS-backed storage for SetupIntent resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_setup_intents` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, setup_intent} = PaperTiger.Store.SetupIntents.get("seti_123")

      # Serialized write
      setup_intent = %{id: "seti_123", customer: "cus_123", ...}
      {:ok, setup_intent} = PaperTiger.Store.SetupIntents.insert(setup_intent)

      # Query helpers (direct ETS access)
      setup_intents = PaperTiger.Store.SetupIntents.find_by_customer("cus_123")
  """

  use PaperTiger.Store,
    table: :paper_tiger_setup_intents,
    resource: "setup_intent"

  @doc """
  Finds setup intents by customer ID.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_customer(String.t()) :: [map()]
  def find_by_customer(customer_id) when is_binary(customer_id) do
    :ets.match_object(@table, {:_, %{customer: customer_id}})
    |> Enum.map(fn {_id, setup_intent} -> setup_intent end)
  end
end
