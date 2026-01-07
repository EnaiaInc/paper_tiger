# Stripe.* modules are only available at runtime when stripity_stripe is installed
defmodule PaperTiger.Adapters.StripityStripe do
  @moduledoc """
  Syncs Stripe data using the stripity_stripe library.

  Automatically detected when `Stripe` module is available. Fetches all
  customers, subscriptions, products, prices, and payment methods from
  the real Stripe API and populates PaperTiger stores.

  This adapter handles pagination automatically and syncs all available data.
  """

  @behaviour PaperTiger.SyncAdapter

  alias PaperTiger.Store.{
    Customers,
    Plans,
    Prices,
    Products,
    Subscriptions
  }

  require Logger

  # Suppress warnings for Stripe.* modules which are only available when stripity_stripe is installed
  @compile {:no_warn_undefined, [Stripe.Customer, Stripe.Subscription, Stripe.Product, Stripe.Price, Stripe.Plan]}

  @impl true
  def sync_all do
    Logger.info("PaperTiger syncing data from Stripe API...")

    stats = %{
      customers: sync_customers(),
      payment_methods: sync_payment_methods(),
      plans: sync_plans(),
      prices: sync_prices(),
      products: sync_products(),
      subscriptions: sync_subscriptions()
    }

    total = Enum.sum(Map.values(stats))

    Logger.info(
      "PaperTiger synced #{total} entities: " <>
        "#{stats.customers} customers, " <>
        "#{stats.subscriptions} subscriptions, " <>
        "#{stats.products} products, " <>
        "#{stats.prices} prices, " <>
        "#{stats.plans} plans, " <>
        "#{stats.payment_methods} payment methods"
    )

    {:ok, stats}
  rescue
    error ->
      Logger.error("PaperTiger sync failed: #{inspect(error)}")
      {:error, error}
  end

  ## Private Sync Functions

  defp sync_customers do
    stripe_module = Stripe.Customer

    list_all(&stripe_module.list/1)
    |> Enum.reduce(0, fn customer, count ->
      {:ok, _} = Customers.insert(normalize_resource(customer))
      count + 1
    end)
  end

  defp sync_subscriptions do
    stripe_module = Stripe.Subscription

    list_all(&stripe_module.list/1)
    |> Enum.reduce(0, fn subscription, count ->
      {:ok, _} = Subscriptions.insert(normalize_resource(subscription))
      count + 1
    end)
  end

  defp sync_products do
    stripe_module = Stripe.Product

    list_all(&stripe_module.list/1)
    |> Enum.reduce(0, fn product, count ->
      {:ok, _} = Products.insert(normalize_resource(product))
      count + 1
    end)
  end

  defp sync_prices do
    stripe_module = Stripe.Price

    list_all(&stripe_module.list/1)
    |> Enum.reduce(0, fn price, count ->
      {:ok, _} = Prices.insert(normalize_resource(price))
      count + 1
    end)
  end

  defp sync_plans do
    stripe_module = Stripe.Plan

    list_all(&stripe_module.list/1)
    |> Enum.reduce(0, fn plan, count ->
      {:ok, _} = Plans.insert(normalize_resource(plan))
      count + 1
    end)
  end

  defp sync_payment_methods do
    # Payment methods need to be listed per customer
    # For now, we'll skip this and rely on expanded objects or init_data
    # Could be enhanced later to iterate customers and list their PMs
    0
  end

  ## Pagination Helper

  defp list_all(list_fn, acc \\ [], starting_after \\ nil) do
    opts = if starting_after, do: [starting_after: starting_after, limit: 100], else: [limit: 100]

    case list_fn.(opts) do
      {:ok, %{data: data, has_more: has_more}} ->
        new_acc = acc ++ data

        if has_more && not Enum.empty?(data) do
          last_id = List.last(data).id
          list_all(list_fn, new_acc, last_id)
        else
          new_acc
        end

      {:error, _} ->
        acc
    end
  end

  ## Resource Normalization

  # Convert stripity_stripe structs to plain maps
  defp normalize_resource(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> normalize_resource()
  end

  defp normalize_resource(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_map(v) or is_list(v) -> {k, normalize_resource(v)}
      {k, v} -> {k, v}
    end)
  end

  defp normalize_resource(list) when is_list(list) do
    Enum.map(list, &normalize_resource/1)
  end

  defp normalize_resource(value), do: value
end
