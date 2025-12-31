defmodule PaperTiger.Resources.BalanceTransaction do
  @moduledoc """
  Handles BalanceTransaction resource endpoints.

  ## Endpoints

  - GET    /v1/balance_transactions/:id  - Retrieve balance transaction
  - GET    /v1/balance_transactions      - List balance transactions

  Note: Balance transactions are auto-generated and immutable for audit trail integrity.

  ## Balance Transaction Object

      %{
        id: "txn_...",
        object: "balance_transaction",
        created: 1234567890,
        amount: 1000,
        currency: "usd",
        net: 980,
        fee: 20,
        type: "charge",
        status: "available",
        source: "ch_...",
        description: "Transaction description"
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.BalanceTransactions

  require Logger

  @doc """
  Retrieves a balance transaction by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case BalanceTransactions.get(id) do
      {:ok, balance_transaction} ->
        balance_transaction
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("balance_transaction", id))
    end
  end

  @doc """
  Lists all balance transactions with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  - type - Filter by transaction type (charge, refund, payout, payment, etc.)
  - source - Filter by source ID
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result = BalanceTransactions.list(pagination_opts)

    json_response(conn, 200, result)
  end

  ## Private Functions

  defp maybe_expand(balance_transaction, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(balance_transaction, expand_params)
  end
end
