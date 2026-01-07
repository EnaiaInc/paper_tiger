defmodule PaperTiger.SyncAdapter do
  @moduledoc """
  Behavior for syncing Stripe data into PaperTiger stores.

  Adapters fetch data from external sources (typically real Stripe) and populate
  PaperTiger's ETS stores. This allows dev/PR environments to restore state on
  restart instead of losing all customer/subscription data.

  ## Built-in Adapters

  - `PaperTiger.Adapters.StripityStripe` - Auto-detected, syncs from Stripe API
  - Custom adapters - Implement this behavior for custom data sources

  ## Configuration

      # Auto-detected (default) - uses StripityStripe if available
      config :paper_tiger, sync_adapter: :auto

      # Disable sync
      config :paper_tiger, sync_adapter: nil

      # Custom adapter
      config :paper_tiger, sync_adapter: MyApp.CustomAdapter

  ## Implementing a Custom Adapter

      defmodule MyApp.CustomAdapter do
        @behaviour PaperTiger.SyncAdapter

        @impl true
        def sync_all do
          # Fetch data from your source
          customers = MyApp.Repo.all(MyApp.Customer)

          # Convert to Stripe format and insert
          Enum.each(customers, fn customer ->
            stripe_customer = %{
              id: customer.stripe_id,
              email: customer.email,
              name: customer.name,
              # ... other Stripe fields
            }
            PaperTiger.Store.Customers.insert(stripe_customer)
          end)

          {:ok, %{customers: length(customers)}}
        end
      end
  """

  @doc """
  Syncs all Stripe entities into PaperTiger stores.

  Should fetch data from external source and insert into appropriate stores.
  Returns `{:ok, stats}` with counts of synced entities, or `{:error, reason}`.

  ## Return Format

      {:ok, %{
        customers: 150,
        subscriptions: 45,
        products: 12,
        prices: 24,
        payment_methods: 78
      }}
  """
  @callback sync_all() :: {:ok, stats :: map()} | {:error, term()}
end
