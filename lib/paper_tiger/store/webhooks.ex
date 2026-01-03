defmodule PaperTiger.Store.Webhooks do
  @moduledoc """
  ETS-backed storage for Webhook Endpoint resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_webhooks` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, webhook} = PaperTiger.Store.Webhooks.get("we_123")

      # Serialized write
      webhook = %{id: "we_123", url: "https://example.com/webhook", ...}
      {:ok, webhook} = PaperTiger.Store.Webhooks.insert(webhook)

      # Query helpers (direct ETS access)
      webhooks = PaperTiger.Store.Webhooks.find_active()
  """

  use PaperTiger.Store,
    table: :paper_tiger_webhooks,
    resource: "webhook_endpoint",
    prefix: "we"

  @doc """
  Finds active webhook endpoints (status: "enabled").

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_active() :: [map()]
  def find_active do
    :ets.match_object(@table, {:_, %{status: "enabled"}})
    |> Enum.map(fn {_id, webhook} -> webhook end)
  end
end
