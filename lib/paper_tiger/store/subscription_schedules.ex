defmodule PaperTiger.Store.SubscriptionSchedules do
  @moduledoc """
  ETS-backed storage for SubscriptionSchedule resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_subscription_schedules` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, schedule} = PaperTiger.Store.SubscriptionSchedules.get("sub_sched_123")

      # Serialized write
      schedule = %{id: "sub_sched_123", customer: "cus_123", status: "not_started", ...}
      {:ok, schedule} = PaperTiger.Store.SubscriptionSchedules.insert(schedule)

      # Query helpers (direct ETS access)
      schedules = PaperTiger.Store.SubscriptionSchedules.find_by_customer("cus_123")
  """

  use PaperTiger.Store,
    table: :paper_tiger_subscription_schedules,
    resource: "subscription_schedule",
    prefix: "sub_sched"

  @doc """
  Finds subscription schedules by customer ID.

  **Direct ETS access** - does not go through GenServer.

  Returns all subscription schedules for the given customer, regardless of status.
  """
  @spec find_by_customer(String.t()) :: [map()]
  def find_by_customer(customer_id) when is_binary(customer_id) do
    :ets.match_object(@table, {:_, %{customer: customer_id}})
    |> Enum.map(fn {_id, schedule} -> schedule end)
  end

  @doc """
  Finds all active (not_started or active) subscription schedules.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_active() :: [map()]
  def find_active do
    all()
    |> Enum.filter(fn schedule -> schedule.status in ["not_started", "active"] end)
  end

  @doc """
  Finds subscription schedules that are scheduled (not yet started).

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_scheduled() :: [map()]
  def find_scheduled do
    :ets.match_object(@table, {:_, %{status: "not_started"}})
    |> Enum.map(fn {_id, schedule} -> schedule end)
  end

  defp all do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, schedule} -> schedule end)
  end
end
