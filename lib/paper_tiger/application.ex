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
  alias PaperTiger.Store.TaxRates
  alias PaperTiger.Store.Tokens
  alias PaperTiger.Store.Topups
  alias PaperTiger.Store.Webhooks

  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting PaperTiger Application")

    # Attach telemetry handlers for automatic event emission
    PaperTiger.TelemetryHandler.attach()

    children =
      [
        # Core systems (always running)
        PaperTiger.Clock,
        PaperTiger.Idempotency,
        {Task.Supervisor, name: PaperTiger.TaskSupervisor},
        PaperTiger.WebhookDelivery,

        # Resource stores (always running)
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
        # Load init_data after stores are initialized
        load_init_data()
        {:ok, pid}

      error ->
        error
    end
  end

  ## Private Functions

  # Loads init_data if configured
  defp load_init_data do
    case PaperTiger.Initializer.load() do
      {:ok, _stats} -> :ok
      {:error, reason} -> Logger.error("PaperTiger init_data failed: #{inspect(reason)}")
    end
  end

  # Returns children that only start under certain conditions
  defp conditional_children do
    []
    |> maybe_add_http_server()
    |> maybe_add_workers()
  end

  defp maybe_add_http_server(children) do
    if should_auto_start?() do
      port = get_port()

      http_spec = {
        Bandit,
        plug: PaperTiger.Router, port: port, scheme: :http
      }

      Logger.info("PaperTiger HTTP server will start on port #{port}")
      children ++ [http_spec]
    else
      children
    end
  end

  # Check if HTTP server should auto-start (env var takes precedence over config)
  # Defaults to true - the whole point of PaperTiger is to serve HTTP requests
  defp should_auto_start? do
    case System.get_env("PAPER_TIGER_AUTO_START") do
      nil -> Application.get_env(:paper_tiger, :auto_start, true)
      "true" -> true
      "false" -> false
      _ -> true
    end
  end

  # Get port from env var or config
  # Precedence: PAPER_TIGER_PORT_{ENV} > PAPER_TIGER_PORT > config > default
  defp get_port do
    env_specific_var = "PAPER_TIGER_PORT_#{mix_env_upcase()}"

    case System.get_env(env_specific_var) do
      nil ->
        case System.get_env("PAPER_TIGER_PORT") do
          nil -> Application.get_env(:paper_tiger, :port, 4001)
          port_string -> String.to_integer(port_string)
        end

      port_string ->
        String.to_integer(port_string)
    end
  end

  defp mix_env_upcase do
    Mix.env() |> Atom.to_string() |> String.upcase()
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
