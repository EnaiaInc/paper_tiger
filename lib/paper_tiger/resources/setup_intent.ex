defmodule PaperTiger.Resources.SetupIntent do
  @moduledoc """
  Handles SetupIntent resource endpoints.

  ## Endpoints

  - POST   /v1/setup_intents      - Create setup intent
  - GET    /v1/setup_intents/:id  - Retrieve setup intent
  - POST   /v1/setup_intents/:id  - Update setup intent
  - GET    /v1/setup_intents      - List setup intents

  Note: Setup intents cannot be deleted (only canceled).

  ## SetupIntent Object

      %{
        id: "seti_...",
        object: "setup_intent",
        created: 1234567890,
        customer: "cus_...",
        payment_method: "pm_...",
        status: "requires_payment_method",
        usage: "off_session",
        metadata: %{},
        # ... other fields
      }
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.SetupIntents


  @doc """
  Creates a new setup intent.

  ## Required Parameters

  None (all optional for SetupIntent creation)

  ## Optional Parameters

  - customer - Customer ID for this setup intent
  - payment_method - Payment method ID (can be updated later)
  - usage - How the payment method will be used ("off_session" or "on_session")
  - metadata - Key-value metadata
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    setup_intent = build_setup_intent(conn.params)

    {:ok, setup_intent} = SetupIntents.insert(setup_intent)
    maybe_store_idempotency(conn, setup_intent)

    setup_intent
    |> maybe_expand(conn.params)
    |> then(&json_response(conn, 200, &1))
  end

  @doc """
  Retrieves a setup intent by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case SetupIntents.get(id) do
      {:ok, setup_intent} ->
        setup_intent
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("setup_intent", id))
    end
  end

  @doc """
  Updates a setup intent.

  ## Updatable Fields

  - customer
  - payment_method
  - metadata
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- SetupIntents.get(id),
         updated =
           merge_updates(existing, conn.params, [
             :id,
             :object,
             :created,
             :status,
             :usage
           ]),
         {:ok, updated} <- SetupIntents.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("setup_intent", id))
    end
  end

  @doc """
  Lists all setup intents with pagination.

  ## Parameters

  - limit - Number of items (default: 10, max: 100)
  - starting_after - Cursor for pagination
  - ending_before - Reverse cursor
  - customer - Filter by customer ID
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)

    result = SetupIntents.list(pagination_opts)

    json_response(conn, 200, result)
  end

  ## Private Functions

  defp build_setup_intent(params) do
    %{
      id: generate_id("seti"),
      object: "setup_intent",
      created: PaperTiger.now(),
      customer: Map.get(params, :customer),
      payment_method: Map.get(params, :payment_method),
      status: "requires_payment_method",
      usage: Map.get(params, :usage, "off_session"),
      metadata: Map.get(params, :metadata, %{}),
      # Additional fields
      livemode: false,
      application: Map.get(params, :application),
      cancellation_reason: nil,
      client_secret: generate_client_secret(),
      description: Map.get(params, :description),
      flow_directions: Map.get(params, :flow_directions, []),
      last_setup_error: nil,
      mandate: Map.get(params, :mandate),
      next_action: nil,
      on_behalf_of: Map.get(params, :on_behalf_of),
      payment_method_options: Map.get(params, :payment_method_options),
      payment_method_types: Map.get(params, :payment_method_types, ["card"]),
      single_use_mandate: nil
    }
  end

  defp maybe_expand(setup_intent, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(setup_intent, expand_params)
  end

  defp generate_client_secret do
    random_part =
      :crypto.strong_rand_bytes(16)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "seti_secret_#{random_part}"
  end
end
