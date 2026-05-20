defmodule PaperTiger.Resources.AccountLink do
  @moduledoc """
  Handles Connect Account Link creation.

  Account Links are ephemeral in Stripe and are therefore not stored.
  """

  import PaperTiger.Resource

  alias PaperTiger.Connect
  alias PaperTiger.Store.Accounts

  @valid_types ~w(account_onboarding account_update)

  @doc """
  Creates an account link for onboarding or account updates.
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    Connect.without_account(fn ->
      with {:ok, _params} <- validate_params(conn.params, [:account, :refresh_url, :return_url, :type]),
           :ok <- validate_type(Map.get(conn.params, :type)),
           {:ok, _account} <- Accounts.get(Map.get(conn.params, :account)) do
        link = build_account_link(conn.params)
        maybe_store_idempotency(conn, link)
        json_response(conn, 200, link)
      else
        {:error, :invalid_params, field} ->
          error_response(conn, PaperTiger.Error.invalid_request("Missing required parameter", field))

        {:error, :invalid_type, type} ->
          error_response(conn, PaperTiger.Error.invalid_request("Invalid account link type: #{type}", "type"))

        {:error, :not_found} ->
          error_response(conn, PaperTiger.Error.not_found("account", Map.get(conn.params, :account)))
      end
    end)
  end

  defp validate_type(type) when type in @valid_types, do: :ok
  defp validate_type(type), do: {:error, :invalid_type, type}

  defp build_account_link(params) do
    created = PaperTiger.now()

    %{
      account: Map.fetch!(params, :account),
      collect: Map.get(params, :collect),
      created: created,
      expires_at: created + 300,
      object: "account_link",
      refresh_url: Map.fetch!(params, :refresh_url),
      return_url: Map.fetch!(params, :return_url),
      type: Map.fetch!(params, :type),
      url: "https://connect.stripe.com/setup/s/#{generate_id("link")}"
    }
  end
end
