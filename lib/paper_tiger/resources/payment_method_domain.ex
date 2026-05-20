defmodule PaperTiger.Resources.PaymentMethodDomain do
  @moduledoc """
  Handles PaymentMethodDomain resource endpoints.
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.PaymentMethodDomains

  @wallet_fields [:amazon_pay, :apple_pay, :google_pay, :klarna, :link, :paypal]

  @doc """
  Creates a payment method domain.
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:domain_name]),
         payment_method_domain = build_payment_method_domain(conn.params),
         {:ok, payment_method_domain} <- PaymentMethodDomains.insert(payment_method_domain) do
      maybe_store_idempotency(conn, payment_method_domain)

      payment_method_domain
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :invalid_params, field} ->
        error_response(conn, PaperTiger.Error.invalid_request("Missing required parameter", field))
    end
  end

  @doc """
  Retrieves a payment method domain by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case PaymentMethodDomains.get(id) do
      {:ok, payment_method_domain} ->
        payment_method_domain
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("payment_method_domain", id))
    end
  end

  @doc """
  Updates a payment method domain.
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    with {:ok, existing} <- PaymentMethodDomains.get(id),
         updated =
           existing
           |> merge_updates(conn.params, [:id, :object, :created, :domain_name, :livemode])
           |> cast_enabled()
           |> put_wallet_statuses(),
         {:ok, updated} <- PaymentMethodDomains.update(updated) do
      updated
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    else
      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("payment_method_domain", id))
    end
  end

  @doc """
  Lists payment method domains.
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)
    result = PaymentMethodDomains.list(pagination_opts)
    json_response(conn, 200, result)
  end

  defp build_payment_method_domain(params) do
    %{
      created: PaperTiger.now(),
      domain_name: params.domain_name,
      enabled: get_boolean(params, :enabled, true),
      id: generate_id("pmd"),
      livemode: false,
      object: "payment_method_domain"
    }
    |> put_wallet_statuses()
  end

  defp put_wallet_statuses(%{enabled: enabled} = domain) do
    status = if enabled, do: "active", else: "inactive"

    Enum.reduce(@wallet_fields, domain, fn field, acc ->
      Map.put(acc, field, %{status: status})
    end)
  end

  defp cast_enabled(%{enabled: enabled} = domain) do
    Map.put(domain, :enabled, to_boolean(enabled))
  end

  defp get_boolean(params, key, default) do
    case Map.get(params, key) do
      nil -> default
      value -> to_boolean(value)
    end
  end

  defp maybe_expand(payment_method_domain, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(payment_method_domain, expand_params)
  end
end
