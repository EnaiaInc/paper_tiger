defmodule PaperTiger.Resources.Dispute do
  @moduledoc """
  Handles Dispute resource endpoints.

  ## Endpoints

  - GET    /v1/disputes/:id  - Retrieve dispute
  - POST   /v1/disputes/:id  - Update dispute
  - GET    /v1/disputes      - List disputes

  Note: Disputes cannot be created or deleted (created by card networks, immutable).

  ## Dispute Object

      %{
        id: "dp_...",
        object: "dispute",
        created: 1234567890,
        amount: 2000,  # $20.00 in cents
        charge: "ch_...",
        currency: "usd",
        status: "warning_needs_response" | "warning_under_review" | "warning_closed" |
                "needs_response" | "under_review" | "charge_refunded" | "won" | "lost",
        reason: "duplicate" | "fraudulent" | "subscription_canceled" |
                "product_unacceptable" | "product_not_received" | "unrecognized" |
                "credit_not_processed" | "general",
        evidence: %{},
        metadata: %{},
        # ... other fields
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Disputes

  require Logger

  @doc """
  Retrieves a dispute by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case Disputes.get(id) do
      {:ok, dispute} ->
        dispute
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("dispute", id))
    end
  end

  @doc """
  Updates a dispute.

  Note: Disputes can only have limited fields updated.

  ## Updatable Fields

  - evidence
  - metadata
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- Disputes.get(id),
         updated =
           merge_updates(existing, conn.params, [
             :id,
             :object,
             :created,
             :amount,
             :charge,
             :currency,
             :status,
             :reason
           ]),
         {:ok, updated} <- Disputes.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("dispute", id))
    end
  end

  @doc """
  Lists all disputes with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  - charge - Filter by charge ID
  - status - Filter by dispute status
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result = Disputes.list(pagination_opts)

    json_response(conn, 200, result)
  end

  ## Private Functions

  defp maybe_expand(dispute, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(dispute, expand_params)
  end
end
