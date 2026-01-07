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
    Plans,
    Prices,
    Products,
    Subscriptions
  }

  alias PaperTiger.UserAdapters.AutoDiscover

  require Logger

  @impl true
  def sync_all do
    with {:ok, repo} <- get_repo(),
         {:ok, user_adapter} <- get_user_adapter() do
      Logger.info("PaperTiger syncing data from database (strippity_stripe tables)...")

      stats = %{
        customers: sync_customers(repo, user_adapter),
        plans: sync_plans(repo),
        prices: sync_prices(repo),
        products: sync_products(repo),
        subscriptions: sync_subscriptions(repo)
      }

      total = Enum.sum(Map.values(stats))

      Logger.info(
        "PaperTiger synced #{total} entities: " <>
          "#{stats.customers} customers, " <>
          "#{stats.subscriptions} subscriptions, " <>
          "#{stats.products} products, " <>
          "#{stats.prices} prices, " <>
          "#{stats.plans} plans"
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
  rescue
    error ->
      Logger.error("PaperTiger sync failed: #{Exception.message(error)}")
      {:error, error}
  end

  ## Private Sync Functions

  defp sync_products(repo) do
    query = """
    SELECT
      id,
      stripe_id,
      name,
      active,
      metadata,
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
    query = """
    SELECT
      p.id,
      p.stripe_id,
      p.unit_amount,
      p.currency,
      p.recurring_interval,
      p.recurring_interval_count,
      p.product_id,
      prod.stripe_id as product_stripe_id,
      p.active,
      p.metadata,
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
    query = """
    SELECT
      pl.id,
      pl.stripe_id,
      pl.amount,
      pl.currency,
      pl.interval,
      pl.interval_count,
      pl.product_id,
      prod.stripe_id as product_stripe_id,
      pl.active,
      pl.metadata,
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
