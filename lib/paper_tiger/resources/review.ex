defmodule PaperTiger.Resources.Review do
  @moduledoc """
  Handles Review resource endpoints.

  ## Endpoints

  - GET    /v1/reviews/:id  - Retrieve review
  - POST   /v1/reviews/:id  - Update review
  - GET    /v1/reviews      - List reviews

  Note: Reviews cannot be created or deleted (created by Stripe Radar, immutable).

  ## Review Object

      %{
        id: "prv_...",
        object: "review",
        created: 1234567890,
        charge: "ch_...",
        payment_intent: "pi_...",
        reason: "rule" | "manual" | "approved" | "refunded",
        open: true,
        closed_reason: "approved" | "refunded" | "refunded_as_fraud" | "disputed",
        metadata: %{},
        # ... other fields
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Reviews


  @doc """
  Retrieves a review by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case Reviews.get(id) do
      {:ok, review} ->
        review
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("review", id))
    end
  end

  @doc """
  Updates a review.

  Note: Reviews can only have limited fields updated.

  ## Updatable Fields

  - closed_reason (only when closing a review)
  - metadata
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- Reviews.get(id),
         updated =
           merge_updates(existing, conn.params, [
             :id,
             :object,
             :created,
             :charge,
             :payment_intent,
             :reason,
             :open
           ]),
         {:ok, updated} <- Reviews.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("review", id))
    end
  end

  @doc """
  Lists all reviews with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  - charge - Filter by charge ID
  - payment_intent - Filter by payment intent ID
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result = Reviews.list(pagination_opts)

    json_response(conn, 200, result)
  end

  ## Private Functions

  defp maybe_expand(review, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(review, expand_params)
  end
end
