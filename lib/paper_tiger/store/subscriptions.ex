defmodule PaperTiger.Store.Subscriptions do
  @moduledoc """
  ETS-backed storage for Subscription resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_subscriptions` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, subscription} = PaperTiger.Store.Subscriptions.get("sub_123")

      # Serialized write
      subscription = %{id: "sub_123", customer: "cus_123", status: "active", ...}
      {:ok, subscription} = PaperTiger.Store.Subscriptions.insert(subscription)

      # Query helpers (direct ETS access)
      subscriptions = PaperTiger.Store.Subscriptions.find_by_customer("cus_123")
      active_subscriptions = PaperTiger.Store.Subscriptions.find_active()
  """

  use PaperTiger.Store,
    table: :paper_tiger_subscriptions,
    resource: "subscription",
    prefix: "sub"

  @doc """
  Finds subscriptions by customer ID.

  **Direct ETS access** - does not go through GenServer.

  Returns all subscriptions for the given customer, regardless of status.
  """
  @spec find_by_customer(String.t()) :: [map()]
  def find_by_customer(customer_id) when is_binary(customer_id) do
    :ets.match_object(@table, {:_, %{customer: customer_id}})
    |> Enum.map(fn {_id, subscription} -> subscription end)
  end

  @doc """
  Finds all active subscriptions.

  **Direct ETS access** - does not go through GenServer.

  Returns subscriptions with status "active".
  """
  @spec find_active() :: [map()]
  def find_active do
    :ets.match_object(@table, {:_, %{status: "active"}})
    |> Enum.map(fn {_id, subscription} -> subscription end)
  end
end
