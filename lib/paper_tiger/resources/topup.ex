defmodule PaperTiger.Resources.Topup do
  @moduledoc """
  Handles Topup resource endpoints.

  ## Endpoints

  - POST   /v1/topups      - Create topup
  - GET    /v1/topups/:id  - Retrieve topup
  - POST   /v1/topups/:id  - Update topup
  - GET    /v1/topups      - List topups

  Note: Topups cannot be deleted (only canceled).

  ## Topup Object

      %{
        id: "tu_...",
        object: "topup",
        created: 1234567890,
        amount: 2000,
        currency: "usd",
        status: "pending" | "succeeded" | "failed" | "canceled" | "reversed",
        description: "Account top-up",
        metadata: %{},
        # ... other fields
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Topups


  @doc """
  Creates a new topup.

  ## Required Parameters

  - amount - Amount in cents (e.g., 2000 for $20.00)
  - currency - Three-letter ISO currency code (e.g., "usd")
  - description - Topup description

  ## Optional Parameters

  - metadata - Key-value metadata
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:amount, :currency, :description]),
         topup = build_topup(conn.params),
         {:ok, topup} <- Topups.insert(topup) do
      maybe_store_idempotency(conn, topup)

      topup
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
  Retrieves a topup by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case Topups.get(id) do
      {:ok, topup} ->
        topup
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("topup", id))
    end
  end

  @doc """
  Updates a topup.

  Note: Topups can only have limited fields updated.

  ## Updatable Fields

  - description
  - metadata
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- Topups.get(id),
         updated =
           merge_updates(existing, conn.params, [
             :id,
             :object,
             :created,
             :amount,
             :currency,
             :status
           ]),
         {:ok, updated} <- Topups.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("topup", id))
    end
  end

  @doc """
  Lists all topups with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  - status - Filter by status
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result = Topups.list(pagination_opts)

    json_response(conn, 200, result)
  end

  ## Private Functions

  defp build_topup(params) do
    %{
      id: generate_id("tu"),
      object: "topup",
      created: PaperTiger.now(),
      amount: get_integer(params, :amount),
      currency: Map.get(params, :currency),
      status: Map.get(params, :status, "pending"),
      description: Map.get(params, :description),
      metadata: Map.get(params, :metadata, %{}),
      # Additional fields
      livemode: false,
      source: Map.get(params, :source),
      statement_descriptor: Map.get(params, :statement_descriptor),
      transfer_group: Map.get(params, :transfer_group),
      expected_arrival_date: Map.get(params, :expected_arrival_date),
      failure_code: Map.get(params, :failure_code),
      failure_message: Map.get(params, :failure_message)
    }
  end

  defp maybe_expand(topup, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(topup, expand_params)
  end
end
