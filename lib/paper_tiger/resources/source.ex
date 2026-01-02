defmodule PaperTiger.Resources.Source do
  @moduledoc """
  Handles Source resource endpoints.

  ## Endpoints

  - POST   /v1/sources      - Create source
  - GET    /v1/sources/:id  - Retrieve source
  - POST   /v1/sources/:id  - Update source
  - GET    /v1/sources      - List sources

  Note: Sources cannot be deleted (can only be detached from customers).

  ## Source Object

      %{
        id: "src_...",
        object: "source",
        created: 1234567890,
        type: "card" | "bank_account" | "sepa_debit" | "alipay" | etc.,
        customer: "cus_..." | nil,
        status: "pending" | "chargeable" | "consumed" | "canceled" | "failed",
        amount: 2000,  # Optional, for single-use sources (in cents)
        currency: "usd",
        metadata: %{},
        # ... other fields depending on source type
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Sources

  require Logger

  @doc """
  Creates a new source.

  ## Required Parameters

  - type - Source type (card, bank_account, sepa_debit, alipay, etc.)

  ## Optional Parameters

  - customer - Customer ID to attach source to
  - amount - Amount in cents (for single-use sources)
  - currency - Three-letter ISO currency code (default: "usd")
  - metadata - Key-value metadata
  - owner - Owner information (name, email, phone, address)
  - statement_descriptor - Descriptor for bank statements
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:type]),
         source = build_source(conn.params),
         {:ok, source} <- Sources.insert(source) do
      maybe_store_idempotency(conn, source)

      source
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
  Retrieves a source by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case Sources.get(id) do
      {:ok, source} ->
        source
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("source", id))
    end
  end

  @doc """
  Updates a source.

  Note: Sources have limited updatable fields.

  ## Updatable Fields

  - metadata
  - owner
  - statement_descriptor
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- Sources.get(id),
         updated =
           merge_updates(existing, conn.params, [
             :id,
             :object,
             :created,
             :type,
             :customer,
             :status,
             :amount,
             :currency,
             :livemode
           ]),
         {:ok, updated} <- Sources.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("source", id))
    end
  end

  @doc """
  Lists all sources with pagination and optional customer filter.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  - customer - Filter by customer ID (optional)
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result =
      case Map.get(conn.params, :customer) do
        nil ->
          Sources.list(pagination_opts)

        customer_id ->
          sources = Sources.find_by_customer(customer_id)
          PaperTiger.List.paginate(sources, Map.put(pagination_opts, :url, "/v1/sources"))
      end

    json_response(conn, 200, result)
  end

  ## Private Functions

  defp build_source(params) do
    %{
      id: generate_id("src"),
      object: "source",
      created: PaperTiger.now(),
      type: Map.get(params, :type),
      customer: Map.get(params, :customer),
      status: Map.get(params, :status, "pending"),
      amount: get_integer(params, :amount),
      currency: Map.get(params, :currency, "usd"),
      metadata: Map.get(params, :metadata, %{}),
      # Additional fields
      livemode: false,
      owner: Map.get(params, :owner),
      statement_descriptor: Map.get(params, :statement_descriptor),
      # Type-specific fields (will vary based on source type)
      card: Map.get(params, :card),
      bank_account: Map.get(params, :bank_account),
      sepa_debit: Map.get(params, :sepa_debit),
      alipay: Map.get(params, :alipay),
      # Single-use source fields
      flow: Map.get(params, :flow),
      redirect: Map.get(params, :redirect),
      receiver: Map.get(params, :receiver)
    }
  end

  defp maybe_expand(source, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(source, expand_params)
  end
end
