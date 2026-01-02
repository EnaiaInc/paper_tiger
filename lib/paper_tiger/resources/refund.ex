defmodule PaperTiger.Resources.Refund do
  @moduledoc """
  Handles Refund resource endpoints.

  ## Endpoints

  - POST   /v1/refunds      - Create refund
  - GET    /v1/refunds/:id  - Retrieve refund
  - POST   /v1/refunds/:id  - Update refund
  - GET    /v1/refunds      - List refunds

  Note: Refunds cannot be deleted (immutable resource).

  ## Refund Object

      %{
        id: "re_...",
        object: "refund",
        created: 1234567890,
        amount: 2000,  # in cents ($20.00)
        charge: "ch_...",
        currency: "usd",
        status: "succeeded",
        reason: "requested_by_customer",
        metadata: %{},
        # ... other fields
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.BalanceTransactionHelper
  alias PaperTiger.Store.Charges
  alias PaperTiger.Store.Refunds

  require Logger

  @doc """
  Creates a new refund.

  ## Required Parameters

  - charge - Charge ID to refund

  ## Optional Parameters

  - amount - Amount in cents to refund (if not provided, refunds full charge)
  - reason - Reason for refund: "duplicate", "fraudulent", "requested_by_customer"
  - metadata - Key-value metadata
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:charge]),
         refund = build_refund(conn.params),
         {:ok, refund} <- Refunds.insert(refund),
         {:ok, refund} <- create_balance_transaction(refund) do
      maybe_store_idempotency(conn, refund)

      refund
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

  # Creates a balance transaction for a refund
  defp create_balance_transaction(refund) do
    charge_id = refund[:charge] || refund["charge"]

    # Get the original charge for fee calculation
    original_charge =
      case Charges.get(charge_id) do
        {:ok, charge} -> charge
        _ -> %{amount: 0}
      end

    {:ok, txn_id} = BalanceTransactionHelper.create_for_refund(refund, original_charge)
    updated = Map.put(refund, :balance_transaction, txn_id)
    Refunds.update(updated)
  end

  @doc """
  Retrieves a refund by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case Refunds.get(id) do
      {:ok, refund} ->
        refund
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("refund", id))
    end
  end

  @doc """
  Updates a refund.

  Note: Refunds can only have limited fields updated.

  ## Updatable Fields

  - metadata
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- Refunds.get(id),
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
         {:ok, updated} <- Refunds.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("refund", id))
    end
  end

  @doc """
  Lists all refunds with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  - charge - Filter by charge ID
  - status - Filter by status (succeeded, pending, failed)
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result = Refunds.list(pagination_opts)

    json_response(conn, 200, result)
  end

  ## Private Functions

  defp build_refund(params) do
    %{
      id: generate_id("re"),
      object: "refund",
      created: PaperTiger.now(),
      amount: get_integer(params, :amount),
      charge: Map.get(params, :charge),
      currency: Map.get(params, :currency, "usd"),
      status: Map.get(params, :status, "succeeded"),
      reason: Map.get(params, :reason),
      metadata: Map.get(params, :metadata, %{}),
      # Additional fields
      livemode: false,
      receipt_number: Map.get(params, :receipt_number),
      balance_transaction: nil,
      failure_code: nil,
      failure_reason: nil
    }
  end

  defp maybe_expand(refund, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(refund, expand_params)
  end
end
