defmodule PaperTiger.Resources.PaymentIntent do
  @moduledoc """
  Handles PaymentIntent resource endpoints.

  ## Endpoints

  - POST   /v1/payment_intents      - Create payment intent
  - GET    /v1/payment_intents/:id  - Retrieve payment intent
  - POST   /v1/payment_intents/:id  - Update payment intent
  - GET    /v1/payment_intents      - List payment intents

  Note: Payment intents cannot be deleted (only canceled).

  ## PaymentIntent Object

      %{
        id: "pi_...",
        object: "payment_intent",
        created: 1234567890,
        amount: 2000,  # Amount in cents
        currency: "usd",
        status: "requires_payment_method",
        customer: "cus_...",
        payment_method: "pm_...",
        metadata: %{},
        charges: %{data: []},
        # ... other fields
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Charges
  alias PaperTiger.Store.PaymentIntents

  require Logger

  @doc """
  Creates a new payment intent.

  ## Required Parameters

  - amount - Amount in cents (e.g., 2000 for $20.00)
  - currency - Three-letter ISO currency code (e.g., "usd")

  ## Optional Parameters

  - customer - Customer ID this payment is for
  - payment_method - Payment method ID to use
  - metadata - Key-value metadata
  - description - Payment description
  - statement_descriptor - Descriptor for bank statements
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:amount, :currency]),
         payment_intent = build_payment_intent(conn.params),
         {:ok, payment_intent} <- PaymentIntents.insert(payment_intent) do
      maybe_store_idempotency(conn, payment_intent)

      :telemetry.execute([:paper_tiger, :payment_intent, :created], %{}, %{object: payment_intent})

      payment_intent
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
  Retrieves a payment intent by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case PaymentIntents.get(id) do
      {:ok, payment_intent} ->
        payment_intent
        |> load_charges()
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("payment_intent", id))
    end
  end

  @doc """
  Updates a payment intent.

  ## Updatable Fields

  - amount
  - customer
  - payment_method
  - metadata
  - description
  - statement_descriptor
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- PaymentIntents.get(id),
         updated =
           merge_updates(existing, conn.params, [
             :id,
             :object,
             :created,
             :currency,
             :status,
             :charges
           ]),
         {:ok, updated} <- PaymentIntents.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("payment_intent", id))
    end
  end

  @doc """
  Lists all payment intents with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  - customer - Filter by customer ID
  - status - Filter by status
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result = PaymentIntents.list(pagination_opts)

    json_response(conn, 200, result)
  end

  ## Private Functions

  defp build_payment_intent(params) do
    %{
      id: generate_id("pi"),
      object: "payment_intent",
      created: PaperTiger.now(),
      amount: Map.get(params, :amount),
      currency: Map.get(params, :currency),
      status: "requires_payment_method",
      customer: Map.get(params, :customer),
      payment_method: Map.get(params, :payment_method),
      metadata: Map.get(params, :metadata, %{}),
      charges: %{data: []},
      # Additional fields
      livemode: false,
      description: Map.get(params, :description),
      statement_descriptor: Map.get(params, :statement_descriptor),
      confirmation_method: Map.get(params, :confirmation_method, "automatic"),
      setup_future_usage: Map.get(params, :setup_future_usage),
      off_session: Map.get(params, :off_session),
      receipt_email: Map.get(params, :receipt_email),
      capture_method: Map.get(params, :capture_method, "automatic"),
      amount_details: Map.get(params, :amount_details),
      cancellation_reason: nil,
      client_secret: generate_client_secret(),
      next_action: nil,
      shipping: Map.get(params, :shipping),
      on_behalf_of: Map.get(params, :on_behalf_of),
      last_payment_error: nil,
      processing: nil,
      review: nil,
      application: nil,
      application_fee_amount: nil,
      invoice: nil,
      mandate: nil,
      source: Map.get(params, :source)
    }
  end

  # Loads actual charges from the store into the charges list
  defp load_charges(payment_intent) do
    charges =
      Charges.find_by_payment_intent(payment_intent.id)
      |> Enum.sort_by(& &1.created, :desc)

    Map.put(payment_intent, :charges, %{
      data: charges,
      has_more: false,
      object: "list",
      total_count: length(charges),
      url: "/v1/charges?payment_intent=#{payment_intent.id}"
    })
  end

  defp maybe_expand(payment_intent, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(payment_intent, expand_params)
  end

  defp generate_client_secret do
    random_part =
      :crypto.strong_rand_bytes(24)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "pi_secret_#{random_part}"
  end
end
