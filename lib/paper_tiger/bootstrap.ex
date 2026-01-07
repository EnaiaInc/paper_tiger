defmodule PaperTiger.Bootstrap do
  @moduledoc """
  Bootstrap a worker to handle sync after start up.
  """
  use GenServer

  alias PaperTiger.Store.{Prices, Customers, Products, Plans, Subscriptions, PaymentMethods, SubscriptionItems}

  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @enable_bootstrap? Application.compile_env(:paper_tiger, :enable_bootstrap, false)
  @impl true
  def init(:ok) do
    if @enable_bootstrap? do
      send(self(), :bootstrap)
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:bootstrap, state) do
    Logger.info("PaperTiger bootstrap starting")

    wait_for_repo!()

    load_test_tokens()
    load_from_data_source()
    load_init_data()
    register_configured_webhooks()

    Logger.info("PaperTiger bootstrap complete")
    {:noreply, state}
  end

  defp wait_for_repo! do
    repo = Application.fetch_env!(:paper_tiger, :repo)

    Stream.repeatedly(fn ->
      try do
        repo.query!("SELECT 1")
        :ok
      rescue
        _ ->
          Process.sleep(200)
          :error
      end
    end)
    |> Enum.find(&(&1 == :ok))
  end

  ## Private Functions

  # Loads pre-defined Stripe test tokens (pm_card_visa, tok_visa, etc.)
  defp load_test_tokens do
    {:ok, _stats} = PaperTiger.TestTokens.load()
    :ok
  end

  # Loads data from configured data_source (if any)
  defp load_from_data_source do
    case Application.get_env(:paper_tiger, :data_source) do
      nil ->
        :ok

      source ->
        # Ensure the module is loaded before checking for exported functions
        Code.ensure_loaded(source)

        # Helper to call loader and insert into a store
        insert_resources = fn function, store, label ->
          if function_exported?(source, function, 0) do
            try do
              resources = apply(source, function, [])

              if is_list(resources) do
                Enum.each(resources, fn resource ->
                  try do
                    apply(store, :insert, [resource])
                  rescue
                    e -> Logger.warning("Failed to insert #{label} from data_source: #{inspect(e)}")
                  end
                end)

                Logger.info("PaperTiger loaded #{length(resources)} #{label} from data_source")
              else
                Logger.warning("data_source.#{function}/0 returned non-list: #{inspect(resources)}")
              end
            rescue
              e -> Logger.warning("data_source.#{function}/0 raised: #{inspect(e)}")
            end
          end
        end

        insert_resources.(:load_prices, Prices, "prices")
        insert_resources.(:load_products, Products, "products")
        insert_resources.(:load_plans, Plans, "plans")
        insert_resources.(:load_customers, Customers, "customers")
        insert_resources.(:load_subscriptions, Subscriptions, "subscriptions")
        insert_resources.(:load_subscription_items, SubscriptionItems, "subscription_items")
        insert_resources.(:load_payment_methods, PaymentMethods, "payment_methods")

        :ok
    end
  end

  # Loads init_data if configured
  defp load_init_data do
    case PaperTiger.Initializer.load() do
      {:ok, _stats} -> :ok
      {:error, reason} -> Logger.warning("PaperTiger init_data failed: #{inspect(reason)}")
    end
  end

  # Registers webhooks from application config
  defp register_configured_webhooks do
    PaperTiger.register_configured_webhooks()
  end
end
