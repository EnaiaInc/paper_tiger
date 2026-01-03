defmodule PaperTiger.Store.Cards do
  @moduledoc """
  ETS-backed storage for Card resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_cards` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, card} = PaperTiger.Store.Cards.get("card_123")

      # Serialized write
      card = %{id: "card_123", customer: "cus_123", ...}
      {:ok, card} = PaperTiger.Store.Cards.insert(card)

      # Query helpers (direct ETS access)
      cards = PaperTiger.Store.Cards.find_by_customer("cus_123")
  """

  use PaperTiger.Store,
    table: :paper_tiger_cards,
    resource: "card",
    prefix: "card"

  @doc """
  Finds cards by customer ID.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_customer(String.t()) :: [map()]
  def find_by_customer(customer_id) when is_binary(customer_id) do
    :ets.match_object(@table, {:_, %{customer: customer_id}})
    |> Enum.map(fn {_id, card} -> card end)
  end
end
