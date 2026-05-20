defmodule PaperTiger.Resources.Account do
  @moduledoc """
  Handles legacy Connect Account endpoints.

  PaperTiger intentionally models `/v1/accounts` first rather than Accounts v2
  because current Stripe client libraries still commonly use the v1 resource.
  Accounts are platform-owned: they are stored in the sandbox namespace, not in
  the connected account request scope.
  """

  import PaperTiger.Resource

  alias PaperTiger.Connect
  alias PaperTiger.Store.Accounts

  @capability_fields ~w(
    card_payments
    transfers
    treasury
    card_issuing
    us_bank_account_ach_payments
  )a

  @doc """
  Creates a connected account.
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    Connect.without_account(fn ->
      account = build_account(conn.params)

      {:ok, account} = Accounts.insert(account)
      maybe_store_idempotency(conn, account)

      account
      |> maybe_expand(conn.params)
      |> then(&json_response(conn, 200, &1))
    end)
  end

  @doc """
  Retrieves a connected account by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    Connect.without_account(fn ->
      case Accounts.get(id) do
        {:ok, account} ->
          account
          |> maybe_expand(conn.params)
          |> then(&json_response(conn, 200, &1))

        {:error, :not_found} ->
          error_response(conn, PaperTiger.Error.not_found("account", id))
      end
    end)
  end

  @doc """
  Updates mutable account fields and requested capabilities.
  """
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, id) do
    Connect.without_account(fn ->
      with {:ok, existing} <- Accounts.get(id),
           updated = update_account(existing, conn.params),
           {:ok, updated} <- Accounts.update(updated) do
        updated
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))
      else
        {:error, :not_found} ->
          error_response(conn, PaperTiger.Error.not_found("account", id))
      end
    end)
  end

  @doc """
  Deletes a connected account from the platform account.
  """
  @spec delete(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def delete(conn, id) do
    Connect.without_account(fn ->
      case Accounts.get(id) do
        {:ok, _account} ->
          :ok = Accounts.delete(id)
          json_response(conn, 200, %{deleted: true, id: id, object: "account"})

        {:error, :not_found} ->
          error_response(conn, PaperTiger.Error.not_found("account", id))
      end
    end)
  end

  @doc """
  Lists accounts connected to the platform.
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    Connect.without_account(fn ->
      pagination_opts = parse_pagination_params(conn.params)
      json_response(conn, 200, Accounts.list(pagination_opts))
    end)
  end

  defp build_account(params) do
    capabilities = build_capabilities(Map.get(params, :capabilities, %{}))
    transfers_active? = Map.get(capabilities, :transfers) == "active"
    card_payments_active? = Map.get(capabilities, :card_payments) == "active"

    %{
      business_profile: Map.get(params, :business_profile, %{}),
      business_type: Map.get(params, :business_type),
      capabilities: capabilities,
      charges_enabled: card_payments_active?,
      controller: build_controller(params),
      country: Map.get(params, :country, "US"),
      created: PaperTiger.now(),
      default_currency: Map.get(params, :default_currency, "usd"),
      details_submitted: transfers_active? or card_payments_active?,
      email: Map.get(params, :email),
      external_accounts: empty_nested_list("/v1/accounts/pending/external_accounts"),
      future_requirements: empty_requirements(),
      id: generate_id("acct", Map.get(params, :id)),
      individual: Map.get(params, :individual),
      metadata: Map.get(params, :metadata, %{}),
      object: "account",
      payouts_enabled: transfers_active?,
      requirements: empty_requirements(),
      settings: build_settings(params),
      tos_acceptance: Map.get(params, :tos_acceptance, %{}),
      type: Map.get(params, :type, "custom")
    }
    |> then(fn account ->
      Map.put(account, :external_accounts, empty_nested_list("/v1/accounts/#{account.id}/external_accounts"))
    end)
  end

  defp update_account(existing, params) do
    immutable = [:id, :object, :created]

    existing
    |> merge_updates(params, immutable)
    |> maybe_update_capabilities(params)
    |> refresh_capability_flags()
  end

  defp maybe_update_capabilities(account, %{capabilities: capability_params}) when is_map(capability_params) do
    Map.put(account, :capabilities, Map.merge(account.capabilities, build_capabilities(capability_params)))
  end

  defp maybe_update_capabilities(account, _params), do: account

  defp refresh_capability_flags(account) do
    capabilities = Map.get(account, :capabilities, %{})
    transfers_active? = Map.get(capabilities, :transfers) == "active"
    card_payments_active? = Map.get(capabilities, :card_payments) == "active"

    account
    |> Map.put(:charges_enabled, card_payments_active?)
    |> Map.put(:payouts_enabled, transfers_active?)
    |> Map.put(:details_submitted, transfers_active? or card_payments_active?)
  end

  defp build_capabilities(params) when is_map(params) do
    requested =
      params
      |> Enum.map(fn {key, value} -> {normalize_capability_key(key), requested?(value)} end)
      |> Enum.filter(fn {key, _requested?} -> key in @capability_fields end)
      |> Map.new(fn {key, requested?} -> {key, if(requested?, do: "active", else: "inactive")} end)

    @capability_fields
    |> Map.new(&{&1, "inactive"})
    |> Map.merge(requested)
  end

  defp build_capabilities(_params), do: build_capabilities(%{})

  defp normalize_capability_key(key) when is_atom(key), do: key

  defp normalize_capability_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :unknown
  end

  defp requested?(%{requested: requested}), do: to_boolean(requested)
  defp requested?(%{"requested" => requested}), do: to_boolean(requested)
  defp requested?(requested), do: to_boolean(requested)

  defp build_controller(params) do
    controller = Map.get(params, :controller, %{})
    dashboard = Map.get(controller, :dashboard, %{})
    dashboard_type = Map.get(dashboard, :type) || Map.get(controller, :stripe_dashboard, %{})[:type]

    dashboard_type =
      cond do
        is_binary(dashboard_type) -> dashboard_type
        Map.get(params, :type, "custom") == "standard" -> "full"
        true -> "none"
      end

    %{
      dashboard: %{type: dashboard_type},
      fees: Map.get(controller, :fees, %{payer: "application"}),
      losses: Map.get(controller, :losses, %{payments: "application"}),
      requirement_collection: Map.get(controller, :requirement_collection, "application"),
      stripe_dashboard: %{type: dashboard_type}
    }
  end

  defp build_settings(params) do
    Map.merge(
      %{
        card_payments: %{decline_on: %{avs_failure: false, cvc_failure: false}},
        payouts: %{debit_negative_balances: true, schedule: %{interval: "daily"}, statement_descriptor: nil}
      },
      Map.get(params, :settings, %{})
    )
  end

  defp empty_requirements do
    %{
      alternatives: [],
      current_deadline: nil,
      currently_due: [],
      disabled_reason: nil,
      errors: [],
      eventually_due: [],
      past_due: [],
      pending_verification: []
    }
  end

  defp empty_nested_list(url) do
    %{data: [], has_more: false, object: "list", total_count: 0, url: url}
  end

  defp maybe_expand(account, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(account, expand_params)
  end
end
