defmodule PaperTiger.Initializer do
  @moduledoc """
  Loads initial data into PaperTiger stores on startup.

  ## Configuration

  Configure initial data in your application config:

      # From a JSON file
      config :paper_tiger,
        init_data: "/path/to/stripe_init_data.json"

      # Or inline as a map
      config :paper_tiger,
        init_data: %{
          products: [
            %{
              id: "prod_test_standard",
              name: "Standard Plan",
              active: true,
              metadata: %{credits: "100"}
            }
          ],
          prices: [
            %{
              id: "price_test_standard_monthly",
              product: "prod_test_standard",
              unit_amount: 4900,
              currency: "usd",
              recurring: %{interval: "month", interval_count: 1}
            }
          ]
        }

  Initial data is loaded after PaperTiger's ETS stores are initialized,
  making the data available immediately when your application starts.
  Since ETS is ephemeral, this runs on every application start.

  ## Custom IDs

  Use custom IDs to ensure deterministic, reproducible data across
  application restarts. IDs must match Stripe's format:

  - Products: `prod_*`
  - Prices: `price_*`
  - Customers: `cus_*`
  - etc.
  """

  alias PaperTiger.Store.Customers
  alias PaperTiger.Store.Plans
  alias PaperTiger.Store.Prices
  alias PaperTiger.Store.Products

  require Logger

  @doc """
  Loads initial data from configuration.

  Called automatically during PaperTiger application startup if `init_data`
  is configured. Can also be called manually to reload data.

  Returns `{:ok, stats}` with counts of loaded entities, or `{:error, reason}`.
  """
  @spec load() :: {:ok, map()} | {:error, term()}
  def load do
    case Application.get_env(:paper_tiger, :init_data) do
      nil ->
        {:ok, %{message: "No init_data configured"}}

      path when is_binary(path) ->
        load_from_file(path)

      data when is_map(data) ->
        load_from_map(data)

      other ->
        {:error, {:invalid_init_data_config, other}}
    end
  end

  @doc """
  Loads initial data from a JSON file.

  Paths starting with `priv/` are automatically resolved by searching all
  loaded applications' priv directories. This allows configurations like
  `init_data: "priv/paper_tiger/init_data.json"` to work both in development
  (relative to project root) and in releases (where the file is in the host
  application's priv directory).
  """
  @spec load_from_file(String.t()) :: {:ok, map()} | {:error, term()}
  def load_from_file(path) do
    resolved_path = resolve_priv_path(path)

    with {:ok, contents} <- File.read(resolved_path),
         {:ok, data} <- decode_json(contents) do
      load_from_map(data)
    else
      {:error, reason} ->
        Logger.warning("PaperTiger failed to load init_data file: #{inspect(reason)}")
        {:error, {:init_data_file_error, reason}}
    end
  end

  @doc """
  Loads initial data from a map.

  ## Expected Format

      %{
        "products" => [...] or products: [...],
        "prices" => [...] or prices: [...],
        "customers" => [...] or customers: [...]
      }
  """
  @spec load_from_map(map()) :: {:ok, map()} | {:error, term()}
  def load_from_map(data) do
    stats = %{
      customers: load_customers(get_list(data, :customers)),
      plans: load_plans(get_list(data, :plans)),
      prices: load_prices(get_list(data, :prices)),
      products: load_products(get_list(data, :products))
    }

    total = stats.products + stats.prices + stats.plans + stats.customers

    if total > 0 do
      Logger.info(
        "PaperTiger loaded init_data: #{total} entities (#{stats.products} products, #{stats.prices} prices, #{stats.plans} plans, #{stats.customers} customers)"
      )
    end

    {:ok, stats}
  end

  ## Private Functions

  # Resolves paths starting with "priv/" by searching all loaded applications'
  # priv directories. This handles the case where init_data is configured as
  # "priv/paper_tiger/init_data.json" which works in dev (relative to project
  # root) but fails in releases where the working directory is different.
  defp resolve_priv_path("priv/" <> rest = original_path) do
    if File.exists?(original_path) do
      original_path
    else
      search_app_priv_dirs(rest) || original_path
    end
  end

  defp resolve_priv_path(path), do: path

  defp search_app_priv_dirs(relative_path) do
    :application.loaded_applications()
    |> Enum.find_value(fn {app, _, _} -> find_in_app_priv(app, relative_path) end)
  end

  defp find_in_app_priv(app, relative_path) do
    case :code.priv_dir(app) do
      {:error, _} ->
        nil

      priv_dir ->
        full_path = Path.join(to_string(priv_dir), relative_path)

        if File.exists?(full_path) do
          Logger.debug("PaperTiger resolved priv path via #{app}: #{full_path}")
          full_path
        end
    end
  end

  defp decode_json(contents) do
    # Try built-in JSON first (Elixir 1.18+), fall back to Jason
    cond do
      Code.ensure_loaded?(JSON) and function_exported?(JSON, :decode, 1) ->
        JSON.decode(contents)

      Code.ensure_loaded?(Jason) ->
        Jason.decode(contents)

      true ->
        {:error, :no_json_library}
    end
  end

  defp get_list(data, key) do
    # Support both atom and string keys
    Map.get(data, key) || Map.get(data, to_string(key)) || []
  end

  defp load_products(products) do
    Enum.reduce(products, 0, fn product_data, count ->
      product = build_product(product_data)
      {:ok, _product} = Products.insert(product)
      count + 1
    end)
  end

  defp load_prices(prices) do
    Enum.reduce(prices, 0, fn price_data, count ->
      price = build_price(price_data)
      {:ok, _price} = Prices.insert(price)
      count + 1
    end)
  end

  defp load_plans(plans) do
    Enum.reduce(plans, 0, fn plan_data, count ->
      plan = build_plan(plan_data)
      {:ok, _plan} = Plans.insert(plan)
      count + 1
    end)
  end

  defp load_customers(customers) do
    Enum.reduce(customers, 0, fn customer_data, count ->
      customer = build_customer(customer_data)
      {:ok, _customer} = Customers.insert(customer)
      count + 1
    end)
  end

  defp build_product(data) do
    %{
      active: get_field(data, :active, true),
      attributes: get_field(data, :attributes, []),
      caption: get_field(data, :caption),
      created: PaperTiger.now(),
      description: get_field(data, :description),
      id: get_field(data, :id) || PaperTiger.Resource.generate_id("prod"),
      images: get_field(data, :images, []),
      livemode: false,
      metadata: atomize_keys(get_field(data, :metadata, %{})),
      name: get_field(data, :name),
      object: "product",
      package_dimensions: get_field(data, :package_dimensions),
      shippable: get_field(data, :shippable),
      statement_descriptor: get_field(data, :statement_descriptor),
      type: "service",
      unit_label: get_field(data, :unit_label),
      updated: PaperTiger.now(),
      url: get_field(data, :url)
    }
  end

  defp build_price(data) do
    recurring = get_field(data, :recurring)

    %{
      active: get_field(data, :active, true),
      billing_scheme: get_field(data, :billing_scheme, "per_unit"),
      created: PaperTiger.now(),
      currency: get_field(data, :currency),
      id: get_field(data, :id) || PaperTiger.Resource.generate_id("price"),
      livemode: false,
      lookup_key: get_field(data, :lookup_key),
      metadata: atomize_keys(get_field(data, :metadata, %{})),
      nickname: get_field(data, :nickname),
      object: "price",
      product: get_field(data, :product),
      recurring: atomize_keys(recurring),
      tax_behavior: get_field(data, :tax_behavior, "unspecified"),
      tiers: get_field(data, :tiers),
      tiers_mode: get_field(data, :tiers_mode),
      transform_quantity: get_field(data, :transform_quantity),
      type: if(recurring, do: "recurring", else: "one_time"),
      unit_amount: get_field(data, :unit_amount),
      unit_amount_decimal: get_field(data, :unit_amount_decimal)
    }
  end

  defp build_plan(data) do
    %{
      active: get_field(data, :active, true),
      aggregate_usage: get_field(data, :aggregate_usage),
      amount: get_field(data, :amount),
      billing_scheme: get_field(data, :billing_scheme, "per_unit"),
      created: PaperTiger.now(),
      currency: get_field(data, :currency),
      id: get_field(data, :id) || PaperTiger.Resource.generate_id("plan"),
      interval: get_field(data, :interval),
      interval_count: get_field(data, :interval_count, 1),
      livemode: false,
      metadata: atomize_keys(get_field(data, :metadata, %{})),
      nickname: get_field(data, :nickname),
      object: "plan",
      product: get_field(data, :product),
      tiers: get_field(data, :tiers),
      tiers_mode: get_field(data, :tiers_mode),
      transform_usage: get_field(data, :transform_usage),
      trial_period_days: get_field(data, :trial_period_days),
      usage_type: get_field(data, :usage_type, "licensed")
    }
  end

  defp build_customer(data) do
    %{
      address: get_field(data, :address),
      balance: get_field(data, :balance, 0),
      created: PaperTiger.now(),
      currency: get_field(data, :currency),
      default_source: get_field(data, :default_source),
      deleted: nil,
      delinquent: false,
      description: get_field(data, :description),
      email: get_field(data, :email),
      id: get_field(data, :id) || PaperTiger.Resource.generate_id("cus"),
      invoice_prefix: get_field(data, :invoice_prefix),
      invoice_settings: get_field(data, :invoice_settings, %{}),
      livemode: false,
      metadata: atomize_keys(get_field(data, :metadata, %{})),
      name: get_field(data, :name),
      next_invoice_sequence: 1,
      object: "customer",
      phone: get_field(data, :phone),
      preferred_locales: [],
      shipping: get_field(data, :shipping),
      tax_exempt: get_field(data, :tax_exempt, "none")
    }
  end

  # Get a field from map supporting both atom and string keys
  defp get_field(data, key, default \\ nil) do
    Map.get(data, key) || Map.get(data, to_string(key)) || default
  end

  # Convert string keys to atoms (for metadata, recurring, etc.)
  defp atomize_keys(nil), do: nil

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  end

  defp atomize_keys(value), do: value
end
