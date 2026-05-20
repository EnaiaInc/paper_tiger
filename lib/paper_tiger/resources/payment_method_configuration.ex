defmodule PaperTiger.Resources.PaymentMethodConfiguration do
  @moduledoc """
  Handles PaymentMethodConfiguration resource endpoints.
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.PaymentMethodConfigurations

  @payment_method_types ~w(
    acss_debit
    affirm
    afterpay_clearpay
    alipay
    alma
    amazon_pay
    apple_pay
    apple_pay_later
    au_becs_debit
    bacs_debit
    bancontact
    billie
    blik
    boleto
    card
    cartes_bancaires
    cashapp
    customer_balance
    eps
    fpx
    giropay
    google_pay
    grabpay
    ideal
    jcb
    kakao_pay
    klarna
    konbini
    kr_card
    link
    mobilepay
    multibanco
    naver_pay
    nz_bank_account
    oxxo
    p24
    pay_by_bank
    payco
    paynow
    paypal
    pix
    promptpay
    revolut_pay
    samsung_pay
    satispay
    sepa_debit
    sofort
    swish
    twint
    us_bank_account
    wechat_pay
    zip
  )

  @default_on_types ~w(apple_pay card google_pay link)
  @payment_method_atoms Enum.map(@payment_method_types, &String.to_atom/1)

  @doc """
  Creates a payment method configuration.
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with :ok <- validate_name_or_parent(conn.params),
         payment_method_configuration = build_payment_method_configuration(conn.params),
         {:ok, payment_method_configuration} <- PaymentMethodConfigurations.insert(payment_method_configuration) do
      maybe_store_idempotency(conn, payment_method_configuration)

      payment_method_configuration
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :missing_name_or_parent} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("Missing required parameter", "name")
        )
    end
  end

  @doc """
  Retrieves a payment method configuration by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case PaymentMethodConfigurations.get(id) do
      {:ok, payment_method_configuration} ->
        payment_method_configuration
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("payment_method_configuration", id))
    end
  end

  @doc """
  Updates a payment method configuration.
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- PaymentMethodConfigurations.get(id),
         updated =
           existing
           |> merge_updates(Map.drop(conn.params, @payment_method_atoms), [
             :id,
             :object,
             :application,
             :created,
             :is_default,
             :livemode,
             :parent
           ])
           |> cast_active()
           |> put_payment_method_configs(conn.params, existing),
         {:ok, updated} <- PaymentMethodConfigurations.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("payment_method_configuration", id))
    end
  end

  @doc """
  Lists payment method configurations.
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)
    result = PaymentMethodConfigurations.list(pagination_opts)
    json_response(conn, 200, result)
  end

  defp validate_name_or_parent(params) do
    if present?(Map.get(params, :name)) || present?(Map.get(params, :parent)) do
      :ok
    else
      {:error, :missing_name_or_parent}
    end
  end

  defp build_payment_method_configuration(params) do
    %{
      active: get_boolean(params, :active, true),
      application: nil,
      created: PaperTiger.now(),
      id: generate_id("pmc"),
      is_default: false,
      livemode: false,
      name: Map.get(params, :name),
      object: "payment_method_configuration",
      parent: Map.get(params, :parent)
    }
    |> put_payment_method_configs(params, nil)
  end

  defp put_payment_method_configs(configuration, params, existing) do
    Enum.reduce(@payment_method_types, configuration, fn type, acc ->
      Map.put(acc, String.to_atom(type), payment_method_config(type, params, existing))
    end)
  end

  defp payment_method_config(type, params, existing) do
    display_params = display_params(type, params)
    existing_display = existing_display(type, existing)
    default_preference = default_preference(type)
    preference = display_preference(display_params, existing_display, default_preference)
    value = display_value(preference, existing_display, default_preference)

    %{
      available: value == "on",
      display_preference: %{
        overridable: param(display_params, :overridable) || Map.get(existing_display, :overridable),
        preference: preference,
        value: value
      }
    }
  end

  defp display_params(type, params) do
    params
    |> payment_method_params(type)
    |> param(:display_preference, %{})
  end

  defp payment_method_params(params, type) do
    Map.get(params, String.to_atom(type)) || Map.get(params, type) || %{}
  end

  defp existing_display(_type, nil), do: %{}

  defp existing_display(type, existing) do
    existing
    |> Map.get(String.to_atom(type))
    |> case do
      existing_config when is_map(existing_config) -> Map.get(existing_config, :display_preference, %{})
      _missing -> %{}
    end
  end

  defp display_preference(display_params, existing_display, default_preference) do
    param(display_params, :preference) ||
      Map.get(existing_display, :preference) ||
      default_preference
  end

  defp display_value("none", existing_display, default_preference) do
    Map.get(existing_display, :value, default_preference)
  end

  defp display_value(value, _existing_display, _default_preference), do: value

  defp default_preference(type) when type in @default_on_types, do: "on"
  defp default_preference(_type), do: "off"

  defp get_boolean(params, key, default) do
    case Map.get(params, key) do
      nil -> default
      value -> to_boolean(value)
    end
  end

  defp cast_active(%{active: active} = configuration) do
    Map.put(configuration, :active, to_boolean(active))
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  defp param(map, key, default \\ nil)

  defp param(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
  end

  defp param(_map, _key, default), do: default

  defp maybe_expand(payment_method_configuration, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(payment_method_configuration, expand_params)
  end
end
