defmodule PaperTiger.Store.Tokens do
  @moduledoc """
  ETS-backed storage for Token resources.

  Uses the shared store pattern via `use PaperTiger.Store` which provides:
  - GenServer wraps ETS table
  - Reads go directly to ETS (concurrent, fast)
  - Writes go through GenServer (serialized, safe)

  ## Architecture

  - **ETS Table**: `:paper_tiger_tokens` (public, read_concurrency: true)
  - **GenServer**: Serializes writes, handles initialization
  - **Shared Implementation**: All CRUD operations via PaperTiger.Store

  ## Examples

      # Direct read (no GenServer bottleneck)
      {:ok, token} = PaperTiger.Store.Tokens.get("tok_123")

      # Serialized write
      token = %{id: "tok_123", type: "card", ...}
      {:ok, token} = PaperTiger.Store.Tokens.insert(token)
  """

  use PaperTiger.Store,
    table: :paper_tiger_tokens,
    resource: "token"
end
