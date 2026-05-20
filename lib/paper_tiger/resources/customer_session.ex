defmodule PaperTiger.Resources.CustomerSession do
  @moduledoc """
  Handles Customer Session creation.
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Customers

  @doc """
  Creates a Customer Session.
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    with {:ok, _params} <- validate_params(conn.params, [:customer, :components]),
         :ok <- validate_customer(conn.params.customer),
         :ok <- validate_components(conn.params.components) do
      customer_session = build_customer_session(conn.params)
      maybe_store_idempotency(conn, customer_session)
      json_response(conn, 200, customer_session)
    else
      {:error, :invalid_params, field} ->
        error_response(conn, PaperTiger.Error.invalid_request("Missing required parameter", field))

      {:error, :customer_not_found, customer_id} ->
        error_response(conn, PaperTiger.Error.not_found("customer", customer_id))

      {:error, :components_disabled} ->
        error_response(
          conn,
          PaperTiger.Error.invalid_request("At least one Customer Session component must be enabled", "components")
        )
    end
  end

  defp validate_customer(customer_id) do
    case Customers.get(customer_id) do
      {:ok, _customer} -> :ok
      {:error, :not_found} -> {:error, :customer_not_found, customer_id}
    end
  end

  defp validate_components(components) when is_map(components) do
    if Enum.any?(components, fn {_name, config} -> component_enabled?(config) end) do
      :ok
    else
      {:error, :components_disabled}
    end
  end

  defp validate_components(_components), do: {:error, :components_disabled}

  defp component_enabled?(%{enabled: true}), do: true
  defp component_enabled?(%{enabled: "true"}), do: true
  defp component_enabled?(%{"enabled" => true}), do: true
  defp component_enabled?(%{"enabled" => "true"}), do: true
  defp component_enabled?(_config), do: false

  defp build_customer_session(params) do
    %{
      client_secret: generate_client_secret(),
      components: params.components,
      created: PaperTiger.now(),
      customer: params.customer,
      expires_at: PaperTiger.now() + 86_400,
      livemode: false,
      object: "customer_session"
    }
  end

  defp generate_client_secret do
    random_part =
      :crypto.strong_rand_bytes(32)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    "_#{random_part}"
  end
end
