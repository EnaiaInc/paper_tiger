defmodule PaperTiger.Resources.BankAccount do
  @moduledoc """
  Handles BankAccount resource endpoints.

  ## Endpoints

  - POST   /v1/customers/:customer_id/bank_accounts      - Create bank account
  - GET    /v1/customers/:customer_id/bank_accounts/:id  - Retrieve bank account
  - POST   /v1/customers/:customer_id/bank_accounts/:id  - Update bank account
  - DELETE /v1/customers/:customer_id/bank_accounts/:id  - Delete bank account
  - GET    /v1/customers/:customer_id/bank_accounts      - List bank accounts

  ## BankAccount Object

      %{
        id: "ba_...",
        object: "bank_account",
        created: 1234567890,
        customer: "cus_...",
        account_holder_name: "John Doe",
        account_holder_type: "individual",
        bank_name: "Chase Bank",
        country: "US",
        currency: "usd",
        fingerprint: "abcdef1234567890",
        last4: "6789",
        routing_number: "110000000",
        status: "verified",
        metadata: %{},
        # ... other fields
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.BankAccounts


  @doc """
  Creates a new bank account.

  ## Required Parameters

  - customer - Customer ID this bank account belongs to
  - routing_number - Bank routing number
  - account_number - Bank account number

  ## Optional Parameters

  - account_holder_name - Name of account holder
  - account_holder_type - Type of account holder ("individual" or "company")
  - bank_name - Name of the bank
  - country - Country code (default: "US")
  - currency - Currency code (default: "usd")
  - metadata - Key-value metadata
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <-
           validate_params(conn.params, [:customer, :routing_number, :account_number]),
         bank_account = build_bank_account(conn.params),
         {:ok, bank_account} <- BankAccounts.insert(bank_account) do
      maybe_store_idempotency(conn, bank_account)

      bank_account
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
  Retrieves a bank account by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case BankAccounts.get(id) do
      {:ok, bank_account} ->
        bank_account
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("bank_account", id))
    end
  end

  @doc """
  Updates a bank account.

  ## Updatable Fields

  - account_holder_name
  - account_holder_type
  - metadata
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- BankAccounts.get(id),
         updated =
           merge_updates(existing, conn.params, [
             :id,
             :object,
             :created,
             :customer,
             :routing_number,
             :account_number,
             :bank_name,
             :country,
             :currency,
             :fingerprint,
             :last4,
             :status
           ]),
         {:ok, updated} <- BankAccounts.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("bank_account", id))
    end
  end

  @doc """
  Deletes a bank account.

  Returns a deletion confirmation object.
  """
  @spec delete(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def delete(conn, id) do
    case BankAccounts.get(id) do
      {:ok, _bank_account} ->
        :ok = BankAccounts.delete(id)

        json_response(conn, 200, %{
          deleted: true,
          id: id,
          object: "bank_account"
        })

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("bank_account", id))
    end
  end

  @doc """
  Lists all bank accounts for a customer with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result = BankAccounts.list(pagination_opts)

    json_response(conn, 200, result)
  end

  ## Private Functions

  defp build_bank_account(params) do
    account_number = Map.get(params, :account_number, "")
    last4_digits = String.slice(account_number, -4..-1)

    fingerprint =
      :crypto.hash(:sha256, "#{Map.get(params, :routing_number)}#{account_number}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    %{
      id: generate_id("ba"),
      object: "bank_account",
      created: PaperTiger.now(),
      customer: Map.get(params, :customer),
      account_holder_name: Map.get(params, :account_holder_name),
      account_holder_type: Map.get(params, :account_holder_type, "individual"),
      bank_name: Map.get(params, :bank_name),
      country: Map.get(params, :country, "US"),
      currency: Map.get(params, :currency, "usd"),
      fingerprint: fingerprint,
      last4: last4_digits,
      routing_number: Map.get(params, :routing_number),
      status: "new",
      metadata: Map.get(params, :metadata, %{}),
      # Additional fields
      livemode: false,
      account_number: Map.get(params, :account_number)
    }
  end

  defp maybe_expand(bank_account, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(bank_account, expand_params)
  end
end
