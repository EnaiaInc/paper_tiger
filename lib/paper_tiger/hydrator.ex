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

  @doc """
  Hydrates a resource by expanding specified fields.

  ## Parameters

  - `resource` - The struct to hydrate
  - `expand_params` - List of paths to expand (e.g., ["customer", "customer.default_source"])

  ## Examples

      subscription = %{customer: "cus_123", ...}
      PaperTiger.Hydrator.hydrate(subscription, ["customer"])
      # => %{customer: %{id: "cus_123", email: "...", ...}, ...}
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

  Uses ID prefix to determine which store to query:
  - `cus_*` -> Customers
  - `sub_*` -> Subscriptions
  - `pm_*` -> PaymentMethods
  - etc.
  """
  @spec fetch_by_id(String.t()) :: {:ok, map()} | {:error, :not_found | :unknown_prefix}
  def fetch_by_id("cus_" <> _rest = id) do
    Customers.get(id)
  end

  def fetch_by_id("sub_" <> _rest = id), do: Subscriptions.get(id)
  def fetch_by_id("si_" <> _rest = id), do: SubscriptionItems.get(id)
  def fetch_by_id("in_" <> _rest = id), do: Invoices.get(id)
  def fetch_by_id("ii_" <> _rest = id), do: InvoiceItems.get(id)
  def fetch_by_id("pm_" <> _rest = id), do: PaymentMethods.get(id)
  def fetch_by_id("pi_" <> _rest = id), do: PaymentIntents.get(id)
  def fetch_by_id("seti_" <> _rest = id), do: SetupIntents.get(id)
  def fetch_by_id("ch_" <> _rest = id), do: Charges.get(id)
  def fetch_by_id("re_" <> _rest = id), do: Refunds.get(id)
  def fetch_by_id("prod_" <> _rest = id), do: Products.get(id)
  def fetch_by_id("price_" <> _rest = id), do: Prices.get(id)

  def fetch_by_id("plan_" <> _rest = id), do: Plans.get(id)
  def fetch_by_id("card_" <> _rest = id), do: Cards.get(id)
  def fetch_by_id("ba_" <> _rest = id), do: BankAccounts.get(id)
  def fetch_by_id("src_" <> _rest = id), do: Sources.get(id)
  def fetch_by_id("tok_" <> _rest = id), do: Tokens.get(id)
  def fetch_by_id("txr_" <> _rest = id), do: TaxRates.get(id)
  def fetch_by_id("coupon_" <> _rest = id), do: Coupons.get(id)
  def fetch_by_id("txn_" <> _rest = id), do: BalanceTransactions.get(id)

  def fetch_by_id("po_" <> _rest = id), do: Payouts.get(id)
  def fetch_by_id("cs_" <> _rest = id), do: CheckoutSessions.get(id)
  def fetch_by_id("evt_" <> _rest = id), do: Events.get(id)
  def fetch_by_id("whsec_" <> _rest = id), do: Webhooks.get(id)
  def fetch_by_id("dp_" <> _rest = id), do: Disputes.get(id)
  def fetch_by_id("fee_" <> _rest = id), do: ApplicationFees.get(id)
  def fetch_by_id("prv_" <> _rest = id), do: Reviews.get(id)
  def fetch_by_id("tu_" <> _rest = id), do: Topups.get(id)

  def fetch_by_id(id) do
    Logger.debug("Hydrator: unknown ID prefix for expansion: #{id}")
    {:error, :unknown_prefix}
  end
end
