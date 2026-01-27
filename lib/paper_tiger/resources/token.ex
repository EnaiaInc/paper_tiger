defmodule PaperTiger.Resources.Token do
  @moduledoc """
  Handles Token resource endpoints.

  ## Endpoints

  - POST   /v1/tokens      - Create token
  - GET    /v1/tokens/:id  - Retrieve token

  Note: Tokens are immutable and single-use. No update, delete, or list operations.

  ## Token Object

      %{
        id: "tok_...",
        object: "token",
        created: 1234567890,
        type: "card" | "bank_account",
        used: false,
        card: %{
          id: "card_...",
          brand: "Visa",
          last4: "4242",
          exp_month: 12,
          exp_year: 2025
        },
        bank_account: %{
          id: "ba_...",
          account_holder_name: "John Doe",
          account_holder_type: "individual",
          last4: "6789",
          routing_number: "110000000"
        }
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Tokens


  @doc """
  Creates a new token.

  ## Required Parameters

  One of:
  - card - Card object with: number, exp_month, exp_year, cvc
  - bank_account - Bank account object with: account_number, routing_number, account_holder_name

  ## Optional Parameters

  - metadata - Key-value metadata
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_token_params(conn.params),
         token = build_token(conn.params),
         {:ok, token} <- Tokens.insert(token) do
      maybe_store_idempotency(conn, token)

      token
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :invalid_params} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("Either card or bank_account is required")
        )
    end
  end

  @doc """
  Retrieves a token by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case Tokens.get(id) do
      {:ok, token} ->
        token
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("token", id))
    end
  end

  ## Private Functions

  defp validate_token_params(params) do
    has_card = Map.has_key?(params, :card) and not is_nil(Map.get(params, :card))

    has_bank_account =
      Map.has_key?(params, :bank_account) and not is_nil(Map.get(params, :bank_account))

    if has_card or has_bank_account do
      {:ok, params}
    else
      {:error, :invalid_params}
    end
  end

  defp build_token(params) do
    card = Map.get(params, :card)
    bank_account = Map.get(params, :bank_account)

    {type, processed_card, processed_bank_account} =
      if card do
        {:card, process_card(card), nil}
      else
        {:bank_account, nil, process_bank_account(bank_account)}
      end

    %{
      id: generate_id("tok"),
      object: "token",
      created: PaperTiger.now(),
      type: type,
      used: false,
      card: processed_card,
      bank_account: processed_bank_account,
      metadata: Map.get(params, :metadata, %{}),
      # Additional fields
      livemode: false
    }
  end

  defp process_card(card_params) do
    %{
      brand: Map.get(card_params, :brand, infer_brand(Map.get(card_params, :number, ""))),
      country: Map.get(card_params, :country),
      cvc_check: Map.get(card_params, :cvc_check, "pass"),
      exp_month: Map.get(card_params, :exp_month),
      exp_year: Map.get(card_params, :exp_year),
      fingerprint: generate_fingerprint(),
      funding: "credit",
      id: generate_id("card"),
      last4: String.slice(Map.get(card_params, :number, ""), -4..-1),
      object: "card"
    }
  end

  defp process_bank_account(bank_params) do
    %{
      account_holder_name: Map.get(bank_params, :account_holder_name),
      account_holder_type: Map.get(bank_params, :account_holder_type, "individual"),
      bank_name: Map.get(bank_params, :bank_name),
      country: Map.get(bank_params, :country, "US"),
      currency: Map.get(bank_params, :currency, "usd"),
      fingerprint: generate_fingerprint(),
      id: generate_id("ba"),
      last4: String.slice(Map.get(bank_params, :account_number, ""), -4..-1),
      object: "bank_account",
      routing_number: Map.get(bank_params, :routing_number),
      status: "verified"
    }
  end

  defp infer_brand(number) when is_binary(number) do
    cond do
      String.starts_with?(number, "4") -> "Visa"
      String.starts_with?(number, "5") -> "Mastercard"
      String.starts_with?(number, "3") -> "American Express"
      String.starts_with?(number, "6") -> "Discover"
      true -> "Unknown"
    end
  end

  defp infer_brand(_), do: "Unknown"

  defp generate_fingerprint do
    :crypto.strong_rand_bytes(8)
    |> Base.encode16(case: :lower)
  end

  defp maybe_expand(token, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(token, expand_params)
  end
end
