defmodule PaperTiger.Resources.ApplicationFeeRefund do
  @moduledoc """
  Handles Application Fee Refund endpoints nested under Application Fees.
  """

  import PaperTiger.Resource

  alias PaperTiger.BalanceTransactionHelper
  alias PaperTiger.Connect
  alias PaperTiger.Store.ApplicationFeeRefunds
  alias PaperTiger.Store.ApplicationFees

  @doc """
  Creates an application fee refund.
  """
  @spec create(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def create(conn, fee_id) do
    case create_for_fee(fee_id, conn.params) do
      {:ok, refund} ->
        maybe_store_idempotency(conn, refund)

        refund
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :fee_not_found} ->
        error_response(conn, PaperTiger.Error.not_found("application_fee", fee_id))

      {:error, :invalid_amount, message} ->
        error_response(conn, PaperTiger.Error.invalid_request(message, "amount"))
    end
  end

  @doc """
  Creates an application fee refund from internal code.
  """
  @spec create_for_fee(String.t(), map()) ::
          {:ok, map()} | {:error, :fee_not_found} | {:error, :invalid_amount, String.t()}
  def create_for_fee(fee_id, params) do
    Connect.without_account(fn ->
      with {:ok, fee} <- ApplicationFees.get(fee_id),
           {:ok, amount} <- parse_refund_amount(params, fee),
           refund = build_refund(params, fee, amount),
           {:ok, refund} <- insert_refund_with_balance_transaction(refund),
           {:ok, _fee} <- update_fee_for_refund(fee, refund) do
        {:ok, refund}
      else
        {:error, :not_found} -> {:error, :fee_not_found}
        {:error, :invalid_amount, message} -> {:error, :invalid_amount, message}
      end
    end)
  end

  @doc """
  Retrieves an application fee refund.
  """
  @spec retrieve(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, fee_id, id) do
    Connect.without_account(fn ->
      with {:ok, _fee} <- ApplicationFees.get(fee_id),
           {:ok, refund} <- ApplicationFeeRefunds.get(id),
           true <- refund.fee == fee_id do
        refund
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))
      else
        false ->
          error_response(conn, PaperTiger.Error.not_found("fee_refund", id))

        {:error, :not_found} ->
          error_response(conn, PaperTiger.Error.not_found("fee_refund", id))
      end
    end)
  end

  @doc """
  Updates application fee refund metadata.
  """
  @spec update(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def update(conn, fee_id, id) do
    Connect.without_account(fn ->
      with {:ok, _fee} <- ApplicationFees.get(fee_id),
           {:ok, refund} <- ApplicationFeeRefunds.get(id),
           true <- refund.fee == fee_id,
           updated = merge_updates(refund, conn.params, [:id, :object, :created, :amount, :currency, :fee]),
           {:ok, updated} <- ApplicationFeeRefunds.update(updated) do
        updated
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))
      else
        false ->
          error_response(conn, PaperTiger.Error.not_found("fee_refund", id))

        {:error, :not_found} ->
          error_response(conn, PaperTiger.Error.not_found("fee_refund", id))
      end
    end)
  end

  @doc """
  Lists refunds for an application fee.
  """
  @spec list(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def list(conn, fee_id) do
    Connect.without_account(fn ->
      case ApplicationFees.get(fee_id) do
        {:ok, _fee} ->
          pagination_opts = parse_pagination_params(conn.params)

          fee_id
          |> ApplicationFeeRefunds.find_by_fee()
          |> PaperTiger.List.paginate(Map.put(pagination_opts, :url, "/v1/application_fees/#{fee_id}/refunds"))
          |> then(&json_response(conn, 200, &1))

        {:error, :not_found} ->
          error_response(conn, PaperTiger.Error.not_found("application_fee", fee_id))
      end
    end)
  end

  defp parse_refund_amount(params, fee) do
    remaining = fee.amount - fee.amount_refunded
    amount = get_integer(params, :amount, remaining)

    cond do
      amount <= 0 ->
        {:error, :invalid_amount, "Amount must be greater than zero"}

      amount > remaining ->
        {:error, :invalid_amount, "Amount exceeds the unrefunded application fee amount"}

      true ->
        {:ok, amount}
    end
  end

  defp build_refund(params, fee, amount) do
    %{
      amount: amount,
      balance_transaction: nil,
      created: PaperTiger.now(),
      currency: fee.currency,
      fee: fee.id,
      id: generate_id("fr"),
      metadata: Map.get(params, :metadata, %{}),
      object: "fee_refund"
    }
  end

  defp insert_refund_with_balance_transaction(refund) do
    {:ok, balance_transaction_id} = BalanceTransactionHelper.create_for_application_fee_refund(refund)
    refund = Map.put(refund, :balance_transaction, balance_transaction_id)
    ApplicationFeeRefunds.insert(refund)
  end

  defp update_fee_for_refund(fee, refund) do
    amount_refunded = fee.amount_refunded + refund.amount
    refunded? = amount_refunded == fee.amount

    fee
    |> Map.put(:amount_refunded, amount_refunded)
    |> Map.put(:refunded, refunded?)
    |> Map.put(:refunds, add_refund_to_nested_list(fee.refunds, refund))
    |> ApplicationFees.update()
  end

  defp add_refund_to_nested_list(list, refund) do
    data = [refund | Map.get(list, :data, [])] |> Enum.take(10)

    list
    |> Map.put(:data, data)
    |> Map.put(:total_count, Map.get(list, :total_count, 0) + 1)
  end

  defp maybe_expand(refund, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(refund, expand_params)
  end
end
