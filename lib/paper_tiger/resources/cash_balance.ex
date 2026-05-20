defmodule PaperTiger.Resources.CashBalance do
  @moduledoc """
  Handles Customer Cash Balance endpoints.
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Customers

  @doc """
  Retrieves a customer's cash balance.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, customer_id) do
    case Customers.get(customer_id) do
      {:ok, customer} ->
        json_response(conn, 200, cash_balance(customer))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("customer", customer_id))
    end
  end

  @doc """
  Updates a customer's cash balance settings.
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, customer_id) do
    case Customers.get(customer_id) do
      {:ok, customer} ->
        existing = cash_balance(customer)

        settings =
          existing.settings
          |> Map.merge(normalize_settings(Map.get(conn.params, :settings, %{})))

        updated_cash_balance = Map.put(existing, :settings, settings)
        {:ok, _customer} = Customers.update(Map.put(customer, :cash_balance, updated_cash_balance))

        json_response(conn, 200, updated_cash_balance)

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("customer", customer_id))
    end
  end

  defp cash_balance(customer) do
    Map.get(customer, :cash_balance) ||
      %{
        available: %{},
        customer: customer.id,
        livemode: false,
        object: "cash_balance",
        settings: %{
          reconciliation_mode: "automatic",
          using_merchant_default: true
        }
      }
  end

  defp normalize_settings(settings) when is_map(settings) do
    Map.new(settings, fn
      {key, value} when is_binary(key) ->
        {settings_key(key), value}

      {key, value} ->
        {key, value}
    end)
  end

  defp normalize_settings(_settings), do: %{}

  defp settings_key("reconciliation_mode"), do: :reconciliation_mode
  defp settings_key("using_merchant_default"), do: :using_merchant_default
  defp settings_key(key), do: key
end
