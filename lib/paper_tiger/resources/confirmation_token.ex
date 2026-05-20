defmodule PaperTiger.Resources.ConfirmationToken do
  @moduledoc """
  Handles ConfirmationToken retrieval and test-helper creation.
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.ConfirmationTokens
  alias PaperTiger.Store.PaymentMethods

  @doc """
  Creates a test-mode ConfirmationToken.
  """
  @spec create_test_helper(Plug.Conn.t()) :: Plug.Conn.t()
  def create_test_helper(conn) do
    with {:ok, token} <- build_confirmation_token(conn.params),
         {:ok, token} <- ConfirmationTokens.insert(token) do
      maybe_store_idempotency(conn, token)

      token
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :missing_payment_method} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("You must provide either payment_method or payment_method_data", nil)
        )

      {:error, :missing_payment_method_type} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("Missing required parameter", "payment_method_data[type]")
        )

      {:error, :payment_method_not_found, payment_method_id} ->
        error_response(conn, PaperTiger.Error.not_found("payment_method", payment_method_id))
    end
  end

  @doc """
  Retrieves a ConfirmationToken by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case ConfirmationTokens.get(id) do
      {:ok, token} ->
        token
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("confirmation_token", id))
    end
  end

  @doc """
  Consumes a ConfirmationToken for an intent confirmation.
  """
  @spec consume(String.t(), :payment_intent | :setup_intent, String.t()) ::
          {:ok, map(), map()}
          | {:error, :confirmation_token_not_found, String.t()}
          | {:error, :confirmation_token_used}
          | {:error, :missing_payment_method}
          | {:error, :payment_method_not_found, String.t()}
  def consume(token_id, intent_field, intent_id) when intent_field in [:payment_intent, :setup_intent] do
    with {:ok, token} <- fetch_token(token_id),
         :ok <- validate_unused(token),
         {:ok, payment_method} <- materialize_payment_method(token),
         updated =
           token
           |> Map.put(:payment_method, payment_method.id)
           |> Map.put(intent_field, intent_id),
         {:ok, updated} <- ConfirmationTokens.update(updated) do
      {:ok, payment_method, updated}
    end
  end

  defp fetch_token(token_id) do
    case ConfirmationTokens.get(token_id) do
      {:ok, token} -> {:ok, token}
      {:error, :not_found} -> {:error, :confirmation_token_not_found, token_id}
    end
  end

  defp validate_unused(token) do
    if Map.get(token, :payment_intent) || Map.get(token, :setup_intent) do
      {:error, :confirmation_token_used}
    else
      :ok
    end
  end

  defp build_confirmation_token(params) do
    with {:ok, preview, payment_method_id} <- build_payment_method_preview(params) do
      token = %{
        created: PaperTiger.now(),
        expires_at: PaperTiger.now() + 43_200,
        id: generate_id("ctoken"),
        livemode: false,
        mandate_data: param(params, :mandate_data),
        object: "confirmation_token",
        payment_intent: nil,
        payment_method: payment_method_id,
        payment_method_options: param(params, :payment_method_options),
        payment_method_preview: preview,
        return_url: param(params, :return_url),
        setup_future_usage: param(params, :setup_future_usage),
        setup_intent: nil,
        shipping: param(params, :shipping),
        use_stripe_sdk: param(params, :use_stripe_sdk, true)
      }

      {:ok, token}
    end
  end

  defp build_payment_method_preview(%{payment_method: payment_method_id}) when is_binary(payment_method_id) do
    with {:ok, payment_method} <- fetch_payment_method(payment_method_id) do
      {:ok, preview_from_payment_method(payment_method), payment_method.id}
    end
  end

  defp build_payment_method_preview(%{payment_method_data: payment_method_data}) when is_map(payment_method_data) do
    type = param(payment_method_data, :type)

    if is_binary(type) do
      {:ok, preview_from_payment_method_data(payment_method_data), nil}
    else
      {:error, :missing_payment_method_type}
    end
  end

  defp build_payment_method_preview(_params), do: {:error, :missing_payment_method}

  defp fetch_payment_method(payment_method_id) do
    case PaymentMethods.get(payment_method_id) do
      {:ok, payment_method} -> {:ok, payment_method}
      {:error, :not_found} -> load_test_payment_method(payment_method_id)
    end
  end

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

  defp materialize_payment_method(%{payment_method: payment_method_id}) when is_binary(payment_method_id) do
    fetch_payment_method(payment_method_id)
  end

  defp materialize_payment_method(%{payment_method_preview: %{type: type} = preview}) when is_binary(type) do
    payment_method = %{
      billing_details: Map.get(preview, :billing_details),
      card: Map.get(preview, :card),
      created: PaperTiger.now(),
      customer: nil,
      id: generate_id("pm"),
      livemode: false,
      metadata: %{},
      object: "payment_method",
      type: type
    }

    payment_method =
      case dynamic_param(preview, type) do
        nil -> payment_method
        details -> Map.put(payment_method, type, details)
      end

    PaymentMethods.insert(payment_method)
  end

  defp materialize_payment_method(_token), do: {:error, :missing_payment_method}

  defp preview_from_payment_method(payment_method) do
    type = Map.get(payment_method, :type, "card")

    base = %{
      billing_details: Map.get(payment_method, :billing_details) || empty_billing_details(),
      type: type
    }

    case type do
      "card" ->
        Map.put(base, :card, card_preview(Map.get(payment_method, :card, %{})))

      other_type ->
        case dynamic_param(payment_method, other_type) do
          nil -> base
          details -> Map.put(base, other_type, details)
        end
    end
  end

  defp preview_from_payment_method_data(payment_method_data) do
    type = param(payment_method_data, :type)

    base = %{
      billing_details: param(payment_method_data, :billing_details) || empty_billing_details(),
      type: type
    }

    case type do
      "card" ->
        Map.put(base, :card, card_preview(param(payment_method_data, :card, %{})))

      other_type ->
        case dynamic_param(payment_method_data, other_type) do
          nil -> base
          details -> Map.put(base, other_type, details)
        end
    end
  end

  defp card_preview(card) do
    %{
      brand: param(card, :brand, "visa"),
      checks: %{
        address_line1_check: nil,
        address_postal_code_check: nil,
        cvc_check: "unchecked"
      },
      country: param(card, :country, "US"),
      display_brand: param(card, :display_brand, param(card, :brand, "visa")),
      exp_month: param(card, :exp_month, 3),
      exp_year: param(card, :exp_year, 2025),
      fingerprint: param(card, :fingerprint, "paper_tiger_card_fingerprint"),
      funding: param(card, :funding, "credit"),
      generated_from: nil,
      last4: param(card, :last4, "4242"),
      networks: param(card, :networks, %{available: ["visa"], preferred: nil}),
      three_d_secure_usage: %{supported: true},
      wallet: nil
    }
  end

  defp empty_billing_details do
    %{
      address: %{
        city: nil,
        country: nil,
        line1: nil,
        line2: nil,
        postal_code: nil,
        state: nil
      },
      email: nil,
      name: nil,
      phone: nil
    }
  end

  defp dynamic_param(map, key) when is_map(map) and is_binary(key) do
    atom_key =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    Map.get(map, key) || if(atom_key, do: Map.get(map, atom_key))
  end

  defp param(map, key, default \\ nil)

  defp param(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
  end

  defp param(_map, _key, default), do: default

  defp maybe_expand(token, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(token, expand_params)
  end
end
