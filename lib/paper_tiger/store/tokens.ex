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
    resource: "token",
    prefix: "tok"

  @doc """
  Retrieves a token by ID.

  Overrides the default `get/1` to also check the global namespace
  for pre-defined test tokens (tok_visa, tok_mastercard, etc.).

  This allows tests running in isolated namespaces to use the standard
  Stripe test tokens without explicitly creating them.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    namespace = PaperTiger.Test.current_namespace()
    key = {namespace, id}

    case :ets.lookup(@table, key) do
      [{^key, item}] ->
        {:ok, item}

      [] ->
        # Fall back to global namespace for pre-defined test tokens
        get_from_global_namespace(namespace, id)
    end
  end

  defp get_from_global_namespace(:global, _id), do: {:error, :not_found}

  defp get_from_global_namespace(_namespace, id) do
    global_key = {:global, id}

    case :ets.lookup(@table, global_key) do
      [{^global_key, item}] -> {:ok, item}
      [] -> {:error, :not_found}
    end
  end
end
