defmodule PaperTiger.Resources.Transfer do
  @moduledoc """
  Handles Connect Transfer and Transfer Reversal endpoints.
  """

  import PaperTiger.Resource

  alias PaperTiger.BalanceTransactionHelper
  alias PaperTiger.Connect
  alias PaperTiger.Resources.ApplicationFeeRefund
  alias PaperTiger.Store.Accounts
  alias PaperTiger.Store.TransferReversals
  alias PaperTiger.Store.Transfers

  @doc """
  Creates a transfer to a connected account.
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:amount, :currency, :destination]),
         amount when amount > 0 <- get_integer(conn.params, :amount),
         :ok <- validate_destination(Map.get(conn.params, :destination)),
         transfer = build_transfer(conn.params),
         {:ok, transfer} <- insert_transfer_with_balance_transactions(transfer) do
      maybe_store_idempotency(conn, transfer)

      transfer
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :invalid_params, field} ->
        error_response(conn, PaperTiger.Error.invalid_request("Missing required parameter", field))

      amount when is_integer(amount) ->
        error_response(conn, PaperTiger.Error.invalid_request("Amount must be greater than zero", "amount"))

      {:error, :invalid_destination, destination} ->
        error_response(conn, PaperTiger.Error.not_found("account", destination))
    end
  end

  @doc """
  Retrieves a transfer.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case Transfers.get(id) do
      {:ok, transfer} ->
        transfer
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("transfer", id))
    end
  end

  @doc """
  Updates a transfer. Stripe only allows metadata updates; PaperTiger also keeps
  description mutable for common test setup ergonomics.
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- Transfers.get(id),
         updated =
           merge_updates(existing, conn.params, [
             :id,
             :object,
             :created,
             :amount,
             :currency,
             :destination,
             :destination_payment,
             :reversed,
             :amount_reversed
           ]),
         {:ok, updated} <- Transfers.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("transfer", id))
    end
  end

  @doc """
  Lists transfers with optional destination filtering.
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result =
      case Map.get(conn.params, :destination) do
        destination when is_binary(destination) and destination != "" ->
          destination
          |> Transfers.find_by_destination()
          |> PaperTiger.List.paginate(Map.put(pagination_opts, :url, "/v1/transfers"))

        _ ->
          Transfers.list(pagination_opts)
      end

    json_response(conn, 200, result)
  end

  @doc """
  Creates a reversal against a transfer.
  """
  @spec create_reversal(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def create_reversal(conn, transfer_id) do
    with {:ok, transfer} <- Transfers.get(transfer_id),
         {:ok, amount} <- parse_reversal_amount(conn.params, transfer),
         reversal = build_reversal(conn.params, transfer, amount),
         {:ok, reversal, transfer} <- insert_reversal_with_balance_transactions(reversal, transfer) do
      maybe_refund_application_fee(conn.params, transfer)
      maybe_store_idempotency(conn, reversal)

      reversal
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("transfer", transfer_id))

      {:error, :invalid_reversal_amount, message} ->
        error_response(conn, PaperTiger.Error.invalid_request(message, "amount"))
    end
  end

  @doc """
  Retrieves a transfer reversal.
  """
  @spec retrieve_reversal(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def retrieve_reversal(conn, transfer_id, id) do
    with {:ok, _transfer} <- Transfers.get(transfer_id),
         {:ok, reversal} <- TransferReversals.get(id),
         true <- reversal.transfer == transfer_id do
      reversal
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      false ->
        error_response(conn, PaperTiger.Error.not_found("transfer_reversal", id))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("transfer_reversal", id))
    end
  end

  @doc """
  Updates transfer reversal metadata.
  """
  @spec update_reversal(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def update_reversal(conn, transfer_id, id) do
    with {:ok, _transfer} <- Transfers.get(transfer_id),
         {:ok, reversal} <- TransferReversals.get(id),
         true <- reversal.transfer == transfer_id,
         updated = merge_updates(reversal, conn.params, [:id, :object, :created, :amount, :currency, :transfer]),
         {:ok, updated} <- TransferReversals.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      false ->
        error_response(conn, PaperTiger.Error.not_found("transfer_reversal", id))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("transfer_reversal", id))
    end
  end

  @doc """
  Lists reversals for a transfer.
  """
  @spec list_reversals(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def list_reversals(conn, transfer_id) do
    case Transfers.get(transfer_id) do
      {:ok, _transfer} ->
        pagination_opts = parse_pagination_params(conn.params)

        transfer_id
        |> TransferReversals.find_by_transfer()
        |> PaperTiger.List.paginate(Map.put(pagination_opts, :url, "/v1/transfers/#{transfer_id}/reversals"))
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("transfer", transfer_id))
    end
  end

  defp build_transfer(params) do
    %{
      amount: get_integer(params, :amount),
      amount_reversed: 0,
      application_fee: Map.get(params, :application_fee),
      balance_transaction: nil,
      created: PaperTiger.now(),
      currency: Map.get(params, :currency),
      description: Map.get(params, :description),
      destination: Map.get(params, :destination),
      destination_payment: generate_id("py"),
      id: generate_id("tr"),
      livemode: false,
      metadata: Map.get(params, :metadata, %{}),
      object: "transfer",
      reversals: nested_reversal_list("pending"),
      reversed: false,
      source_transaction: Map.get(params, :source_transaction),
      source_type: Map.get(params, :source_type, "card"),
      transfer_group: Map.get(params, :transfer_group)
    }
    |> then(fn transfer ->
      %{transfer | reversals: nested_reversal_list(transfer.id)}
    end)
  end

  defp build_reversal(params, transfer, amount) do
    %{
      amount: amount,
      balance_transaction: nil,
      created: PaperTiger.now(),
      currency: transfer.currency,
      destination_payment_refund: nil,
      id: generate_id("trr"),
      metadata: Map.get(params, :metadata, %{}),
      object: "transfer_reversal",
      source_refund: Map.get(params, :source_refund),
      transfer: transfer.id
    }
  end

  defp insert_transfer_with_balance_transactions(transfer) do
    {:ok, balance_transaction_id} = BalanceTransactionHelper.create_for_transfer(transfer)

    Connect.with_account(transfer.destination, fn ->
      {:ok, _destination_transaction_id} = BalanceTransactionHelper.create_for_destination_transfer(transfer)
    end)

    transfer = Map.put(transfer, :balance_transaction, balance_transaction_id)
    Transfers.insert(transfer)
  end

  defp insert_reversal_with_balance_transactions(reversal, transfer) do
    {:ok, balance_transaction_id} = BalanceTransactionHelper.create_for_transfer_reversal(reversal)

    Connect.with_account(transfer.destination, fn ->
      {:ok, _destination_transaction_id} =
        BalanceTransactionHelper.create_for_destination_transfer_reversal(reversal)
    end)

    reversal = Map.put(reversal, :balance_transaction, balance_transaction_id)
    {:ok, reversal} = TransferReversals.insert(reversal)

    amount_reversed = transfer.amount_reversed + reversal.amount
    reversed? = amount_reversed == transfer.amount

    updated_transfer =
      transfer
      |> Map.put(:amount_reversed, amount_reversed)
      |> Map.put(:reversed, reversed?)
      |> Map.put(:reversals, add_reversal_to_nested_list(transfer.reversals, reversal))

    {:ok, updated_transfer} = Transfers.update(updated_transfer)
    {:ok, reversal, updated_transfer}
  end

  defp parse_reversal_amount(params, transfer) do
    remaining = transfer.amount - transfer.amount_reversed
    amount = get_integer(params, :amount, remaining)

    cond do
      amount <= 0 ->
        {:error, :invalid_reversal_amount, "Amount must be greater than zero"}

      amount > remaining ->
        {:error, :invalid_reversal_amount, "Amount exceeds the unreversed transfer amount"}

      true ->
        {:ok, amount}
    end
  end

  defp validate_destination(destination) do
    Connect.without_account(fn ->
      case Accounts.get(destination) do
        {:ok, _account} -> :ok
        {:error, :not_found} -> {:error, :invalid_destination, destination}
      end
    end)
  end

  defp maybe_refund_application_fee(params, transfer) do
    if to_boolean(Map.get(params, :refund_application_fee)) and is_binary(Map.get(transfer, :application_fee)) do
      ApplicationFeeRefund.create_for_fee(transfer.application_fee, %{})
    else
      :ok
    end
  end

  defp nested_reversal_list(transfer_id) do
    %{
      data: [],
      has_more: false,
      object: "list",
      total_count: 0,
      url: "/v1/transfers/#{transfer_id}/reversals"
    }
  end

  defp add_reversal_to_nested_list(list, reversal) do
    data = [reversal | Map.get(list, :data, [])] |> Enum.take(10)

    list
    |> Map.put(:data, data)
    |> Map.put(:total_count, Map.get(list, :total_count, 0) + 1)
  end

  defp maybe_expand(transfer, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(transfer, expand_params)
  end
end
