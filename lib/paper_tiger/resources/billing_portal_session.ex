defmodule PaperTiger.Resources.BillingPortalSession do
  @moduledoc """
  Handles Billing Portal Session creation and deterministic browser redirect.
  """

  import PaperTiger.Resource

  alias PaperTiger.Resources.BillingPortalConfiguration
  alias PaperTiger.Store.BillingPortalConfigurations
  alias PaperTiger.Store.BillingPortalSessions
  alias PaperTiger.Store.Customers

  @doc """
  Creates a Billing Portal Session.
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:customer]),
         :ok <- validate_customer(conn.params.customer),
         {:ok, configuration} <- resolve_configuration(Map.get(conn.params, :configuration)),
         session = build_session(conn.params, configuration),
         {:ok, session} <- BillingPortalSessions.insert(session) do
      maybe_store_idempotency(conn, session)
      json_response(conn, 200, session)
    else
      {:error, :invalid_params, field} ->
        error_response(conn, PaperTiger.Error.invalid_request("Missing required parameter", field))

      {:error, :customer_not_found, customer_id} ->
        error_response(conn, PaperTiger.Error.not_found("customer", customer_id))

      {:error, :configuration_not_found, configuration_id} ->
        error_response(
          conn,
          PaperTiger.Error.not_found("billing_portal.configuration", configuration_id)
        )
    end
  end

  @doc """
  Browser-accessible Billing Portal Session URL.

  PaperTiger does not host an interactive subscription-management page. Visiting
  the portal URL redirects to the session's return URL when present, or returns
  a deterministic completion response otherwise.
  """
  @spec browser_enter(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def browser_enter(conn, id) do
    case BillingPortalSessions.get(id) do
      {:ok, %{return_url: return_url}} when is_binary(return_url) and return_url != "" ->
        conn
        |> Plug.Conn.put_resp_header("location", return_url)
        |> Plug.Conn.send_resp(302, "")

      {:ok, _session} ->
        Plug.Conn.send_resp(conn, 200, "Billing portal session completed")

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("billing_portal.session", id))
    end
  end

  defp validate_customer(customer_id) do
    case Customers.get(customer_id) do
      {:ok, _customer} -> :ok
      {:error, :not_found} -> {:error, :customer_not_found, customer_id}
    end
  end

  defp resolve_configuration(nil) do
    existing_default =
      BillingPortalConfigurations.list(%{limit: 100}).data
      |> Enum.find(fn configuration -> Map.get(configuration, :is_default) end)

    case existing_default do
      nil ->
        configuration = BillingPortalConfiguration.build_default()
        BillingPortalConfigurations.insert(configuration)

      configuration ->
        {:ok, configuration}
    end
  end

  defp resolve_configuration(configuration_id) when is_binary(configuration_id) do
    case BillingPortalConfigurations.get(configuration_id) do
      {:ok, configuration} -> {:ok, configuration}
      {:error, :not_found} -> {:error, :configuration_not_found, configuration_id}
    end
  end

  defp build_session(params, configuration) do
    id = generate_id("bps", Map.get(params, :id))

    %{
      configuration: configuration.id,
      created: PaperTiger.now(),
      customer: Map.get(params, :customer),
      flow: flow(Map.get(params, :flow_data)),
      id: id,
      livemode: false,
      locale: Map.get(params, :locale),
      object: "billing_portal.session",
      on_behalf_of: Map.get(params, :on_behalf_of),
      return_url: Map.get(params, :return_url) || Map.get(configuration, :default_return_url),
      url: portal_url(id)
    }
  end

  defp flow(nil), do: nil
  defp flow(flow_data) when is_map(flow_data), do: flow_data

  defp portal_url(id) do
    port = Application.get_env(:paper_tiger, :actual_port) || Application.get_env(:paper_tiger, :port, 4001)
    "http://localhost:#{port}/billing_portal/sessions/#{id}"
  end
end
