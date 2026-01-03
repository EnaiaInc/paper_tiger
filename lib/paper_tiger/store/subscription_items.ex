defmodule PaperTiger.Store.SubscriptionItems do
  @moduledoc """
  ETS-backed storage for SubscriptionItem resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_subscription_items` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, subscription_item} = PaperTiger.Store.SubscriptionItems.get("si_123")

      # Serialized write
      subscription_item = %{id: "si_123", subscription: "sub_123", ...}
      {:ok, subscription_item} = PaperTiger.Store.SubscriptionItems.insert(subscription_item)

      # Query helpers (direct ETS access)
      subscription_items = PaperTiger.Store.SubscriptionItems.find_by_subscription("sub_123")
  """

  use PaperTiger.Store,
    table: :paper_tiger_subscription_items,
    resource: "subscription_item",
    prefix: "si"

  @doc """
  Finds subscription items by subscription ID.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_subscription(String.t()) :: [map()]
  def find_by_subscription(subscription_id) when is_binary(subscription_id) do
    :ets.tab2list(@table)
    |> Enum.filter(fn {_id, item} -> Map.get(item, :subscription) == subscription_id end)
    |> Enum.map(fn {_id, subscription_item} -> subscription_item end)
  end

  @doc """
  Deletes all subscription items for a given subscription.

  **Serialized write** - goes through GenServer.
  """
  @spec delete_by_subscription(String.t()) :: :ok
  def delete_by_subscription(subscription_id) when is_binary(subscription_id) do
    GenServer.call(__MODULE__, {:delete_by_subscription, subscription_id})
  end

  # Override handle_call to add custom delete_by_subscription handler
  @impl true
  def handle_call({:delete_by_subscription, subscription_id}, _from, state) do
    require Logger
    # Find all items for this subscription and delete them
    items = find_by_subscription(subscription_id)

    Enum.each(items, fn item ->
      :ets.delete(@table, item.id)
    end)

    Logger.debug("Deleted #{length(items)} items for subscription #{subscription_id}")
    {:reply, :ok, state}
  end

  # Delegate other handle_call patterns to the macro's implementation
  def handle_call(msg, from, state) do
    super(msg, from, state)
  end
end
