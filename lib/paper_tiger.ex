defmodule PaperTiger do
  @moduledoc """
  PaperTiger - A stateful mock Stripe server for testing.

  ## Quick Start

      # Start the server
      {:ok, _pid} = PaperTiger.start()

      # Make API calls via HTTP
      response = HTTP.post!("/v1/customers", ...)

      # Clean up between tests
      PaperTiger.flush()

  ## Time Control

  PaperTiger supports three clock modes for deterministic testing:

  - `:real` - Use system time (default)
  - `:accelerated` - Time moves faster (useful for subscription billing tests)
  - `:manual` - Freeze time and advance manually

  ## Examples

      # Manual time control
      PaperTiger.set_clock_mode(:manual, timestamp: 1234567890)
      PaperTiger.advance_time(3600)  # Advance 1 hour

      # Accelerated time (10x speed)
      PaperTiger.set_clock_mode(:accelerated, multiplier: 10)

  ## Resource Cleanup

      # Flush specific resource
      PaperTiger.flush(:customers)

      # Flush all resources
      PaperTiger.flush()
  """

  alias PaperTiger.Store.{
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
  }

  @doc """
  Starts the PaperTiger application.

  ## Options

  - `:port` - HTTP port (default: 4001, avoids Phoenix's 4000)
  - `:clock_mode` - Time mode (default: `:real`)

  ## Examples

      {:ok, _pid} = PaperTiger.start()
      {:ok, _pid} = PaperTiger.start(port: 4002, clock_mode: :manual)
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts \\ []) do
    opts = Keyword.merge([port: 4001, clock_mode: :real, auto_start: true], opts)

    # Configure and start application
    Application.put_env(:paper_tiger, :port, opts[:port])
    Application.put_env(:paper_tiger, :clock_mode, opts[:clock_mode])
    Application.put_env(:paper_tiger, :auto_start, opts[:auto_start])

    Application.ensure_all_started(:paper_tiger)
  end

  @doc """
  Returns the current Unix timestamp according to the configured clock.

  ## Examples

      PaperTiger.now()
      #=> 1234567890
  """
  @spec now() :: integer()
  defdelegate now(), to: PaperTiger.Clock

  @doc """
  Sets the clock mode.

  ## Modes

  - `:real` - Use system time
  - `:accelerated` - Time runs faster (specify `:multiplier` option)
  - `:manual` - Manual control (specify `:timestamp` option)

  ## Examples

      PaperTiger.set_clock_mode(:real)
      PaperTiger.set_clock_mode(:accelerated, multiplier: 10)
      PaperTiger.set_clock_mode(:manual, timestamp: 1234567890)
  """
  @spec set_clock_mode(atom(), keyword()) :: :ok
  defdelegate set_clock_mode(mode, opts \\ []), to: PaperTiger.Clock, as: :set_mode

  @doc """
  Flushes (clears) all resources or a specific resource type.

  Dynamically discovers all PaperTiger ETS tables (`:paper_tiger_*`)
  and clears them. This prevents state leakage between tests without
  requiring manual maintenance of resource lists.

  ## Examples

      PaperTiger.flush()  # Clear all resources
      PaperTiger.flush(:customers)  # Clear only customers
  """
  @spec flush() :: :ok
  def flush do
    # Dynamically find all PaperTiger ETS tables
    :ets.all()
    |> Enum.filter(fn table_name ->
      # Only process atom table names (some ETS tables use references)
      if is_atom(table_name) do
        table_str = Atom.to_string(table_name)
        String.starts_with?(table_str, "paper_tiger_")
      else
        false
      end
    end)
    |> Enum.each(fn table_name ->
      :ets.delete_all_objects(table_name)
    end)

    # Also clear idempotency cache via its API
    PaperTiger.Idempotency.clear()

    # Reset chaos coordinator
    PaperTiger.ChaosCoordinator.reset()

    # Reload pre-defined Stripe test tokens (pm_card_visa, tok_visa, etc.)
    {:ok, _stats} = PaperTiger.TestTokens.load()

    :ok
  end

  @spec flush(atom()) :: :ok | {:error, :unknown_resource}
  def flush(:customers), do: Customers.clear()
  def flush(:subscriptions), do: Subscriptions.clear()
  def flush(:subscription_items), do: SubscriptionItems.clear()
  def flush(:invoices), do: Invoices.clear()
  def flush(:invoice_items), do: InvoiceItems.clear()
  def flush(:products), do: Products.clear()
  def flush(:prices), do: Prices.clear()
  def flush(:plans), do: Plans.clear()
  def flush(:payment_methods), do: PaymentMethods.clear()
  def flush(:payment_intents), do: PaymentIntents.clear()
  def flush(:setup_intents), do: SetupIntents.clear()
  def flush(:charges), do: Charges.clear()
  def flush(:refunds), do: Refunds.clear()
  def flush(:disputes), do: Disputes.clear()
  def flush(:coupons), do: Coupons.clear()
  def flush(:tax_rates), do: TaxRates.clear()
  def flush(:cards), do: Cards.clear()
  def flush(:bank_accounts), do: BankAccounts.clear()
  def flush(:sources), do: Sources.clear()
  def flush(:tokens), do: Tokens.clear()
  def flush(:checkout_sessions), do: CheckoutSessions.clear()
  def flush(:webhooks), do: Webhooks.clear()
  def flush(:events), do: Events.clear()
  def flush(:payouts), do: Payouts.clear()
  def flush(:balance_transactions), do: BalanceTransactions.clear()
  def flush(:application_fees), do: ApplicationFees.clear()
  def flush(:reviews), do: Reviews.clear()
  def flush(:topups), do: Topups.clear()
  def flush(_), do: {:error, :unknown_resource}

  @doc """
  Advances time in manual mode.

  ## Examples

      PaperTiger.advance_time(seconds: 3600)
      PaperTiger.advance_time(days: 30)
      PaperTiger.advance_time(86400)  # 1 day
  """
  @spec advance_time(integer() | keyword()) :: :ok
  defdelegate advance_time(amount), to: PaperTiger.Clock, as: :advance

  @doc """
  Returns the current clock mode.

  ## Examples

      PaperTiger.clock_mode()
      #=> :real
  """
  @spec clock_mode() :: atom()
  defdelegate clock_mode(), to: PaperTiger.Clock, as: :get_mode

  @doc """
  Registers a webhook endpoint for test orchestration.

  This is used by the `POST /_config/webhooks` endpoint for test setup.

  ## Parameters

  - `:url` - Webhook endpoint URL (required)
  - `:secret` - Webhook signing secret (default: "whsec_paper_tiger_test")
  - `:events` - List of event types to subscribe to (default: ["*"] for all events)

  ## Examples

      # Register with all events
      PaperTiger.register_webhook(url: "http://localhost:4000/webhooks/stripe")

      # Register with specific events
      PaperTiger.register_webhook(
        url: "http://localhost:4000/webhooks/stripe",
        secret: "whsec_custom",
        events: ["customer.created", "invoice.paid"]
      )
  """
  @spec register_webhook(keyword()) :: {:ok, map()}
  def register_webhook(opts) do
    import PaperTiger.Resource

    webhook = %{
      api_version: "2023-10-16",
      connect: false,
      created: now(),
      enabled_events: Keyword.get(opts, :events, ["*"]),
      id: generate_id("we"),
      livemode: false,
      metadata: %{},
      object: "webhook_endpoint",
      secret: Keyword.get(opts, :secret, "whsec_paper_tiger_test"),
      status: "enabled",
      url: Keyword.fetch!(opts, :url),
      version: nil
    }

    Webhooks.insert(webhook)
  end

  @doc """
  Registers webhook endpoints from application configuration.

  This function reads webhook endpoints from the `:paper_tiger, :webhooks` config
  and registers them automatically. Useful for setting up test webhooks at startup.

  ## Configuration

      # In config/test.exs
      config :paper_tiger,
        webhooks: [
          [url: "http://localhost:4000/webhooks/stripe"],
          [url: "http://localhost:4000/webhooks/events", events: ["invoice.paid"]]
        ]

  ## Examples

      # Register all configured webhooks
      PaperTiger.register_configured_webhooks()
      #=> {:ok, [%{id: "we_..."}, %{id: "we_..."}]}

  ## Returns

  `{:ok, webhooks}` where webhooks is a list of registered webhook maps.
  """
  @spec register_configured_webhooks() :: {:ok, [map()]}
  def register_configured_webhooks do
    webhooks = Application.get_env(:paper_tiger, :webhooks, [])

    registered =
      webhooks
      |> Enum.map(fn webhook_opts ->
        {:ok, webhook} = register_webhook(webhook_opts)
        webhook
      end)

    {:ok, registered}
  end

  @doc """
  Returns configuration for stripity_stripe to use PaperTiger as the Stripe API backend.

  This helper generates the configuration needed to point stripity_stripe at
  PaperTiger instead of the real Stripe API. Use this in your config files or
  test setup to simplify integration.

  ## Options

  - `:port` - PaperTiger port (default: 4001)
  - `:host` - PaperTiger host (default: "localhost")
  - `:webhook_secret` - Webhook signing secret (default: "whsec_paper_tiger_test")
  - `:sandbox` - Enable sandbox isolation for concurrent tests (default: true)

  ## Sandbox Mode

  When `sandbox: true` (the default), the returned config includes
  `http_module: PaperTiger.StripityStripeHackney`, which injects namespace
  headers for test isolation. This allows tests to run concurrently without
  data leakage between tests.

  Set `sandbox: false` if you want global (non-isolated) mode, though this
  is rarely needed.

  ## Examples

      # In config/test.exs (recommended)
      config :stripity_stripe, PaperTiger.stripity_stripe_config()

      # With custom options
      config :stripity_stripe, PaperTiger.stripity_stripe_config(port: 4002)

      # Disable sandbox (not recommended for concurrent tests)
      config :stripity_stripe, PaperTiger.stripity_stripe_config(sandbox: false)

  ## Returns

  Keyword list with:
  - `:api_key` - Mock API key
  - `:public_key` - Mock publishable key
  - `:api_base_url` - URL pointing to PaperTiger
  - `:webhook_signing_key` - Webhook signing secret
  - `:http_module` - Custom HTTP module for sandbox isolation (when sandbox: true)
  """
  @spec stripity_stripe_config(keyword()) :: keyword()
  def stripity_stripe_config(opts \\ []) do
    port = Keyword.get(opts, :port, 4001)
    host = Keyword.get(opts, :host, "localhost")
    webhook_secret = Keyword.get(opts, :webhook_secret, "whsec_paper_tiger_test")
    sandbox = Keyword.get(opts, :sandbox, true)

    base_config = [
      api_key: "sk_test_paper_tiger",
      public_key: "pk_test_paper_tiger",
      # NOTE: stripity_stripe appends endpoints like "/v1/products" to this URL,
      # so do NOT include "/v1" here
      api_base_url: "http://#{host}:#{port}",
      webhook_signing_key: webhook_secret
    ]

    if sandbox do
      base_config ++ [http_module: PaperTiger.StripityStripeHackney]
    else
      base_config
    end
  end
end
