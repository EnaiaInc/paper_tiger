defmodule PaperTiger.Resources.BillingPortalConfiguration do
  @moduledoc """
  Handles Billing Portal Configuration resource endpoints.
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.BillingPortalConfigurations

  @doc """
  Creates a Billing Portal Configuration.
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:features]),
         configuration = build_configuration(conn.params),
         {:ok, configuration} <- BillingPortalConfigurations.insert(configuration) do
      maybe_store_idempotency(conn, configuration)

      configuration
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :invalid_params, field} ->
        error_response(conn, PaperTiger.Error.invalid_request("Missing required parameter", field))
    end
  end

  @doc """
  Retrieves a Billing Portal Configuration.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case BillingPortalConfigurations.get(id) do
      {:ok, configuration} ->
        configuration
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("billing_portal.configuration", id))
    end
  end

  @doc """
  Updates a Billing Portal Configuration.
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    case BillingPortalConfigurations.get(id) do
      {:ok, existing} ->
        updated =
          existing
          |> merge_updates(normalize_update_params(conn.params))
          |> Map.put(:updated, PaperTiger.now())

        {:ok, updated} = BillingPortalConfigurations.update(updated)

        updated
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("billing_portal.configuration", id))
    end
  end

  @doc """
  Lists Billing Portal Configurations.
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    conn.params
    |> parse_pagination_params()
    |> BillingPortalConfigurations.list()
    |> then(&json_response(conn, 200, &1))
  end

  @doc false
  @spec build_default() :: map()
  def build_default do
    build_configuration(%{is_default: true})
  end

  defp build_configuration(params) do
    now = PaperTiger.now()

    %{
      active: boolean_param(params, :active, true),
      application: nil,
      business_profile: Map.get(params, :business_profile, default_business_profile()),
      created: now,
      default_return_url: Map.get(params, :default_return_url),
      features: Map.get(params, :features, default_features()),
      id: generate_id("bpc", Map.get(params, :id)),
      is_default: boolean_param(params, :is_default, false),
      livemode: false,
      login_page: Map.get(params, :login_page, %{enabled: false, url: nil}),
      metadata: Map.get(params, :metadata, %{}),
      object: "billing_portal.configuration",
      updated: now
    }
  end

  defp default_business_profile do
    %{
      headline: nil,
      privacy_policy_url: nil,
      terms_of_service_url: nil
    }
  end

  defp default_features do
    %{
      customer_update: %{allowed_updates: [], enabled: false},
      invoice_history: %{enabled: true},
      payment_method_update: %{enabled: false},
      subscription_cancel: %{
        cancellation_reason: %{enabled: false, options: []},
        enabled: false,
        mode: "at_period_end",
        proration_behavior: "none"
      },
      subscription_update: %{
        default_allowed_updates: [],
        enabled: false,
        products: [],
        proration_behavior: "none"
      }
    }
  end

  defp maybe_expand(configuration, params) do
    params
    |> parse_expand_params()
    |> then(&PaperTiger.Hydrator.hydrate(configuration, &1))
  end

  defp normalize_update_params(params) do
    params
    |> normalize_boolean_field(:active)
    |> normalize_boolean_field(:is_default)
  end

  defp normalize_boolean_field(params, key) do
    if Map.has_key?(params, key) do
      Map.put(params, key, to_boolean(Map.get(params, key)))
    else
      params
    end
  end

  defp boolean_param(params, key, default) do
    if Map.has_key?(params, key) do
      to_boolean(Map.get(params, key))
    else
      default
    end
  end
end
