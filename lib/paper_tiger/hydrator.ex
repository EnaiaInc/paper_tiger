defmodule PaperTiger.Hydrator do
  @moduledoc """
  Expands nested object references based on `expand[]` query parameters.

  Stripe allows expanding related objects in responses. Instead of returning
  just an ID, the full object is returned.

  ## Examples

      # Without expansion
      %Subscription{customer: "cus_123"}

      # With expand[]=customer
      %Subscription{customer: %Customer{id: "cus_123", email: "..."}}

      # Nested expansion: expand[]=customer.default_source
      %Subscription{
        customer: %Customer{
          id: "cus_123",
          default_source: %Card{id: "card_123", last4: "4242"}
        }
      }

  ## Usage

      # In resource handlers
      expand_params = parse_expand_params(conn.query_params)
      hydrated = PaperTiger.Hydrator.hydrate(subscription, expand_params)
  """

  alias PaperTiger.Store.ApplicationFees
  alias PaperTiger.Store.BalanceTransactions
  alias PaperTiger.Store.BankAccounts
  alias PaperTiger.Store.Cards
  alias PaperTiger.Store.Charges
  alias PaperTiger.Store.CheckoutSessions
  alias PaperTiger.Store.Coupons
  alias PaperTiger.Store.Customers
  alias PaperTiger.Store.Disputes
  alias PaperTiger.Store.Events
  alias PaperTiger.Store.InvoiceItems
  alias PaperTiger.Store.Invoices
  alias PaperTiger.Store.PaymentIntents
  alias PaperTiger.Store.PaymentMethods
  alias PaperTiger.Store.Payouts
  alias PaperTiger.Store.Plans
  alias PaperTiger.Store.Prices
  alias PaperTiger.Store.Products
  alias PaperTiger.Store.Refunds
  alias PaperTiger.Store.Reviews
  alias PaperTiger.Store.SetupIntents
  alias PaperTiger.Store.Sources
  alias PaperTiger.Store.SubscriptionItems
  alias PaperTiger.Store.Subscriptions
  alias PaperTiger.Store.TaxRates
  alias PaperTiger.Store.Tokens
  alias PaperTiger.Store.Topups
  alias PaperTiger.Store.Webhooks

  require Logger

  @stores [
    ApplicationFees,
    BalanceTransactions,
    BankAccounts,
    Cards,
    Charges,
    CheckoutSessions,
    Coupons,
    Customers,
    Disputes,
    Events,
    InvoiceItems,
    Invoices,
    PaymentIntents,
    PaymentMethods,
    Payouts,
    Plans,
    Prices,
    Products,
    Refunds,
    Reviews,
    SetupIntents,
    Sources,
    SubscriptionItems,
    Subscriptions,
    TaxRates,
    Tokens,
    Topups,
    Webhooks
  ]

  # Map of "prefix_" to store module
  @prefix_registry Map.new(@stores, fn module ->
                     {"#{module.prefix()}_", module}
                   end)

  @doc """
  Hydrates a resource by expanding specified fields.
  ...
  """
  @spec hydrate(map() | struct(), [String.t()]) :: map() | struct()
  def hydrate(resource, expand_params) when is_list(expand_params) do
    Enum.reduce(expand_params, resource, fn path, acc ->
      expand_path(acc, String.split(path, "."))
    end)
  end

  def hydrate(resource, _), do: resource

  ## Private Functions

  # Single field expansion: expand[]=customer
  defp expand_path(resource, [field]) when is_map(resource) do
    field_atom = String.to_existing_atom(field)

    case Map.get(resource, field_atom) do
      id when is_binary(id) and byte_size(id) > 0 ->
        case fetch_by_id(id) do
          {:ok, expanded} ->
            Map.put(resource, field_atom, expanded)

          {:error, :not_found} ->
            Logger.debug("Hydrator: could not expand #{field}=#{id} (not found)")
            resource

          {:error, :unknown_prefix} ->
            Logger.debug("Hydrator: could not expand #{field}=#{id} (unknown prefix)")
            resource
        end

      _not_expandable ->
        resource
    end
  rescue
    ArgumentError ->
      # Field doesn't exist as atom, skip expansion
      Logger.debug("Hydrator: unknown field '#{field}' for expansion")
      resource
  end

  # Nested expansion: expand[]=customer.default_source
  defp expand_path(resource, [field | rest]) when is_map(resource) do
    field_atom = String.to_existing_atom(field)

    case Map.get(resource, field_atom) do
      id when is_binary(id) ->
        # Fetch and expand nested path
        case fetch_by_id(id) do
          {:ok, expanded} ->
            nested = expand_path(expanded, rest)
            Map.put(resource, field_atom, nested)

          {:error, :not_found} ->
            resource

          {:error, :unknown_prefix} ->
            resource
        end

      already_expanded when is_map(already_expanded) ->
        # Field is already expanded, continue with nested expansion
        nested = expand_path(already_expanded, rest)
        Map.put(resource, field_atom, nested)

      _other ->
        resource
    end
  rescue
    ArgumentError ->
      Logger.debug("Hydrator: unknown field '#{field}' for nested expansion")
      resource
  end

  defp expand_path(resource, []), do: resource

  @doc """
  Fetches a resource by ID from the appropriate store.

  Automatically determines the correct store based on the ID prefix.
  """
  @spec fetch_by_id(String.t()) :: {:ok, map()} | {:error, :not_found | :unknown_prefix}
  def fetch_by_id(id) when is_binary(id) do
    case String.split(id, "_", parts: 2) do
      [prefix, _rest] -> lookup_store_and_fetch(prefix, id)
      _ -> {:error, :unknown_prefix}
    end
  end

  defp lookup_store_and_fetch("whsec", id), do: Webhooks.get(id)

  defp lookup_store_and_fetch(prefix, id) do
    case Map.get(@prefix_registry, "#{prefix}_") do
      nil ->
        Logger.debug("Hydrator: unknown ID prefix for expansion: #{id}")
        {:error, :unknown_prefix}

      module ->
        module.get(id)
    end
  end
end
