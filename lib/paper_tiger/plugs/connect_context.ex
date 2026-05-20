defmodule PaperTiger.Plugs.ConnectContext do
  @moduledoc """
  Applies Stripe Connect request context from the `Stripe-Account` header.

  The header must contain an existing connected account ID. Once accepted,
  normal resource stores scope reads and writes to that connected account for
  the rest of the request.
  """

  @behaviour Plug

  import Plug.Conn

  alias PaperTiger.Connect
  alias PaperTiger.Resource
  alias PaperTiger.Store.Accounts

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_req_header(conn, "stripe-account") do
      [] ->
        Connect.clear_account()
        conn

      [account_id | _] ->
        connect_as(conn, account_id)
    end
  end

  defp connect_as(conn, account_id) do
    cond do
      not Connect.account_id?(account_id) ->
        conn
        |> Resource.error_response(PaperTiger.Error.invalid_request("Invalid Stripe-Account header", "Stripe-Account"))
        |> halt()

      account_exists?(account_id) ->
        Connect.put_account(account_id)
        assign(conn, :stripe_account, account_id)

      true ->
        conn
        |> Resource.error_response(PaperTiger.Error.not_found("account", account_id))
        |> halt()
    end
  end

  defp account_exists?(account_id) do
    Connect.without_account(fn ->
      match?({:ok, _account}, Accounts.get(account_id))
    end)
  end
end
