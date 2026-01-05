# credo:disable-for-this-file Credo.Check.Refactor.Apply
defmodule PaperTiger.Application do
  @moduledoc false

  use Application

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
  alias PaperTiger.Store.SubscriptionSchedules
  alias PaperTiger.Store.TaxRates
  alias PaperTiger.Store.Tokens
  alias PaperTiger.Store.Topups
  alias PaperTiger.Store.WebhookDeliveries
  alias PaperTiger.Store.Webhooks

  require Logger

  # Capture Mix.env at compile time since Mix isn't available in releases
  @mix_env Mix.env()

  @impl true
  def start(_type, _args) do
    if should_start?() do
      do_start()
    else
      # Return empty supervisor - PaperTiger is disabled for this context
      Supervisor.start_link([], strategy: :one_for_one, name: PaperTiger.Supervisor)
    end
  end

  defp do_start do
    Logger.info("Starting PaperTiger Application")

    # Attach telemetry handlers for automatic event emission
    PaperTiger.TelemetryHandler.attach()

    children =
      [
        # Core systems
        PaperTiger.Clock,
        PaperTiger.Idempotency,
        PaperTiger.ChaosCoordinator,
        {Task.Supervisor, name: PaperTiger.TaskSupervisor},
        PaperTiger.WebhookDelivery,

        # Resource stores
        Customers,
        Subscriptions,
        Products,
        Prices,
        Invoices,
        PaymentMethods,
        Charges,
        Refunds,
        PaymentIntents,
        SetupIntents,
        SubscriptionItems,
        SubscriptionSchedules,
        InvoiceItems,
        Plans,
        Coupons,
        TaxRates,
        Cards,
        BankAccounts,
        Sources,
        Tokens,
        BalanceTransactions,
        Payouts,
        CheckoutSessions,
        Events,
        WebhookDeliveries,
        Webhooks,
        Disputes,
        ApplicationFees,
        Reviews,
        Topups
      ] ++
        conditional_children()

    opts = [strategy: :one_for_one, name: PaperTiger.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Load pre-defined Stripe test tokens (pm_card_visa, tok_visa, etc.)
        load_test_tokens()
        # Load init_data after stores are initialized
        load_init_data()
        # Register configured webhooks
        register_configured_webhooks()
        {:ok, pid}

      error ->
        error
    end
  end

  ## Private Functions

  # Loads pre-defined Stripe test tokens (pm_card_visa, tok_visa, etc.)
  defp load_test_tokens do
    {:ok, _stats} = PaperTiger.TestTokens.load()
    :ok
  end

  # Loads init_data if configured
  defp load_init_data do
    case PaperTiger.Initializer.load() do
      {:ok, _stats} -> :ok
      {:error, reason} -> Logger.error("PaperTiger init_data failed: #{inspect(reason)}")
    end
  end

  # Registers webhooks from application config
  defp register_configured_webhooks do
    PaperTiger.register_configured_webhooks()
  end

  # Returns children that only start under certain conditions
  defp conditional_children do
    []
    |> maybe_add_http_server()
    |> maybe_add_workers()
  end

  defp maybe_add_http_server(children) do
    port = get_port()

    http_spec = {
      Bandit,
      plug: PaperTiger.Router, port: port, scheme: :http
    }

    Logger.info("PaperTiger HTTP server starting on port #{port}")
    children ++ [http_spec]
  end

  # Check if PaperTiger should start at all
  # Env var takes precedence, then config, then smart default based on context
  defp should_start? do
    case System.get_env("PAPER_TIGER_START") do
      "true" -> true
      "false" -> false
      nil -> Application.get_env(:paper_tiger, :start, default_should_start?())
    end
  end

  # Smart default: start for test, phx.server, interactive iex sessions, and releases
  # Don't start for other mix tasks (compile, migrations, openapi generation, etc.)
  defp default_should_start? do
    cond do
      # In a release (no Mix module) - always start, user controls via config/env
      not Code.ensure_loaded?(Mix) -> true
      # Always start in test environment (compare atoms dynamically to avoid dialyzer warning)
      Atom.to_string(@mix_env) == "test" -> true
      # Start if running phx.server
      running_phx_server?() -> true
      # Start in interactive iex session (no Mix.TasksServer means not a mix task)
      interactive_session?() -> true
      # Don't start for other mix tasks
      true -> false
    end
  end

  defp running_phx_server? do
    System.argv() |> Enum.any?(&(&1 =~ "phx.server"))
  end

  defp interactive_session? do
    # If IEx is running and we're not in a mix task, it's interactive
    # Use apply to avoid dialyzer warning about IEx.started?/0 not existing
    iex_started? =
      Code.ensure_loaded?(IEx) and function_exported?(IEx, :started?, 0) and
        apply(IEx, :started?, [])

    iex_started? and not mix_task_running?()
  end

  defp mix_task_running? do
    # Mix.TasksServer only exists during mix tasks, not in releases
    Process.whereis(Mix.TasksServer) != nil
  end

  # Get port from env var or config, with random fallback to avoid conflicts
  # Precedence: PAPER_TIGER_PORT > config > random high port
  defp get_port do
    case System.get_env("PAPER_TIGER_PORT") do
      nil ->
        case Application.get_env(:paper_tiger, :port) do
          nil -> random_high_port()
          port -> port
        end

      port_string ->
        String.to_integer(port_string)
    end
  end

  # Pick a random port in range 51000-52000 to avoid conflicts
  defp random_high_port do
    51_000 + :rand.uniform(1000)
  end

  defp maybe_add_workers(children) do
    children
    |> maybe_add_billing_engine()
  end

  defp maybe_add_billing_engine(children) do
    if Application.get_env(:paper_tiger, :billing_engine, false) do
      Logger.info("PaperTiger BillingEngine enabled")
      children ++ [PaperTiger.BillingEngine]
    else
      children
    end
  end
end
