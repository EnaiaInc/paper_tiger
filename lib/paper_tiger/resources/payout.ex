defmodule PaperTiger.Resources.Payout do
  @moduledoc """
  Handles Payout resource endpoints.

  ## Endpoints

  - POST   /v1/payouts      - Create payout
  - GET    /v1/payouts/:id  - Retrieve payout
  - POST   /v1/payouts/:id  - Update payout
  - GET    /v1/payouts      - List payouts

  Note: Payouts cannot be deleted (can only be canceled).

  ## Payout Object

      %{
        id: "po_...",
        object: "payout",
        created: 1234567890,
        amount: 2000,  # cents
        currency: "usd",
        status: "paid",
        arrival_date: 1234567890,
        method: "standard",
        type: "bank_account",
        destination: "ba_...",
        metadata: %{},
        # ... other fields
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Payouts

  @doc """
  Creates a new payout.

  ## Required Parameters

  - amount - Payout amount in cents
  - currency - Three-letter ISO currency code (e.g., "usd")

  ## Optional Parameters

  - status - Payout status (default: "pending")
  - arrival_date - When the payout arrives
  - method - Payout method: "standard" or "instant" (default: "standard")
  - type - Destination type: "bank_account" or "card"
  - destination - Bank account or card ID
  - metadata - Key-value metadata
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:amount, :currency]),
         payout = build_payout(conn.params),
         {:ok, payout} <- Payouts.insert(payout) do
      maybe_store_idempotency(conn, payout)

      payout
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :invalid_params, field} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("Missing required parameter", field)
        )
    end
  end

  @doc """
  Retrieves a payout by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case Payouts.get(id) do
      {:ok, payout} ->
        payout
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("payout", id))
    end
  end

  @doc """
  Updates a payout.

  Note: Only metadata can be updated after creation.

  ## Updatable Fields

  - metadata
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- Payouts.get(id),
         updated =
           merge_updates(existing, conn.params, [
             :id,
             :object,
             :created,
             :amount,
             :currency,
             :status,
             :arrival_date,
             :method,
             :type,
             :destination
           ]),
         {:ok, updated} <- Payouts.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("payout", id))
    end
  end

  @doc """
  Lists all payouts with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  - status - Filter by status (paid, pending, in_transit, canceled, failed)
  - created - Filter by creation date
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result = Payouts.list(pagination_opts)

    json_response(conn, 200, result)
  end

  ## Private Functions

  # Additional fields
  defp build_payout(params) do
    %{
      amount: get_integer(params, :amount),
      arrival_date: Map.get(params, :arrival_date),
      automatic: Map.get(params, :automatic, false),
      balance_transaction: Map.get(params, :balance_transaction),
      connected_account: Map.get(params, :connected_account),
      created: PaperTiger.now(),
      currency: Map.get(params, :currency),
      description: Map.get(params, :description),
      destination: Map.get(params, :destination),
      failure_balance_transaction: Map.get(params, :failure_balance_transaction),
      failure_code: Map.get(params, :failure_code),
      failure_message: Map.get(params, :failure_message),
      id: generate_id("po"),
      livemode: false,
      metadata: Map.get(params, :metadata, %{}),
      method: Map.get(params, :method, "standard"),
      object: "payout",
      original_payout: Map.get(params, :original_payout),
      reversed_by: Map.get(params, :reversed_by),
      source_type: Map.get(params, :source_type, "card"),
      statement_descriptor: Map.get(params, :statement_descriptor),
      status: Map.get(params, :status, "pending"),
      type: Map.get(params, :type)
    }
  end

  defp maybe_expand(payout, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(payout, expand_params)
  end
end
