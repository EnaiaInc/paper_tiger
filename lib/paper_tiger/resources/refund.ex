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
  alias PaperTiger.ListFilters
  alias PaperTiger.Store.Charges
  alias PaperTiger.Store.PaymentIntents
  alias PaperTiger.Store.Refunds

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
         {:ok, charge} <- fetch_refundable_charge(conn.params),
         {:ok, amount} <- resolve_refund_amount(conn.params, charge),
         refund = build_refund(conn.params, charge, amount),
         {:ok, refund} <- Refunds.insert(refund),
         {:ok, refund} <- create_balance_transaction(refund, charge),
         {:ok, _charge} <- apply_refund_to_charge(charge, refund) do
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

      {:error, :charge_not_found, charge_id} ->
        error_response(conn, PaperTiger.Error.not_found("charge", charge_id))

      {:error, :invalid_amount, message} ->
        error_response(conn, PaperTiger.Error.invalid_request(message, "amount"))
    end
  end

  # Creates a balance transaction for a refund
  # Get the original charge for fee calculation
  ## Private Functions

  defp create_balance_transaction(refund, charge) do
    {:ok, txn_id} = BalanceTransactionHelper.create_for_refund(refund, charge)
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

    with :ok <- validate_list_reference(:charge, conn.params),
         :ok <- validate_list_reference(:payment_intent, conn.params),
         {:ok, refunds} <-
           Refunds.list_namespace(PaperTiger.Connect.storage_namespace())
           |> ListFilters.apply(conn.params, [
             {:string, :charge},
             {:created, :created},
             {:string, :payment_intent},
             {:string, :status}
           ]) do
      result =
        refunds
        |> PaperTiger.List.paginate(Map.put(pagination_opts, :url, "/v1/refunds"))
        |> ListFilters.expand_page(conn.params)

      json_response(conn, 200, result)
    else
      {:error, error} ->
        error_response(conn, error)
    end
  end

  defp build_refund(params, charge, amount) do
    %{
      amount: amount,
      balance_transaction: nil,
      charge: charge.id,
      created: PaperTiger.now(),
      currency: Map.get(params, :currency, charge.currency),
      failure_code: nil,
      failure_reason: nil,
      id: generate_id("re"),
      livemode: false,
      metadata: Map.get(params, :metadata, %{}),
      object: "refund",
      payment_intent: Map.get(charge, :payment_intent),
      reason: Map.get(params, :reason),
      receipt_number: Map.get(params, :receipt_number),
      source_transfer_reversal: nil,
      status: Map.get(params, :status, "succeeded")
    }
  end

  defp fetch_refundable_charge(params) do
    charge_id = Map.get(params, :charge)

    case Charges.get(charge_id) do
      {:ok, charge} -> {:ok, charge}
      {:error, :not_found} -> {:error, :charge_not_found, charge_id}
    end
  end

  defp resolve_refund_amount(params, charge) do
    refundable = refundable_amount(charge)
    refunded = Map.get(charge, :amount_refunded, 0)
    remaining = refundable - refunded

    amount =
      case get_optional_integer(params, :amount) do
        nil -> remaining
        value -> value
      end

    cond do
      amount <= 0 ->
        {:error, :invalid_amount, "Amount must be greater than zero"}

      amount > remaining ->
        {:error, :invalid_amount, "Amount exceeds the unrefunded charge amount"}

      true ->
        {:ok, amount}
    end
  end

  defp apply_refund_to_charge(charge, refund) do
    amount_refunded = Map.get(charge, :amount_refunded, 0) + refund.amount

    updated =
      charge
      |> Map.put(:amount_refunded, amount_refunded)
      |> Map.put(:refunded, amount_refunded >= refundable_amount(charge))

    Charges.update(updated)
  end

  defp validate_list_reference(param, params) do
    case Map.get(params, param) do
      nil ->
        :ok

      id ->
        param
        |> store_for_list_reference()
        |> then(& &1.get(id))
        |> case do
          {:ok, _resource} -> :ok
          {:error, :not_found} -> {:error, PaperTiger.Error.not_found(resource_name(param), id)}
        end
    end
  end

  defp store_for_list_reference(:charge), do: Charges
  defp store_for_list_reference(:payment_intent), do: PaymentIntents

  defp resource_name(:charge), do: "charge"
  defp resource_name(:payment_intent), do: "payment_intent"

  defp refundable_amount(charge) do
    case Map.get(charge, :amount_captured) do
      amount when is_integer(amount) and amount > 0 -> amount
      _ -> Map.get(charge, :amount, 0)
    end
  end

  defp maybe_expand(refund, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(refund, expand_params)
  end
end
