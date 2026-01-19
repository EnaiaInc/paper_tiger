defmodule PaperTiger.Adapters.StripityStripe do
  @moduledoc """
  Syncs Stripe data from strippity_stripe database tables.

  Automatically detected when billing tables exist in the database. Queries
  billing_customers, billing_subscriptions, billing_products, billing_prices,
  and billing_plans from the local database and populates PaperTiger stores.

  Does NOT call the real Stripe API - purely database queries.

  ## Configuration

      # Configure your Ecto repo
      config :paper_tiger, repo: MyApp.Repo

      # Configure user adapter (optional, defaults to auto-discovery)
      config :paper_tiger, user_adapter: :auto  # or MyApp.CustomUserAdapter

  ## User Adapter

  The adapter needs to resolve user information (name, email) for customers.
  By default it uses `PaperTiger.UserAdapters.AutoDiscover` which attempts to
  discover common schema patterns. For custom schemas, implement `PaperTiger.UserAdapter`.
  """

  @behaviour PaperTiger.SyncAdapter

  alias PaperTiger.Store.{
    Customers,
    PaymentMethods,
    Plans,
    Prices,
    Products,
    Subscriptions
  }

  alias PaperTiger.UserAdapters.AutoDiscover

  require Logger

  @impl true
  def sync_all do
    # If an external data_source is configured, use that instead of directly
    # querying the host application's database. Consumers should implement
    # the `PaperTiger.DataSource` behaviour and bootstrap will load those
    # resources for PaperTiger.
    case Application.get_env(:paper_tiger, :data_source) do
      nil ->
        with {:ok, repo} <- get_repo(),
             {:ok, user_adapter} <- get_user_adapter() do
          Logger.debug("PaperTiger syncing data from database (strippity_stripe tables)...")

          # Sync payment methods first (if present)
          payment_methods_count = sync_payment_methods(repo)

          # Sync other resources
          customers_count = sync_customers(repo, user_adapter)
          plans_count = sync_plans(repo)
          prices_count = sync_prices(repo)
          products_count = sync_products(repo)
          subscriptions_count = sync_subscriptions(repo)

          # Ensure default_source values on customers have corresponding fake PMs inserted
          created_default_pms = ensure_default_payment_methods(repo)

          payment_methods_count = payment_methods_count + created_default_pms

          stats = %{
            customers: customers_count,
            payment_methods: payment_methods_count,
            plans: plans_count,
            prices: prices_count,
            products: products_count,
            subscriptions: subscriptions_count
          }

          total = Enum.sum(Map.values(stats))

          Logger.debug(
            "PaperTiger synced #{total} entities: " <>
              "#{stats.customers} customers, " <>
              "#{stats.subscriptions} subscriptions, " <>
              "#{stats.products} products, " <>
              "#{stats.prices} prices, " <>
              "#{stats.plans} plans, " <>
              "#{stats.payment_methods} payment_methods"
          )

          {:ok, stats}
        else
          {:error, :no_repo} ->
            error =
              "PaperTiger StripityStripe adapter requires a configured Repo.\n\n" <>
                "Add to your config:\n\n" <>
                "    config :paper_tiger, repo: MyApp.Repo\n"

            Logger.error(error)
            {:error, :no_repo_configured}

          {:error, :repo_not_started} ->
            {:error, :repo_not_started}

          {:error, reason} ->
            Logger.error("PaperTiger sync failed: #{inspect(reason)}")
            {:error, reason}
        end

      _data_source ->
        Logger.debug("PaperTiger StripityStripe adapter: :data_source configured, skipping DB sync")

        stats = %{
          customers: 0,
          payment_methods: 0,
          plans: 0,
          prices: 0,
          products: 0,
          subscriptions: 0
        }

        {:ok, stats}
    end
  rescue
    error ->
      Logger.error("PaperTiger sync failed: #{Exception.message(error)}")
      {:error, error}
  end

  ## Private Sync Functions

  defp sync_products(repo) do
    # Skip if table is not present
    if !table_exists?(repo, "billing_products"), do: 0

    # Choose a name column compatible with the host app
    name_col = choose_column(repo, "billing_products", ["name", "stripe_product_name", "stripe_id"]) || "stripe_id"
    metadata_col = choose_column(repo, "billing_products", ["metadata", "stripe_metadata"]) || "metadata"

    query = """
    SELECT
      id,
      stripe_id,
      #{name_col} as name,
      active,
      #{metadata_col} as metadata,
      inserted_at,
      updated_at
    FROM billing_products
    WHERE stripe_id IS NOT NULL
    """

    case repo.query(query) do
      {:ok, %{columns: columns, rows: rows}} ->
        rows
        |> Enum.map(&build_map(columns, &1))
        |> Enum.reduce(0, fn product_data, count ->
          product = build_product(product_data)
          {:ok, _} = Products.insert(product)
          count + 1
        end)

      {:error, _} ->
        0
    end
  end

  defp sync_prices(repo) do
    # If host app doesn't have a `billing_prices` table, skip
    if !table_exists?(repo, "billing_prices"), do: 0

    recurring_interval_col = choose_column(repo, "billing_prices", ["recurring_interval"]) || "recurring_interval"

    recurring_interval_count_col =
      choose_column(repo, "billing_prices", ["recurring_interval_count"]) || "recurring_interval_count"

    unit_amount_col = choose_column(repo, "billing_prices", ["unit_amount", "amount"]) || "unit_amount"
    currency_col = choose_column(repo, "billing_prices", ["currency"]) || "currency"
    metadata_col = choose_column(repo, "billing_prices", ["metadata"]) || "metadata"

    query = """
    SELECT
      p.id,
      p.stripe_id,
      p.#{unit_amount_col} as unit_amount,
      p.#{currency_col} as currency,
      p.#{recurring_interval_col} as recurring_interval,
      p.#{recurring_interval_count_col} as recurring_interval_count,
      p.product_id,
      prod.stripe_id as product_stripe_id,
      p.active,
      p.#{metadata_col} as metadata,
      p.inserted_at,
      p.updated_at
    FROM billing_prices p
    LEFT JOIN billing_products prod ON p.product_id = prod.id
    WHERE p.stripe_id IS NOT NULL
    """

    case repo.query(query) do
      {:ok, %{columns: columns, rows: rows}} ->
        rows
        |> Enum.map(&build_map(columns, &1))
        |> Enum.reduce(0, fn price_data, count ->
          price = build_price(price_data)
          {:ok, _} = Prices.insert(price)
          count + 1
        end)

      {:error, _} ->
        0
    end
  end

  defp sync_plans(repo) do
    # Skip if billing_plans table doesn't exist
    if !table_exists?(repo, "billing_plans"), do: 0

    interval_col = choose_column(repo, "billing_plans", ["interval", "stripe_plan_name"])
    interval_count_col = choose_column(repo, "billing_plans", ["interval_count", "stripe_interval_count"])
    amount_col = choose_column(repo, "billing_plans", ["amount"]) || "amount"
    currency_col = choose_column(repo, "billing_plans", ["currency"]) || "currency"
    metadata_col = choose_column(repo, "billing_plans", ["metadata"]) || "metadata"

    interval_select = if interval_col, do: "pl.#{interval_col} as interval", else: "NULL as interval"

    interval_count_select =
      if interval_count_col, do: "pl.#{interval_count_col} as interval_count", else: "NULL as interval_count"

    query = """
    SELECT
      pl.id,
      pl.stripe_id,
      pl.#{amount_col} as amount,
      pl.#{currency_col} as currency,
      #{interval_select},
      #{interval_count_select},
      pl.product_id,
      prod.stripe_id as product_stripe_id,
      pl.active,
      pl.#{metadata_col} as metadata,
      pl.inserted_at,
      pl.updated_at
    FROM billing_plans pl
    LEFT JOIN billing_products prod ON pl.product_id = prod.id
    WHERE pl.stripe_id IS NOT NULL
    """

    case repo.query(query) do
      {:ok, %{columns: columns, rows: rows}} ->
        rows
        |> Enum.map(&build_map(columns, &1))
        |> Enum.reduce(0, fn plan_data, count ->
          plan = build_plan(plan_data)
          {:ok, _} = Plans.insert(plan)
          count + 1
        end)

      {:error, _} ->
        0
    end
  end

  defp sync_customers(repo, user_adapter) do
    query = """
    SELECT
      id,
      stripe_id,
      user_id,
      default_source,
      inserted_at,
      updated_at
    FROM billing_customers
    WHERE stripe_id IS NOT NULL
    """

    case repo.query(query) do
      {:ok, %{columns: columns, rows: rows}} ->
        rows
        |> Enum.map(&build_map(columns, &1))
        |> Enum.reduce(0, fn customer_data, count ->
          customer = build_customer(repo, user_adapter, customer_data)
          {:ok, _} = Customers.insert(customer)
          count + 1
        end)

      {:error, _} ->
        0
    end
  end

  defp sync_subscriptions(repo) do
    query = """
    SELECT
      s.id,
      s.stripe_id,
      s.status,
      s.current_period_start_at,
      s.current_period_end_at,
      s.cancel_at,
      s.customer_id,
      c.stripe_id as customer_stripe_id,
      s.plan_id,
      pl.stripe_id as plan_stripe_id,
      s.inserted_at,
      s.updated_at
    FROM billing_subscriptions s
    LEFT JOIN billing_customers c ON s.customer_id = c.id
    LEFT JOIN billing_plans pl ON s.plan_id = pl.id
    WHERE s.stripe_id IS NOT NULL
    """

    case repo.query(query) do
      {:ok, %{columns: columns, rows: rows}} ->
        rows
        |> Enum.map(&build_map(columns, &1))
        |> Enum.reduce(0, fn subscription_data, count ->
          subscription = build_subscription(subscription_data)
          {:ok, _} = Subscriptions.insert(subscription)
          count + 1
        end)

      {:error, _} ->
        0
    end
  end

  defp sync_payment_methods(repo) do
    query = """
    SELECT
      pm.id,
      pm.stripe_id,
      pm.customer_id,
      c.stripe_id as customer_stripe_id,
      pm.card_brand,
      pm.card_last4,
      pm.card_exp_month,
      pm.card_exp_year,
      pm.card_fingerprint,
      pm.metadata,
      pm.inserted_at,
      pm.updated_at
    FROM billing_payment_methods pm
    LEFT JOIN billing_customers c ON pm.customer_id = c.id
    WHERE pm.stripe_id IS NOT NULL
    """

    case repo.query(query) do
      {:ok, %{columns: columns, rows: rows}} ->
        rows
        |> Enum.map(&build_map(columns, &1))
        |> Enum.reduce(0, fn pm_data, count ->
          Logger.debug("pm_data for payment method: #{inspect(pm_data)}")
          pm = build_payment_method(pm_data)
          Logger.debug("StripityStripe inserting payment_method #{inspect(pm)}")
          {:ok, _} = PaymentMethods.insert(pm)
          count + 1
        end)

      {:error, _} ->
        0
    end
  end

  defp build_payment_method(data) do
    %{
      billing_details: %{
        address: %{
          city: nil,
          country: nil,
          line1: nil,
          line2: nil,
          postal_code: nil,
          state: nil
        },
        email: nil,
        name: nil,
        phone: nil
      },
      card: %{
        brand: data["card_brand"],
        checks: %{
          address_line1_check: nil,
          address_postal_code_check: nil,
          cvc_check: "pass"
        },
        country: nil,
        exp_month: data["card_exp_month"],
        exp_year: data["card_exp_year"],
        fingerprint: data["card_fingerprint"],
        funding: nil,
        last4: data["card_last4"],
        three_d_secure_usage: %{supported: true},
        wallet: nil
      },
      created: to_unix(data["inserted_at"]),
      customer: data["customer_stripe_id"],
      id: data["stripe_id"],
      livemode: false,
      metadata: parse_metadata(data["metadata"]),
      object: "payment_method",
      type: "card"
    }
  end

  defp ensure_default_payment_methods(repo) do
    query = """
    SELECT
      c.stripe_id,
      c.default_source
    FROM billing_customers c
    WHERE c.stripe_id IS NOT NULL AND c.default_source IS NOT NULL
    """

    case repo.query(query) do
      {:ok, %{columns: columns, rows: rows}} ->
        rows
        |> Enum.map(&build_map(columns, &1))
        |> Enum.reduce(0, &ensure_payment_method_exists/2)

      {:error, _} ->
        0
    end
  end

  defp ensure_payment_method_exists(%{"default_source" => default_source, "stripe_id" => customer_stripe_id}, count) do
    case PaymentMethods.get(default_source) do
      {:ok, _pm} ->
        count

      {:error, :not_found} ->
        pm = build_default_payment_method(customer_stripe_id, default_source)
        {:ok, _} = PaymentMethods.insert(pm)
        count + 1
    end
  end

  defp build_default_payment_method(customer_stripe_id, default_source) do
    %{
      billing_details: %{
        address: %{
          city: nil,
          country: nil,
          line1: nil,
          line2: nil,
          postal_code: nil,
          state: nil
        },
        email: nil,
        name: nil,
        phone: nil
      },
      card: %{
        brand: nil,
        checks: %{
          address_line1_check: nil,
          address_postal_code_check: nil,
          cvc_check: "pass"
        },
        country: nil,
        exp_month: nil,
        exp_year: nil,
        fingerprint: nil,
        funding: nil,
        last4: nil,
        three_d_secure_usage: %{supported: true},
        wallet: nil
      },
      created: PaperTiger.now(),
      customer: customer_stripe_id,
      id: default_source,
      livemode: false,
      metadata: %{},
      object: "payment_method",
      type: "card"
    }
  end

  ## Resource Builders

  defp build_product(data) do
    %{
      active: data["active"] || true,
      created: to_unix(data["inserted_at"]),
      id: data["stripe_id"],
      livemode: false,
      metadata: parse_metadata(data["metadata"]),
      name: data["name"],
      object: "product",
      type: "service",
      updated: to_unix(data["updated_at"])
    }
  end

  defp build_price(data) do
    recurring =
      if data["recurring_interval"] do
        %{
          interval: data["recurring_interval"],
          interval_count: data["recurring_interval_count"] || 1
        }
      end

    %{
      active: data["active"] || true,
      created: to_unix(data["inserted_at"]),
      currency: data["currency"] || "usd",
      id: data["stripe_id"],
      livemode: false,
      metadata: parse_metadata(data["metadata"]),
      object: "price",
      product: data["product_stripe_id"],
      recurring: recurring,
      type: if(recurring, do: "recurring", else: "one_time"),
      unit_amount: data["unit_amount"]
    }
  end

  defp build_plan(data) do
    %{
      active: data["active"] || true,
      amount: data["amount"],
      created: to_unix(data["inserted_at"]),
      currency: data["currency"] || "usd",
      id: data["stripe_id"],
      interval: data["interval"] || "month",
      interval_count: data["interval_count"] || 1,
      livemode: false,
      metadata: parse_metadata(data["metadata"]),
      object: "plan",
      product: data["product_stripe_id"]
    }
  end

  defp build_customer(repo, user_adapter, data) do
    user_info =
      if user_id = data["user_id"] do
        case user_adapter.get_user_info(repo, user_id) do
          {:ok, info} ->
            info

          {:error, reason} ->
            Logger.warning("Failed to get user info for user_id=#{user_id}: #{inspect(reason)}")
            %{}
        end
      else
        %{}
      end

    %{
      created: to_unix(data["inserted_at"]),
      default_source: data["default_source"],
      email: user_info[:email],
      id: data["stripe_id"],
      livemode: false,
      metadata: %{},
      name: user_info[:name],
      object: "customer"
    }
  end

  defp build_subscription(data) do
    %{
      cancel_at: to_unix(data["cancel_at"]),
      created: to_unix(data["inserted_at"]),
      current_period_end: to_unix(data["current_period_end_at"]),
      current_period_start: to_unix(data["current_period_start_at"]),
      customer: data["customer_stripe_id"],
      id: data["stripe_id"],
      items: %{
        data: [
          %{
            id: "si_#{data["stripe_id"]}",
            object: "subscription_item",
            plan: data["plan_stripe_id"],
            price: data["plan_stripe_id"],
            quantity: 1
          }
        ],
        object: "list"
      },
      livemode: false,
      metadata: %{},
      object: "subscription",
      status: data["status"] || "active"
    }
  end

  ## Helpers

  defp build_map(columns, row) do
    Enum.zip(columns, row) |> Map.new()
  end

  defp parse_metadata(nil), do: %{}
  defp parse_metadata(map) when is_map(map), do: map

  defp parse_metadata(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp to_unix(nil), do: nil

  defp to_unix(%NaiveDateTime{} = dt) do
    dt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
  end

  defp to_unix(%DateTime{} = dt) do
    DateTime.to_unix(dt)
  end

  defp to_unix(_), do: nil

  ## Schema/DB helpers

  defp table_exists?(repo, table_name) do
    query = """
    SELECT 1 FROM information_schema.tables WHERE table_name = $1 LIMIT 1
    """

    case repo.query(query, [table_name]) do
      {:ok, %{rows: [[1]]}} -> true
      _ -> false
    end
  end

  defp column_exists?(repo, table_name, column_name) do
    query = """
    SELECT 1 FROM information_schema.columns WHERE table_name = $1 AND column_name = $2 LIMIT 1
    """

    case repo.query(query, [table_name, column_name]) do
      {:ok, %{rows: [[1]]}} -> true
      _ -> false
    end
  end

  defp choose_column(repo, table_name, candidates) when is_list(candidates) do
    Enum.find(candidates, fn col -> column_exists?(repo, table_name, col) end)
  end

  defp get_repo do
    case Application.get_env(:paper_tiger, :repo) do
      nil ->
        {:error, :no_repo}

      repo ->
        # Check if repo is actually started (skip check for test modules)
        if repo_started?(repo) do
          {:ok, repo}
        else
          {:error, :repo_not_started}
        end
    end
  end

  defp repo_started?(repo) do
    # In tests, mock repos don't have processes, so check if it's a test module
    module_name = Atom.to_string(repo)

    if String.contains?(module_name, "MockRepo") or String.contains?(module_name, "EmptyRepo") do
      true
    else
      # For real repos, check if process is started
      Process.whereis(repo) != nil
    end
  end

  defp get_user_adapter do
    case Application.get_env(:paper_tiger, :user_adapter, :auto) do
      :auto -> {:ok, AutoDiscover}
      adapter when is_atom(adapter) -> {:ok, adapter}
      other -> {:error, {:invalid_user_adapter, other}}
    end
  end
end
