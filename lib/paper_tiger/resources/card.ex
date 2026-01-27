defmodule PaperTiger.Resources.Card do
  @moduledoc """
  Handles Card resource endpoints.

  **DEPRECATED**: Cards are deprecated in favor of PaymentMethod, but still supported
  for backward compatibility.

  ## Endpoints

  - POST   /v1/customers/:customer_id/sources - Create card (attach to customer)
  - GET    /v1/customers/:customer_id/sources/:id - Retrieve card
  - POST   /v1/customers/:customer_id/sources/:id - Update card
  - DELETE /v1/customers/:customer_id/sources/:id - Delete card (detach from customer)
  - GET    /v1/customers/:customer_id/sources - List cards (filtered by customer)

  ## Card Object

      %{
        id: "card_...",
        object: "card",
        created: 1234567890,
        customer: "cus_...",
        brand: "Visa",
        last4: "4242",
        exp_month: 12,
        exp_year: 2025,
        fingerprint: "hash...",
        funding: "credit",
        metadata: %{},
        # ... other fields
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Cards


  @doc """
  Creates a new card (attaches to customer).

  ## Required Parameters

  - customer - Customer ID to attach card to

  ## Optional Parameters

  - source - Token ID or map of card details
  - brand - Card brand (Visa, Mastercard, American Express, Discover)
  - last4 - Last 4 digits
  - exp_month - Expiration month
  - exp_year - Expiration year
  - funding - Funding type (credit, debit, prepaid)
  - metadata - Key-value metadata
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:customer]),
         card = build_card(conn.params),
         {:ok, card} <- Cards.insert(card) do
      maybe_store_idempotency(conn, card)

      card
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
  Retrieves a card by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case Cards.get(id) do
      {:ok, card} ->
        card
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("card", id))
    end
  end

  @doc """
  Updates a card.

  ## Updatable Fields

  - exp_month
  - exp_year
  - metadata
  - address_city
  - address_country
  - address_line1
  - address_line2
  - address_state
  - address_zip
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- Cards.get(id),
         updated = merge_updates(existing, conn.params),
         {:ok, updated} <- Cards.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("card", id))
    end
  end

  @doc """
  Deletes a card (detaches from customer).

  Returns a deletion confirmation object.
  """
  @spec delete(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def delete(conn, id) do
    case Cards.get(id) do
      {:ok, _card} ->
        :ok = Cards.delete(id)

        json_response(conn, 200, %{
          deleted: true,
          id: id,
          object: "card"
        })

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("card", id))
    end
  end

  @doc """
  Lists all cards for a customer with pagination.

  ## Parameters

  - customer - Customer ID (required for filtering)
  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    customer_id = Map.get(conn.params, :customer)

    if customer_id do
      pagination_opts = parse_pagination_params(conn.params)

      cards = Cards.find_by_customer(customer_id)

      paginated_result =
        cards
        |> PaperTiger.List.paginate(Map.put(pagination_opts, :url, "/v1/customers/#{customer_id}/sources"))

      json_response(conn, 200, paginated_result)
    else
      error_response(
        conn,
        PaperTiger.Error.invalid_request("Missing required parameter", "customer")
      )
    end
  end

  ## Private Functions

  defp build_card(params) do
    %{
      id: generate_id("card"),
      object: "card",
      created: PaperTiger.now(),
      customer: Map.get(params, :customer),
      brand: Map.get(params, :brand, "Visa"),
      last4: Map.get(params, :last4),
      exp_month: Map.get(params, :exp_month),
      exp_year: Map.get(params, :exp_year),
      fingerprint: Map.get(params, :fingerprint, generate_fingerprint()),
      funding: Map.get(params, :funding, "credit"),
      metadata: Map.get(params, :metadata, %{}),
      # Additional fields
      livemode: false,
      address_city: Map.get(params, :address_city),
      address_country: Map.get(params, :address_country),
      address_line1: Map.get(params, :address_line1),
      address_line2: Map.get(params, :address_line2),
      address_state: Map.get(params, :address_state),
      address_zip: Map.get(params, :address_zip),
      country: Map.get(params, :country),
      cvc_check: Map.get(params, :cvc_check),
      dynamic_last4: Map.get(params, :dynamic_last4),
      empty: Map.get(params, :empty),
      exp_check: Map.get(params, :exp_check),
      name: Map.get(params, :name),
      tokenization_method: Map.get(params, :tokenization_method),
      wallet: Map.get(params, :wallet)
    }
  end

  defp maybe_expand(card, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(card, expand_params)
  end

  defp generate_fingerprint do
    :crypto.hash(:sha256, "#{:os.system_time(:millisecond)}#{:rand.uniform(1_000_000)}")
    |> Base.encode16(case: :lower)
    |> String.slice(0..31)
  end
end
