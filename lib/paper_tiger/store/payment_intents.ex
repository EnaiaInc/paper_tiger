defmodule PaperTiger.Store.PaymentIntents do
  @moduledoc """
  ETS-backed storage for PaymentIntent resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_payment_intents` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, payment_intent} = PaperTiger.Store.PaymentIntents.get("pi_123")

      # Serialized write
      payment_intent = %{id: "pi_123", customer: "cus_123", ...}
      {:ok, payment_intent} = PaperTiger.Store.PaymentIntents.insert(payment_intent)

      # Query helpers (direct ETS access)
      payment_intents = PaperTiger.Store.PaymentIntents.find_by_customer("cus_123")
  """

  use PaperTiger.Store,
    table: :paper_tiger_payment_intents,
    resource: "payment_intent"

  @doc """
  Finds payment intents by customer ID.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_customer(String.t()) :: [map()]
  def find_by_customer(customer_id) when is_binary(customer_id) do
    :ets.match_object(@table, {:_, %{customer: customer_id}})
    |> Enum.map(fn {_id, payment_intent} -> payment_intent end)
  end

  @doc """
  Finds payment intents by status.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_status(String.t()) :: [map()]
  def find_by_status(status) when is_binary(status) do
    :ets.match_object(@table, {:_, %{status: status}})
    |> Enum.map(fn {_id, payment_intent} -> payment_intent end)
  end
end
