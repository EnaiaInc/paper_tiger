defmodule PaperTiger.Store.Reviews do
  @moduledoc """
  ETS-backed storage for Review resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_reviews` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, review} = PaperTiger.Store.Reviews.get("prv_123")

      # Serialized write
      review = %{id: "prv_123", payment_intent: "pi_123", ...}
      {:ok, review} = PaperTiger.Store.Reviews.insert(review)

      # Query helpers (direct ETS access)
      reviews = PaperTiger.Store.Reviews.find_by_payment_intent("pi_123")
  """

  use PaperTiger.Store,
    table: :paper_tiger_reviews,
    resource: "review"

  @doc """
  Finds reviews by payment intent ID.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_payment_intent(String.t()) :: [map()]
  def find_by_payment_intent(payment_intent_id) when is_binary(payment_intent_id) do
    :ets.match_object(@table, {:_, %{payment_intent: payment_intent_id}})
    |> Enum.map(fn {_id, review} -> review end)
  end
end
