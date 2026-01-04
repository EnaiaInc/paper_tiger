defmodule PaperTiger.Test do
  @moduledoc """
  Test helpers for running PaperTiger tests concurrently.

  Provides a sandbox mechanism similar to Ecto.Adapters.SQL.Sandbox that
  isolates test data by namespace, allowing tests to run with `async: true`.

  ## Usage

      defmodule MyApp.StripeTest do
        use ExUnit.Case, async: true

        setup :checkout_paper_tiger

        test "creates a customer" do
          # Data is isolated to this test process
          {:ok, customer} = PaperTiger.TestClient.create_customer(%{...})
        end
      end

  ## How It Works

  When `checkout_paper_tiger/1` is called:

  1. Stores the test process PID as a namespace in the process dictionary
  2. All subsequent PaperTiger operations scope data to that namespace
  3. On test exit, only that namespace's data is cleaned up

  This allows multiple tests to run concurrently without interfering
  with each other's data.
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
  alias PaperTiger.Store.SubscriptionSchedules
  alias PaperTiger.Store.TaxRates
  alias PaperTiger.Store.Tokens
  alias PaperTiger.Store.Topups
  alias PaperTiger.Store.WebhookDeliveries
  alias PaperTiger.Store.Webhooks

  @namespace_key :paper_tiger_namespace
  @namespace_header "x-paper-tiger-namespace"
  @shared_namespace_key :paper_tiger_shared_namespace
  @default_api_key "sk_test_mock"

  @doc """
  Returns the base URL for PaperTiger HTTP requests.

  Uses the configured port from application config.

  ## Example

      iex> PaperTiger.Test.base_url()
      "http://localhost:4001"

      iex> PaperTiger.Test.base_url("/v1/customers")
      "http://localhost:4001/v1/customers"
  """
  @spec base_url(String.t()) :: String.t()
  def base_url(path \\ "") do
    port = Application.get_env(:paper_tiger, :port, 4001)
    "http://localhost:#{port}#{path}"
  end

  @doc """
  Returns HTTP headers for authenticated sandbox requests.

  Combines authorization header with sandbox namespace headers.
  Use this helper for most HTTP requests to PaperTiger.

  ## Options

  - `:api_key` - Override the default API key (default: "sk_test_mock")

  ## Example

      Req.post(base_url("/v1/customers"),
        form: [email: "test@example.com"],
        headers: auth_headers()
      )

      # With custom API key
      Req.get(url, headers: auth_headers(api_key: "sk_test_custom"))
  """
  @spec auth_headers(keyword()) :: [{String.t(), String.t()}]
  def auth_headers(opts \\ []) do
    api_key = Keyword.get(opts, :api_key, @default_api_key)
    [{"authorization", "Bearer #{api_key}"}] ++ sandbox_headers()
  end

  @doc """
  Returns HTTP headers needed for sandbox isolation.

  Include these headers in HTTP requests to PaperTiger to ensure
  data is scoped to the current test's namespace.

  ## Example

      Req.post(url, headers: PaperTiger.Test.sandbox_headers())

      # Or merge with other headers:
      Req.get(url,
        headers: [{"authorization", "Bearer sk_test_mock"}] ++ PaperTiger.Test.sandbox_headers()
      )
  """
  @spec sandbox_headers() :: [{String.t(), String.t()}]
  def sandbox_headers do
    case current_namespace() do
      :global -> []
      pid when is_pid(pid) -> [{@namespace_header, inspect(pid)}]
    end
  end

  @doc """
  Checks out a PaperTiger sandbox for the current test.

  Use as a setup callback:

      setup :checkout_paper_tiger

  Or call directly in setup block:

      setup do
        PaperTiger.Test.checkout_paper_tiger(%{})
        :ok
      end

  ## Child Process Support

  This function also sets a shared namespace via Application env, which
  allows child processes (like Phoenix LiveView) to use the same sandbox.
  This is essential for integration tests where Stripe calls happen in
  spawned processes.

  Returns `:ok` for use with ExUnit's setup callbacks.
  """
  @spec checkout_paper_tiger(map()) :: :ok
  def checkout_paper_tiger(_context \\ %{}) do
    namespace = self()
    Process.put(@namespace_key, namespace)

    # Also set shared namespace for child processes (LiveView, async tasks, etc.)
    # This allows stripity_stripe calls from spawned processes to use the same sandbox
    Application.put_env(:paper_tiger, @shared_namespace_key, namespace)

    ExUnit.Callbacks.on_exit(fn ->
      cleanup_namespace(namespace)
      # Clear the shared namespace on test exit
      Application.delete_env(:paper_tiger, @shared_namespace_key)
    end)

    :ok
  end

  @doc """
  Returns the current namespace, or `:global` if not in a sandboxed test.
  """
  @spec current_namespace() :: pid() | :global
  def current_namespace do
    Process.get(@namespace_key, :global)
  end

  @doc """
  Cleans up all data for the given namespace.

  Called automatically on test exit when using `checkout_paper_tiger/1`.
  """
  @spec cleanup_namespace(pid() | :global) :: :ok
  def cleanup_namespace(namespace) do
    stores = [
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
      SubscriptionSchedules,
      TaxRates,
      Tokens,
      Topups,
      WebhookDeliveries,
      Webhooks
    ]

    Enum.each(stores, fn store ->
      store.clear_namespace(namespace)
    end)

    # Also clear idempotency keys for this namespace
    PaperTiger.Idempotency.clear_namespace(namespace)

    :ok
  end

  # =============================================================================
  # Webhook Delivery Helpers (for :collect mode)
  # =============================================================================

  @doc """
  Enables webhook collection mode for the current test.

  Call this in your test setup to capture webhooks instead of delivering them.
  Automatically restores the previous mode on test exit.

  ## Example

      setup do
        :ok = checkout_paper_tiger(%{})
        :ok = enable_webhook_collection()
        :ok
      end

      test "creates customer and triggers webhook" do
        {:ok, _customer} = Stripe.Customer.create(%{email: "test@example.com"})
        [delivery] = PaperTiger.Test.assert_webhook_delivered("customer.created")
        assert delivery.event_data.object.email == "test@example.com"
      end
  """
  @spec enable_webhook_collection() :: :ok
  def enable_webhook_collection do
    previous_mode = Application.get_env(:paper_tiger, :webhook_mode)
    Application.put_env(:paper_tiger, :webhook_mode, :collect)

    ExUnit.Callbacks.on_exit(fn ->
      if previous_mode do
        Application.put_env(:paper_tiger, :webhook_mode, previous_mode)
      else
        Application.delete_env(:paper_tiger, :webhook_mode)
      end
    end)

    :ok
  end

  @doc """
  Gets all webhook deliveries collected during the test.

  Only works when `webhook_mode: :collect` is configured.

  Returns a list of delivery records sorted by creation time (oldest first).

  ## Example

      setup do
        Application.put_env(:paper_tiger, :webhook_mode, :collect)
        on_exit(fn -> Application.delete_env(:paper_tiger, :webhook_mode) end)
        :ok
      end

      test "creates customer and triggers webhook" do
        {:ok, _customer} = Stripe.Customer.create(%{email: "test@example.com"})

        deliveries = PaperTiger.Test.get_delivered_webhooks()
        assert [%{event_type: "customer.created"}] = deliveries
      end
  """
  @spec get_delivered_webhooks() :: [map()]
  def get_delivered_webhooks do
    WebhookDeliveries.get_all()
  end

  @doc """
  Gets webhook deliveries filtered by event type.

  Supports wildcard patterns like "customer.*" or "invoice.payment_*".

  ## Examples

      # Get all customer.created events
      get_delivered_webhooks("customer.created")

      # Get all customer events
      get_delivered_webhooks("customer.*")

      # Get all invoice payment events
      get_delivered_webhooks("invoice.payment_*")
  """
  @spec get_delivered_webhooks(String.t()) :: [map()]
  def get_delivered_webhooks(type_pattern) do
    WebhookDeliveries.get_by_type(type_pattern)
  end

  @doc """
  Clears all collected webhook deliveries for the current namespace.

  Useful when testing multiple operations and wanting to verify
  webhooks from a specific action.

  ## Example

      test "verifies webhooks for second operation only" do
        {:ok, _} = Stripe.Customer.create(%{email: "first@example.com"})
        PaperTiger.Test.clear_delivered_webhooks()

        {:ok, _} = Stripe.Customer.create(%{email: "second@example.com"})

        # Only sees the second customer's webhook
        assert [%{event_type: "customer.created"}] = PaperTiger.Test.get_delivered_webhooks()
      end
  """
  @spec clear_delivered_webhooks() :: :ok
  def clear_delivered_webhooks do
    WebhookDeliveries.clear_namespace(current_namespace())
  end

  @doc """
  Asserts that a webhook was delivered with the given event type.

  This is a convenience helper that combines getting deliveries and asserting.
  Returns the matching deliveries for further assertions.

  ## Example

      test "customer creation triggers webhook" do
        {:ok, customer} = Stripe.Customer.create(%{email: "test@example.com"})

        [delivery] = PaperTiger.Test.assert_webhook_delivered("customer.created")
        assert delivery.event_data.object.email == "test@example.com"
      end
  """
  @spec assert_webhook_delivered(String.t()) :: [map()]
  def assert_webhook_delivered(type_pattern) do
    deliveries = get_delivered_webhooks(type_pattern)

    if deliveries == [] do
      all_deliveries = get_delivered_webhooks()
      types = Enum.map(all_deliveries, & &1.event_type)

      raise ExUnit.AssertionError,
        message: """
        Expected webhook delivery matching "#{type_pattern}" but none found.

        Delivered webhooks: #{inspect(types)}
        """
    end

    deliveries
  end

  @doc """
  Asserts that no webhook was delivered with the given event type.

  ## Example

      test "soft delete doesn't trigger delete webhook" do
        {:ok, customer} = Stripe.Customer.create(%{email: "test@example.com"})
        PaperTiger.Test.clear_delivered_webhooks()

        soft_delete_customer(customer)

        PaperTiger.Test.refute_webhook_delivered("customer.deleted")
      end
  """
  @spec refute_webhook_delivered(String.t()) :: :ok
  def refute_webhook_delivered(type_pattern) do
    deliveries = get_delivered_webhooks(type_pattern)

    if deliveries != [] do
      raise ExUnit.AssertionError,
        message: """
        Expected no webhook delivery matching "#{type_pattern}" but found #{length(deliveries)}.

        Deliveries: #{inspect(deliveries, pretty: true)}
        """
    end

    :ok
  end
end
