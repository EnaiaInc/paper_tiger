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
        # ... other fields
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.PaymentIntents

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
             :status
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

  @doc """
  Confirms a payment intent, transitioning it to "succeeded" and creating
  a charge + balance transaction.
  """
  @spec confirm(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def confirm(conn, id) do
    with {:ok, pi} <- PaymentIntents.get(id),
         :ok <- validate_confirmable(pi) do
      # Apply payment_method from confirm params if provided
      # Transition to succeeded
      # Create charge + balance transaction
      # Re-fetch to get latest_charge
      ## Private Functions

      updated =
        case conn.params do
          %{payment_method: pm} when is_binary(pm) -> %{pi | payment_method: pm}
          _ -> pi
        end

      updated = %{updated | status: "succeeded"}
      # Additional fields
      {:ok, updated} = PaymentIntents.update(updated)
      {:ok, _charge} = PaperTiger.ChargeHelper.create_for_payment_intent(updated)
      {:ok, final} = PaymentIntents.get(id)

      :telemetry.execute([:paper_tiger, :payment_intent, :succeeded], %{}, %{object: final})

      final
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("payment_intent", id))

      {:error, :not_confirmable, status} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request(
            "This PaymentIntent's status (#{status}) does not allow confirmation.",
            "status"
          )
        )
    end
  end

  defp validate_confirmable(%{status: status}) when status in ["requires_payment_method", "requires_confirmation"],
    do: :ok

  defp validate_confirmable(%{status: status}), do: {:error, :not_confirmable, status}

  defp build_payment_intent(params) do
    %{
      amount: get_integer(params, :amount),
      amount_details: Map.get(params, :amount_details),
      application: nil,
      application_fee_amount: nil,
      cancellation_reason: nil,
      capture_method: Map.get(params, :capture_method, "automatic"),
      client_secret: generate_client_secret(),
      confirmation_method: Map.get(params, :confirmation_method, "automatic"),
      created: PaperTiger.now(),
      currency: Map.get(params, :currency),
      customer: Map.get(params, :customer),
      description: Map.get(params, :description),
      id: generate_id("pi"),
      invoice: nil,
      last_payment_error: nil,
      latest_charge: nil,
      livemode: false,
      mandate: nil,
      metadata: Map.get(params, :metadata, %{}),
      next_action: nil,
      object: "payment_intent",
      off_session: Map.get(params, :off_session),
      on_behalf_of: Map.get(params, :on_behalf_of),
      payment_method: Map.get(params, :payment_method),
      processing: nil,
      receipt_email: Map.get(params, :receipt_email),
      review: nil,
      setup_future_usage: Map.get(params, :setup_future_usage),
      shipping: Map.get(params, :shipping),
      source: Map.get(params, :source),
      statement_descriptor: Map.get(params, :statement_descriptor),
      status: "requires_payment_method"
    }
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
