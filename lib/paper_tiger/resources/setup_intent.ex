defmodule PaperTiger.Resources.SetupIntent do
  @moduledoc """
  Handles SetupIntent resource endpoints.

  ## Endpoints

  - POST   /v1/setup_intents      - Create setup intent
  - GET    /v1/setup_intents/:id  - Retrieve setup intent
  - POST   /v1/setup_intents/:id  - Update setup intent
  - GET    /v1/setup_intents      - List setup intents
  - POST   /v1/setup_intents/:id/confirm - Confirm setup intent
  - POST   /v1/setup_intents/:id/cancel - Cancel setup intent
  - POST   /v1/setup_intents/:id/verify_microdeposits - Verify bank microdeposits

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

  alias PaperTiger.MandateHelper
  alias PaperTiger.Resources.ConfirmationToken
  alias PaperTiger.Store.PaymentMethods
  alias PaperTiger.Store.SetupAttempts
  alias PaperTiger.Store.SetupIntents

  @cancelable_statuses ~w(requires_payment_method requires_confirmation requires_action)
  @confirmable_statuses ~w(requires_payment_method requires_confirmation)
  @cancellation_reasons ~w(abandoned duplicate requested_by_customer)
  @microdeposit_amounts [32, 45]
  @microdeposit_descriptor_code "SM11AA"

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

  @doc """
  Confirms a setup intent.

  Compatible card payment methods transition to succeeded immediately. Bank
  account methods transition to requires_action until microdeposits are verified.
  """
  @spec confirm(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def confirm(conn, id) do
    with {:ok, setup_intent} <- SetupIntents.get(id),
         :ok <- validate_confirmable(setup_intent),
         {:ok, payment_method} <- resolve_payment_method(setup_intent, conn.params),
         {:ok, confirmed} <- confirm_with_payment_method(setup_intent, payment_method, conn.params) do
      confirmed
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("setup_intent", id))

      {:error, :not_confirmable, status} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request(
            "This SetupIntent's status (#{status}) does not allow confirmation.",
            "status"
          )
        )

      {:error, :missing_payment_method} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request(
            "You cannot confirm this SetupIntent because it's missing a payment method.",
            "payment_method"
          )
        )

      {:error, :payment_method_not_found, payment_method_id} ->
        error_response(conn, PaperTiger.Error.not_found("payment_method", payment_method_id))

      {:error, :confirmation_token_not_found, confirmation_token_id} ->
        error_response(conn, PaperTiger.Error.not_found("confirmation_token", confirmation_token_id))

      {:error, :confirmation_token_used} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("This ConfirmationToken has already been used", "confirmation_token")
        )

      {:error, :payment_method_attached_elsewhere} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request(
            "This PaymentMethod is already attached to a different customer.",
            "payment_method"
          )
        )

      {:error, :setup_failed, error} ->
        error_response(conn, error)
    end
  end

  @doc """
  Cancels a setup intent that has not reached a terminal state.
  """
  @spec cancel(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def cancel(conn, id) do
    with {:ok, setup_intent} <- SetupIntents.get(id),
         :ok <- validate_cancelable(setup_intent),
         {:ok, cancellation_reason} <- validate_cancellation_reason(Map.get(conn.params, :cancellation_reason)) do
      canceled =
        setup_intent
        |> Map.put(:status, "canceled")
        |> Map.put(:cancellation_reason, cancellation_reason)
        |> Map.put(:next_action, nil)
        |> abandon_latest_attempt()

      {:ok, canceled} = SetupIntents.update(canceled)

      :telemetry.execute([:paper_tiger, :setup_intent, :canceled], %{}, %{object: canceled})

      canceled
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("setup_intent", id))

      {:error, :not_cancelable, status} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request(
            "This SetupIntent's status (#{status}) does not allow cancellation.",
            "status"
          )
        )

      {:error, :invalid_cancellation_reason, reason} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request(
            "Invalid cancellation_reason: #{reason}",
            "cancellation_reason"
          )
        )
    end
  end

  @doc """
  Verifies microdeposits for a bank-account setup intent.
  """
  @spec verify_microdeposits(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def verify_microdeposits(conn, id) do
    with {:ok, setup_intent} <- SetupIntents.get(id),
         :ok <- validate_microdeposit_verifiable(setup_intent),
         :ok <- validate_microdeposit_params(conn.params),
         {:ok, verified} <- verify_microdeposit_setup(setup_intent) do
      verified
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("setup_intent", id))

      {:error, :not_microdeposit_verifiable, status} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request(
            "This SetupIntent's status (#{status}) does not allow microdeposit verification.",
            "status"
          )
        )

      {:error, :missing_microdeposit_verification} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request(
            "You must provide either amounts or descriptor_code.",
            nil
          )
        )

      {:error, :invalid_microdeposit_verification, param} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request(
            "The provided microdeposit verification values do not match.",
            param
          )
        )

      {:error, :payment_method_not_found, payment_method_id} ->
        error_response(conn, PaperTiger.Error.not_found("payment_method", payment_method_id))

      {:error, :payment_method_attached_elsewhere} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request(
            "This PaymentMethod is already attached to a different customer.",
            "payment_method"
          )
        )
    end
  end

  ## Private Functions
  defp validate_confirmable(%{status: status}) when status in @confirmable_statuses, do: :ok
  defp validate_confirmable(%{status: status}), do: {:error, :not_confirmable, status}

  defp validate_cancelable(%{status: status}) when status in @cancelable_statuses, do: :ok
  defp validate_cancelable(%{status: status}), do: {:error, :not_cancelable, status}

  defp validate_cancellation_reason(nil), do: {:ok, nil}
  defp validate_cancellation_reason(reason) when reason in @cancellation_reasons, do: {:ok, reason}
  defp validate_cancellation_reason(reason), do: {:error, :invalid_cancellation_reason, reason}

  defp validate_microdeposit_verifiable(%{status: status}) when status in ["requires_action", "processing"], do: :ok

  defp validate_microdeposit_verifiable(%{status: status}), do: {:error, :not_microdeposit_verifiable, status}

  defp validate_microdeposit_params(params) do
    amounts = Map.get(params, :amounts)
    descriptor_code = Map.get(params, :descriptor_code)

    cond do
      valid_microdeposit_amounts?(amounts) ->
        :ok

      valid_microdeposit_descriptor_code?(descriptor_code) ->
        :ok

      present?(amounts) ->
        {:error, :invalid_microdeposit_verification, "amounts"}

      present?(descriptor_code) ->
        {:error, :invalid_microdeposit_verification, "descriptor_code"}

      true ->
        {:error, :missing_microdeposit_verification}
    end
  end

  defp valid_microdeposit_amounts?(amounts) when is_list(amounts) do
    amounts
    |> Enum.map(&to_integer/1)
    |> Enum.sort()
    |> Kernel.==(@microdeposit_amounts)
  end

  defp valid_microdeposit_amounts?(_amounts), do: false

  defp valid_microdeposit_descriptor_code?(descriptor_code) do
    descriptor_code == @microdeposit_descriptor_code
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?([]), do: false
  defp present?(_value), do: true

  defp resolve_payment_method(setup_intent, params) do
    cond do
      confirmation_token_id = Map.get(params, :confirmation_token) ->
        case ConfirmationToken.consume(confirmation_token_id, :setup_intent, setup_intent.id) do
          {:ok, payment_method, _confirmation_token} -> {:ok, payment_method}
          error -> error
        end

      is_map(Map.get(params, :payment_method_data)) ->
        create_payment_method_from_data(Map.get(params, :payment_method_data))

      payment_method_id = Map.get(params, :payment_method) || setup_intent.payment_method ->
        fetch_payment_method(payment_method_id)

      true ->
        {:error, :missing_payment_method}
    end
  end

  defp fetch_payment_method(payment_method_id) when is_binary(payment_method_id) do
    case PaymentMethods.get(payment_method_id) do
      {:ok, payment_method} -> {:ok, payment_method}
      {:error, :not_found} -> load_test_payment_method(payment_method_id)
    end
  end

  defp fetch_payment_method(_payment_method), do: {:error, :missing_payment_method}

  defp load_test_payment_method(payment_method_id) do
    if payment_method_id in PaperTiger.TestTokens.payment_method_ids() do
      {:ok, _stats} = PaperTiger.TestTokens.load()

      case PaymentMethods.get(payment_method_id) do
        {:ok, payment_method} -> {:ok, payment_method}
        {:error, :not_found} -> {:error, :payment_method_not_found, payment_method_id}
      end
    else
      {:error, :payment_method_not_found, payment_method_id}
    end
  end

  defp create_payment_method_from_data(payment_method_data) do
    type = Map.get(payment_method_data, :type)

    if is_binary(type) do
      payment_method = %{
        billing_details: Map.get(payment_method_data, :billing_details),
        card: Map.get(payment_method_data, :card),
        created: PaperTiger.now(),
        customer: nil,
        id: generate_id("pm"),
        livemode: false,
        metadata: Map.get(payment_method_data, :metadata, %{}),
        object: "payment_method",
        type: type,
        us_bank_account: Map.get(payment_method_data, :us_bank_account)
      }

      PaymentMethods.insert(payment_method)
    else
      {:error, :missing_payment_method}
    end
  end

  defp confirm_with_payment_method(setup_intent, payment_method, params) do
    setup_intent =
      setup_intent
      |> Map.put(:payment_method, payment_method.id)
      |> maybe_replace(:payment_method_options, params)

    cond do
      decline_code = decline_code(payment_method) ->
        fail_setup_intent(setup_intent, payment_method, decline_code)

      requires_microdeposits?(payment_method, setup_intent) ->
        require_microdeposit_verification(setup_intent, payment_method)

      true ->
        succeed_setup_intent(setup_intent, payment_method, params)
    end
  end

  defp fail_setup_intent(setup_intent, payment_method, decline_code) do
    error = PaperTiger.Error.card_declined(code: decline_code)
    {:ok, attempt} = create_setup_attempt(setup_intent, payment_method, "failed", error)

    failed =
      setup_intent
      |> Map.put(:last_setup_error, PaperTiger.Error.to_json(error).error)
      |> Map.put(:latest_attempt, attempt.id)
      |> Map.put(:next_action, nil)
      |> Map.put(:status, "requires_payment_method")

    {:ok, _failed} = SetupIntents.update(failed)

    :telemetry.execute([:paper_tiger, :setup_intent, :setup_failed], %{}, %{object: failed})

    {:error, :setup_failed, error}
  end

  defp require_microdeposit_verification(setup_intent, payment_method) do
    {:ok, attempt} = create_setup_attempt(setup_intent, payment_method, "requires_action")

    requires_action =
      setup_intent
      |> Map.put(:last_setup_error, nil)
      |> Map.put(:latest_attempt, attempt.id)
      |> Map.put(:next_action, microdeposit_next_action())
      |> Map.put(:status, "requires_action")

    {:ok, requires_action} = SetupIntents.update(requires_action)

    :telemetry.execute([:paper_tiger, :setup_intent, :requires_action], %{}, %{object: requires_action})

    {:ok, requires_action}
  end

  defp succeed_setup_intent(setup_intent, payment_method, params) do
    with {:ok, payment_method} <- maybe_attach_payment_method(payment_method, setup_intent.customer),
         {:ok, attempt} <- create_setup_attempt(setup_intent, payment_method, "succeeded"),
         {:ok, mandate_id} <- MandateHelper.ensure_for_setup_intent(setup_intent, payment_method, params) do
      succeeded =
        setup_intent
        |> Map.put(:last_setup_error, nil)
        |> Map.put(:latest_attempt, attempt.id)
        |> Map.put(:mandate, mandate_id)
        |> Map.put(:next_action, nil)
        |> Map.put(:status, "succeeded")

      {:ok, succeeded} = SetupIntents.update(succeeded)

      :telemetry.execute([:paper_tiger, :setup_intent, :succeeded], %{}, %{object: succeeded})

      {:ok, succeeded}
    end
  end

  defp verify_microdeposit_setup(setup_intent) do
    with {:ok, payment_method} <- fetch_payment_method(setup_intent.payment_method),
         {:ok, payment_method} <- maybe_attach_payment_method(payment_method, setup_intent.customer),
         {:ok, latest_attempt_id} <- succeed_latest_or_new_attempt(setup_intent, payment_method),
         {:ok, mandate_id} <- MandateHelper.ensure_for_setup_intent(setup_intent, payment_method, %{}) do
      verified =
        setup_intent
        |> Map.put(:last_setup_error, nil)
        |> Map.put(:latest_attempt, latest_attempt_id)
        |> Map.put(:mandate, mandate_id)
        |> Map.put(:next_action, nil)
        |> Map.put(:status, "succeeded")

      {:ok, verified} = SetupIntents.update(verified)

      :telemetry.execute([:paper_tiger, :setup_intent, :succeeded], %{}, %{object: verified})

      {:ok, verified}
    end
  end

  defp succeed_latest_or_new_attempt(%{latest_attempt: attempt_id} = setup_intent, payment_method)
       when is_binary(attempt_id) do
    case SetupAttempts.get(attempt_id) do
      {:ok, attempt} ->
        succeeded = %{attempt | setup_error: nil, status: "succeeded"}
        {:ok, succeeded} = SetupAttempts.update(succeeded)
        {:ok, succeeded.id}

      {:error, :not_found} ->
        succeed_latest_or_new_attempt(Map.delete(setup_intent, :latest_attempt), payment_method)
    end
  end

  defp succeed_latest_or_new_attempt(setup_intent, payment_method) do
    {:ok, attempt} = create_setup_attempt(setup_intent, payment_method, "succeeded")
    {:ok, attempt.id}
  end

  defp maybe_attach_payment_method(payment_method, nil), do: {:ok, payment_method}

  defp maybe_attach_payment_method(%{customer: nil} = payment_method, customer_id) do
    attached = %{payment_method | customer: customer_id}
    PaymentMethods.update(attached)
  end

  defp maybe_attach_payment_method(%{customer: existing_customer_id} = payment_method, customer_id)
       when existing_customer_id == customer_id do
    {:ok, payment_method}
  end

  defp maybe_attach_payment_method(_payment_method, _customer_id), do: {:error, :payment_method_attached_elsewhere}

  defp create_setup_attempt(setup_intent, payment_method, status, error \\ nil) do
    setup_attempt = %{
      application: Map.get(setup_intent, :application),
      attach_to_self: Map.get(setup_intent, :attach_to_self, false),
      created: PaperTiger.now(),
      customer: Map.get(setup_intent, :customer),
      flow_directions: Map.get(setup_intent, :flow_directions),
      id: generate_id("setatt"),
      livemode: false,
      object: "setup_attempt",
      on_behalf_of: Map.get(setup_intent, :on_behalf_of),
      payment_method: payment_method.id,
      payment_method_details: payment_method_details(payment_method),
      setup_error: setup_error(error),
      setup_intent: setup_intent.id,
      status: status,
      usage: Map.get(setup_intent, :usage, "off_session")
    }

    SetupAttempts.insert(setup_attempt)
  end

  defp setup_error(nil), do: nil
  defp setup_error(%PaperTiger.Error{} = error), do: PaperTiger.Error.to_json(error).error

  defp payment_method_details(%{type: "card"} = payment_method) do
    %{
      card: Map.get(payment_method, :card),
      type: "card"
    }
  end

  defp payment_method_details(%{type: type} = payment_method) when is_binary(type) do
    details = Map.get(payment_method, String.to_existing_atom(type), %{})
    Map.put(%{type: type}, type, details)
  rescue
    ArgumentError -> %{type: type}
  end

  defp payment_method_details(_payment_method), do: %{}

  defp requires_microdeposits?(%{type: type}, _setup_intent) when type in ["us_bank_account", "acss_debit"], do: true

  defp requires_microdeposits?(_payment_method, _setup_intent), do: false

  defp decline_code(payment_method) do
    payment_method
    |> Map.get(:metadata, %{})
    |> Map.get(:_paper_tiger_decline_code)
  end

  defp microdeposit_next_action do
    %{
      type: "verify_with_microdeposits",
      verify_with_microdeposits: %{
        arrival_date: PaperTiger.now() + 172_800,
        hosted_verification_url: nil,
        microdeposit_type: "amounts"
      }
    }
  end

  defp abandon_latest_attempt(%{latest_attempt: attempt_id} = setup_intent) when is_binary(attempt_id) do
    case SetupAttempts.get(attempt_id) do
      {:ok, attempt} ->
        {:ok, _attempt} = SetupAttempts.update(%{attempt | status: "abandoned"})
        setup_intent

      {:error, :not_found} ->
        setup_intent
    end
  end

  defp abandon_latest_attempt(setup_intent), do: setup_intent

  defp maybe_replace(resource, key, params) do
    if Map.has_key?(params, key) do
      Map.put(resource, key, Map.get(params, key))
    else
      resource
    end
  end

  defp build_setup_intent(params) do
    %{
      application: Map.get(params, :application),
      attach_to_self: Map.get(params, :attach_to_self, false),
      automatic_payment_methods: Map.get(params, :automatic_payment_methods),
      cancellation_reason: nil,
      client_secret: generate_client_secret(),
      created: PaperTiger.now(),
      customer: Map.get(params, :customer),
      description: Map.get(params, :description),
      excluded_payment_method_types: Map.get(params, :excluded_payment_method_types),
      flow_directions: Map.get(params, :flow_directions, []),
      id: generate_id("seti"),
      last_setup_error: nil,
      latest_attempt: nil,
      livemode: false,
      mandate: Map.get(params, :mandate),
      metadata: Map.get(params, :metadata, %{}),
      next_action: nil,
      object: "setup_intent",
      on_behalf_of: Map.get(params, :on_behalf_of),
      payment_method: Map.get(params, :payment_method),
      payment_method_configuration_details: nil,
      payment_method_options: Map.get(params, :payment_method_options),
      payment_method_types: Map.get(params, :payment_method_types, ["card"]),
      single_use_mandate: nil,
      status: initial_status(params),
      usage: Map.get(params, :usage, "off_session")
    }
  end

  defp initial_status(%{payment_method: payment_method}) when is_binary(payment_method), do: "requires_confirmation"
  defp initial_status(_params), do: "requires_payment_method"

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
