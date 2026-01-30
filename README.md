[![Hex.pm](https://img.shields.io/hexpm/v/paper_tiger)](https://hex.pm/packages/paper_tiger)
[![Hexdocs.pm](https://img.shields.io/badge/docs-hexdocs.pm-purple)](https://hexdocs.pm/paper_tiger)
[![Github.com](https://github.com/EnaiaInc/paper_tiger/actions/workflows/ci.yml/badge.svg)](https://github.com/EnaiaInc/paper_tiger/actions)

# PaperTiger

A stateful mock Stripe server for testing Elixir applications.

## Rationale

Testing payment processing requires simulating complex Stripe workflows: subscription billing cycles, invoice finalization, webhook delivery, idempotency handling. Using real Stripe test accounts introduces external dependencies, network latency, rate limits, and non-deterministic test data. Stubbing individual Stripe API calls leads to brittle tests that break when Stripe's API evolves.

PaperTiger solves this by providing a complete, stateful implementation of the Stripe API that runs in-process. Tests execute in milliseconds instead of seconds, work offline, and produce deterministic results. The dual-mode contract testing system validates that PaperTiger's behavior matches production Stripe, catching API drift automatically.

## Philosophy

**State over stubs**: PaperTiger maintains actual resource state (customers, subscriptions, invoices) instead of returning canned responses. This enables testing complex workflows like subscription lifecycle management, trial expiration, and invoice finalization.

**Contract validation**: The same test suite runs against both PaperTiger and real Stripe. This ensures the mock accurately reflects production behavior while maintaining zero-setup development experience.

**Time control**: Subscription billing, trial periods, and webhook retry logic depend on time progression. PaperTiger provides accelerated and manual clock modes for testing time-dependent behavior without waiting.

**Elixir-native**: Built with ETS, GenServers, and Plug. No external databases or runtimes required.

## Features

- **Complete Stripe API Coverage**: Customers, Subscriptions, Invoices, PaymentMethods, and more
- **Stateful In-Memory Storage**: ETS-backed GenServers with concurrent reads and serialized writes
- **Webhook Delivery**: HMAC-signed webhook events with retry logic
- **Dual-Mode Contract Testing**: Run same tests against PaperTiger or real Stripe API
- **Zero External Dependencies**: No Stripe account or API keys required for normal testing
- **Idempotency**: Request deduplication with 24-hour TTL
- **Object Expansion**: Hydrator system for nested resource expansion
- **Time Control**: Accelerated, manual, or real-time clock for testing
- **Billing Engine**: Automated subscription billing simulation
- **Chaos Testing**: Unified ChaosCoordinator for payment, event, and API chaos

## Installation

Add `paper_tiger` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:paper_tiger, "~> 0.9.23"}
  ]
end
```

## Quick Start

[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https://github.com/EnaiaInc/paper_tiger/blob/main/examples/getting_started.livemd)

Try the [interactive Livebook tutorial](examples/getting_started.livemd) for a hands-on introduction!

```elixir
# Start PaperTiger in your test setup
{:ok, _} = PaperTiger.start()

# Make requests using any HTTP client (e.g., Req)
response = Req.post!(
  "http://localhost:4001/v1/customers",
  form: [email: "user@example.com", name: "Test User"],
  auth: {:bearer, "sk_test_mock"}
)

# Or use the TestClient for dual-mode testing
alias PaperTiger.TestClient

{:ok, customer} = TestClient.create_customer(%{
  "email" => "user@example.com",
  "name" => "Test User"
})

# Clean up between tests
PaperTiger.flush()
```

## Phoenix Integration

PaperTiger integrates seamlessly with Phoenix applications for local development and testing.

### Setup

Add PaperTiger to your dependencies:

```elixir
# mix.exs
def deps do
  [
    {:paper_tiger, "~> 0.9.4", only: [:dev, :test]},
    {:stripity_stripe, "~> 3.0"}
  ]
end
```

### Configuration

Use PaperTiger's configuration helper in your config files:

```elixir
# config/test.exs
config :stripity_stripe, PaperTiger.stripity_stripe_config()

# Optional: Start HTTP server (runs on port 4001 by default)
config :paper_tiger, start: true

# Optional: Register webhooks automatically
config :paper_tiger,
  webhooks: [
    [url: "http://localhost:4000/webhooks/stripe"]
  ]
```

For conditional use in development (e.g., PR apps):

```elixir
# config/runtime.exs
if System.get_env("USE_PAPER_TIGER") == "true" do
  config :stripity_stripe, PaperTiger.stripity_stripe_config()
  config :paper_tiger, start: true
end
```

### Environment Variables

PaperTiger respects environment variables for runtime configuration:

- `PAPER_TIGER_START` - Set to "true" to enable HTTP server
- `PAPER_TIGER_PORT` - Port to run on (default: 4001)
- `PAPER_TIGER_PORT_DEV` - Port for dev environment (overrides `PAPER_TIGER_PORT`)
- `PAPER_TIGER_PORT_TEST` - Port for test environment (overrides `PAPER_TIGER_PORT`)

**Port precedence:** `PAPER_TIGER_PORT_{ENV}` > `PAPER_TIGER_PORT` > config > 4001

This allows running dev server and tests simultaneously on different ports:

```bash
# In .env or shell
export PAPER_TIGER_PORT_DEV=4001
export PAPER_TIGER_PORT_TEST=4003
```

This is also useful for Fly.io or other PaaS deployments:

```bash
# Enable PaperTiger for PR apps
fly secrets set PAPER_TIGER_START=true -a my-app-pr-123
```

### Webhook Integration

PaperTiger automatically emits Stripe events when resources are created, updated, or deleted. These events are delivered to registered webhook endpoints with proper HMAC signatures.

**Supported events:**

- `customer.created`, `customer.updated`, `customer.deleted`
- `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`
- `invoice.created`, `invoice.updated`, `invoice.finalized`, `invoice.paid`, `invoice.payment_succeeded`
- `payment_intent.created`, `product.created`, `price.created`

#### Option 1: Auto-registration via Config

```elixir
# config/test.exs
config :paper_tiger,
  start: true,
  webhooks: [
    [url: "http://localhost:4000/webhooks/stripe"]
  ]

# In your test setup
setup do
  PaperTiger.register_configured_webhooks()
  PaperTiger.flush()
  :ok
end
```

#### Option 2: Manual Registration

```elixir
# In test setup or IEx
PaperTiger.register_webhook(url: "http://localhost:4000/webhooks/stripe")
```

#### Webhook Controller

Your Phoenix webhook controller works unchanged:

```elixir
defmodule MyAppWeb.StripeWebhookController do
  use MyAppWeb, :controller

  def webhook(conn, params) do
    # PaperTiger signs webhooks identically to Stripe
    case Stripe.Webhook.construct_event(
      conn.assigns.raw_body,
      get_req_header(conn, "stripe-signature"),
      Application.get_env(:stripity_stripe, :webhook_signing_key)
    ) do
      {:ok, event} ->
        handle_event(event)
        send_resp(conn, 200, "ok")

      {:error, _} ->
        send_resp(conn, 400, "invalid signature")
    end
  end
end
```

### Development Workflow

```bash
# Terminal 1: Start Phoenix (port 4000)
mix phx.server

# Terminal 2: Start PaperTiger (port 4001)
iex -S mix
iex> PaperTiger.start()
iex> PaperTiger.register_webhook(url: "http://localhost:4000/webhooks/stripe")

# Now Stripe API calls from your app go to PaperTiger
# Webhooks are delivered to your Phoenix app
```

Or use start for zero-config testing:

```elixir
# config/test.exs
config :paper_tiger, start: true
config :stripity_stripe, PaperTiger.stripity_stripe_config()

# In tests - PaperTiger runs automatically
test "subscription creation triggers webhook" do
  # Create subscription via Stripe client
  {:ok, _sub} = Stripe.Subscription.create(%{customer: customer_id, ...})

  # Webhook delivered to your Phoenix app
  assert_receive {:webhook, %{type: "customer.subscription.created"}}
end
```

### Webhook Collection Mode

For tests that need to verify webhooks without running a web server, use `:collect` mode. This stores webhooks in-memory for inspection instead of delivering them via HTTP.

```elixir
defmodule MyApp.SubscriptionTest do
  use ExUnit.Case, async: true
  import PaperTiger.Test

  setup :checkout_paper_tiger

  test "creating subscription triggers correct webhook" do
    # Enable webhook collection for this test
    enable_webhook_collection()

    # Create subscription - this triggers the webhook
    {:ok, subscription} = Stripe.Subscription.create(%{
      customer: customer_id,
      items: [%{price: price_id}]
    })

    # Verify the webhook that Stripe would send
    [delivery] = assert_webhook_delivered("customer.subscription.created")

    # Inspect the webhook payload
    assert delivery.event_data.object.id == subscription.id
    assert delivery.event_data.object.status == "active"
    assert delivery.event_data.object.customer == customer_id
  end

  test "cancellation triggers delete webhook" do
    enable_webhook_collection()

    {:ok, subscription} = Stripe.Subscription.create(%{...})
    clear_delivered_webhooks()  # Clear creation webhook

    {:ok, _} = Stripe.Subscription.cancel(subscription.id)

    [delivery] = assert_webhook_delivered("customer.subscription.deleted")
    assert delivery.event_data.object.status == "canceled"
  end

  test "update does not trigger delete webhook" do
    enable_webhook_collection()

    {:ok, subscription} = Stripe.Subscription.create(%{...})
    clear_delivered_webhooks()

    {:ok, _} = Stripe.Subscription.update(subscription.id, %{metadata: %{foo: "bar"}})

    refute_webhook_delivered("customer.subscription.deleted")
    assert_webhook_delivered("customer.subscription.updated")
  end
end
```

**Available helpers:**

- `enable_webhook_collection/0` - Enables `:collect` mode for the test (auto-cleanup on exit)
- `get_delivered_webhooks/0` - Returns all collected webhooks
- `get_delivered_webhooks/1` - Filter by event type (supports wildcards like `"customer.*"`)
- `assert_webhook_delivered/1` - Asserts webhook was delivered, returns matches
- `refute_webhook_delivered/1` - Asserts webhook was NOT delivered
- `clear_delivered_webhooks/0` - Clears collected webhooks (useful between operations)

**When to use each mode:**

| Mode            | Use Case                                           |
| --------------- | -------------------------------------------------- |
| `:collect`      | Unit tests verifying webhook payloads without HTTP |
| `:sync`         | Integration tests with a real webhook endpoint     |
| Default (async) | Development with Phoenix running                   |

### Port Configuration

PaperTiger automatically picks a random available port in the 59000-60000 range by default, eliminating port conflicts when running multiple instances (tests + dev server, parallel test suites).

**Port selection:**

- **Random by default** - Picks available port, retries if conflict detected
- **Early resolution** - `stripity_stripe_config()` and `PaperTiger.get_port()` resolve and cache the port before startup
- **Manual override** - Set explicit port via env var or config

If you need a specific port:

```elixir
# Via environment variable (recommended)
PAPER_TIGER_PORT=4001 mix test

# Via config
config :stripity_stripe, PaperTiger.stripity_stripe_config(port: 4001)

# Discover which port was selected
iex> PaperTiger.get_port()
59342
```

## Concurrent Test Support

PaperTiger supports running tests concurrently with `async: true` through a sandbox mechanism similar to Ecto's SQL Sandbox.

### Setup

Use `checkout_paper_tiger` in your test setup:

```elixir
defmodule MyApp.StripeTest do
  use ExUnit.Case, async: true

  import PaperTiger.Test

  setup :checkout_paper_tiger

  test "creates a customer" do
    # Data is isolated to this test process
    conn = post("/v1/customers", %{email: "test@example.com"})
    assert conn.status == 200
  end
end
```

### How It Works

1. `checkout_paper_tiger/1` stores the test process PID as a namespace
2. All PaperTiger operations (reads/writes) are scoped to that namespace
3. On test exit, only that namespace's data is automatically cleaned up

This allows hundreds of tests to run in parallel without data interference.

### Stripity Stripe Integration

When using `stripity_stripe`, configure it to use `PaperTiger.StripityStripeHackney` for automatic sandbox isolation:

```elixir
# config/test.exs
config :stripity_stripe,
  api_key: "sk_test_paper_tiger",
  api_base_url: "http://localhost:4001",
  http_module: PaperTiger.StripityStripeHackney
```

Or use the helper:

```elixir
# config/test.exs
config :stripity_stripe, PaperTiger.stripity_stripe_config()
```

This ensures that all Stripe API calls made via `stripity_stripe` automatically include the namespace header for test isolation - including calls made from child processes like Phoenix LiveView.

**How it works:**

1. `checkout_paper_tiger/1` sets a shared namespace via Application env
2. `PaperTiger.StripityStripeHackney` injects the `x-paper-tiger-namespace` header into HTTP requests
3. Child processes (LiveView, async tasks) automatically pick up the shared namespace
4. All Stripe operations are scoped to the test's namespace

**Example with LiveView:**

```elixir
defmodule MyApp.BillingLiveTest do
  use MyApp.ConnCase, async: true

  import PaperTiger.Test

  setup do
    checkout_paper_tiger(%{})
    # ... rest of setup
  end

  test "billing page shows subscription", %{conn: conn} do
    # Create subscription in test process
    {:ok, _sub} = Stripe.Subscription.create(%{...})

    # LiveView's Stripe calls are automatically isolated to same sandbox
    {:ok, live, _html} = live(conn, "/billing")
    assert has_element?(live, "[data-subscription]")
  end
end
```

### Migration from sync tests

Replace:

```elixir
# Before
use ExUnit.Case

setup do
  PaperTiger.flush()
  :ok
end
```

With:

```elixir
# After
use ExUnit.Case, async: true

import PaperTiger.Test

setup :checkout_paper_tiger
```

## Architecture

### Storage Layer

Each Stripe resource has a dedicated ETS-backed GenServer store:

- **Reads**: Direct ETS access (concurrent, no GenServer bottleneck)
- **Writes**: Through GenServer (serialized, prevents race conditions)
- **Operations**: `get/1`, `list/1`, `insert/1`, `update/1`, `delete/1`, `clear/0`

All stores use a shared `PaperTiger.Store` macro to eliminate boilerplate.

### HTTP Layer

Plug-based request pipeline:

1. **Auth**: Validates `Authorization: Bearer sk_test_*` headers (lenient mode)
2. **CORS**: Cross-origin request support
3. **Idempotency**: Prevents duplicate POST requests via `Idempotency-Key` header
4. **UnflattenParams**: Converts form-encoded bracket notation to nested Elixir structures

Router uses macro-based route generation for DRY resource definitions.

### Webhook System

`PaperTiger.WebhookDelivery` GenServer handles asynchronous webhook delivery:

- HMAC SHA256 signing with configurable secrets
- Exponential backoff retry logic (5 attempts)
- Event type filtering per endpoint
- Delivery tracking and logging

### Time Control

`PaperTiger.Clock` provides deterministic time for testing:

```elixir
# Real time (default)
PaperTiger.set_clock_mode(:real)

# Accelerated time (10x speed)
PaperTiger.set_clock_mode(:accelerated, multiplier: 10)

# Manual time control
PaperTiger.set_clock_mode(:manual, timestamp: 1234567890)
PaperTiger.advance_time(3600)  # Advance 1 hour
```

## Billing Engine

PaperTiger includes a `BillingEngine` for simulating subscription billing cycles. This enables testing of payment failures, retry logic, and subscription lifecycle without waiting for real time to pass.

### Basic Usage

```elixir
# Enable billing engine in config
config :paper_tiger, :billing_engine, true

# Or start manually
PaperTiger.BillingEngine.start_link([])

# Process all due subscriptions
{:ok, stats} = PaperTiger.BillingEngine.process_billing()
# => %{processed: 5, succeeded: 4, failed: 1}
```

## Chaos Testing

PaperTiger provides a unified `ChaosCoordinator` for comprehensive chaos testing across payment processing, webhook delivery, and API responses.

### Payment Chaos

Simulate payment failures with configurable rates and decline codes:

```elixir
# Configure global payment failure rate
PaperTiger.ChaosCoordinator.configure(
  payment_failure_rate: 0.3,  # 30% failure rate
  decline_codes: [:card_declined, :insufficient_funds, :expired_card]
)

# Per-customer failure simulation
PaperTiger.ChaosCoordinator.simulate_failure("cus_123", :insufficient_funds)

# Clear per-customer simulation
PaperTiger.ChaosCoordinator.clear_simulation("cus_123")

# Reset all chaos settings
PaperTiger.ChaosCoordinator.reset()
```

### Event Chaos

Test webhook handler resilience with out-of-order and duplicate events:

```elixir
PaperTiger.ChaosCoordinator.configure(
  event_out_of_order_rate: 0.2,  # 20% of events delivered out of order
  event_duplicate_rate: 0.1,     # 10% duplicate events
  event_delay_range: {100, 5000} # Random delay 100-5000ms
)
```

### API Chaos

Simulate API failures and rate limiting:

```elixir
PaperTiger.ChaosCoordinator.configure(
  api_timeout_rate: 0.1,      # 10% of requests timeout
  api_error_rate: 0.05,       # 5% server errors
  rate_limit_rate: 0.02       # 2% rate limit responses
)
```

### Extended Decline Codes

PaperTiger supports 22 Stripe decline codes for realistic failure simulation:

- **Common**: `card_declined`, `insufficient_funds`, `expired_card`, `do_not_honor`
- **Authentication**: `authentication_required`, `incorrect_cvc`, `incorrect_zip`
- **Fraud**: `fraudulent`, `stolen_card`, `lost_card`, `pickup_card`
- **Limits**: `card_velocity_exceeded`, `withdrawal_count_limit_exceeded`
- **Technical**: `processing_error`, `try_again_later`, `issuer_not_available`

### Chaos Statistics

Track chaos events for test assertions:

```elixir
stats = PaperTiger.ChaosCoordinator.stats()
# => %{
#   payment_failures: 5,
#   events_reordered: 3,
#   events_duplicated: 2,
#   api_timeouts: 1
# }
```

### Subscription Lifecycle

The billing engine handles the full subscription lifecycle:

1. Finds subscriptions where `current_period_end` has passed
2. Creates invoice with line items
3. Creates payment intent and attempts charge
4. On success: Updates invoice to `paid`, advances subscription period
5. On failure: Increments `attempt_count`, marks subscription `past_due` after 4 failures

Combined with time control, you can simulate months of billing in seconds:

```elixir
# Set up subscription due for billing
PaperTiger.set_clock_mode(:manual, timestamp: :os.system_time(:second))

# Process billing cycle
{:ok, _} = PaperTiger.BillingEngine.process_billing()

# Advance 30 days
PaperTiger.advance_time(30 * 24 * 60 * 60)

# Process next cycle
{:ok, _} = PaperTiger.BillingEngine.process_billing()
```

## Contract Testing

PaperTiger includes a dual-mode testing system that runs the same tests against both the mock server and real Stripe API, ensuring accuracy.

### Default Mode (PaperTiger)

```bash
mix test
```

Zero configuration required. Tests run against the in-memory mock server.

### Validation Mode (Real Stripe)

```bash
export STRIPE_API_KEY=sk_test_your_key_here
export VALIDATE_AGAINST_STRIPE=true
mix test test/paper_tiger/contract_test.exs
```

Tests run against stripe.com to validate that PaperTiger behavior matches production. Requires a Stripe test account.

> **🛡️ Safety Guard:** PaperTiger performs two-layer validation before running against real Stripe:
>
> 1. Validates the API key prefix (rejects `sk_live_*`, `rk_live_*`)
> 2. Makes a live API call to `/v1/balance` and verifies `livemode: false`
>
> If you accidentally configure a live-mode key, the tests will refuse to run with a clear error message. This prevents accidental charges to real customers.

### Writing Contract Tests

```elixir
defmodule MyApp.ContractTest do
  use ExUnit.Case
  alias PaperTiger.TestClient

  setup do
    if TestClient.paper_tiger?() do
      PaperTiger.flush()
    end
    :ok
  end

  test "customer CRUD lifecycle" do
    # Create
    {:ok, customer} = TestClient.create_customer(%{
      "email" => "user@example.com",
      "name" => "Test User"
    })

    # Retrieve
    {:ok, retrieved} = TestClient.get_customer(customer["id"])
    assert retrieved["email"] == "user@example.com"

    # Update
    {:ok, updated} = TestClient.update_customer(customer["id"], %{
      "name" => "Updated Name"
    })
    assert updated["name"] == "Updated Name"

    # Delete
    {:ok, deleted} = TestClient.delete_customer(customer["id"])
    assert deleted["deleted"] == true

    # Cleanup for real Stripe
    if TestClient.real_stripe?() do
      # Already deleted above
    end
  end
end
```

The `TestClient` module routes operations to the appropriate backend based on environment variables, normalizing responses to ensure consistent map structures with string keys.

### Supported Contract Operations

**Customers**:

- `create_customer/1`, `get_customer/1`, `update_customer/2`, `delete_customer/1`, `list_customers/1`

**Subscriptions**:

- `create_subscription/1`, `get_subscription/1`, `update_subscription/2`, `delete_subscription/1`, `list_subscriptions/1`

**PaymentMethods**:

- `create_payment_method/1`, `get_payment_method/1`

**Invoices**:

- `create_invoice/1`, `get_invoice/1`

## Supported Resources

PaperTiger provides comprehensive coverage of core Stripe resources with full CRUD operations:

**Billing & Subscriptions**: Customers, Subscriptions, SubscriptionItems, Invoices, InvoiceItems, Products, Prices, Plans, Coupons, TaxRates

**Payments**: PaymentMethods, PaymentIntents, SetupIntents, Charges, Refunds

**Payment Sources**: Cards, BankAccounts, Sources, Tokens

**Platform & Connect**: Payouts, BalanceTransactions, ApplicationFees, Disputes

**Checkout & Events**: CheckoutSessions, WebhookEndpoints, Events, Reviews, Topups

> **Note**: PaperTiger implements Stripe API v1 resources. Some v2-only resources (e.g., v2 billing features) are not yet supported. Check the [issues page](https://github.com/EnaiaInc/paper_tiger/issues) for planned additions or open a feature request.

## API Examples

### Customer Operations

```elixir
# Create
{:ok, customer} = TestClient.create_customer(%{
  "email" => "user@example.com",
  "name" => "John Doe",
  "metadata" => %{"user_id" => "12345"}
})

# Retrieve
{:ok, customer} = TestClient.get_customer("cus_123")

# Update
{:ok, updated} = TestClient.update_customer("cus_123", %{
  "name" => "Jane Doe"
})

# Delete
{:ok, deleted} = TestClient.delete_customer("cus_123")

# List with pagination
{:ok, list} = TestClient.list_customers(%{
  "limit" => 10,
  "starting_after" => "cus_123"
})
```

### Subscription Operations

```elixir
# Create subscription with inline price
{:ok, subscription} = TestClient.create_subscription(%{
  "customer" => "cus_123",
  "items" => [
    %{
      "price_data" => %{
        "currency" => "usd",
        "product_data" => %{"name" => "Premium Plan"},
        "recurring" => %{"interval" => "month"},
        "unit_amount" => 2000
      }
    }
  ]
})

# Update
{:ok, updated} = TestClient.update_subscription("sub_123", %{
  "metadata" => %{"tier" => "premium"}
})

# Cancel
{:ok, canceled} = TestClient.delete_subscription("sub_123")
```

### Invoice Operations

```elixir
# Create draft invoice
{:ok, invoice} = TestClient.create_invoice(%{
  "customer" => "cus_123"
})

# Finalize and pay (PaperTiger HTTP API)
conn = post("/v1/invoices/#{invoice["id"]}/finalize")
conn = post("/v1/invoices/#{invoice["id"]}/pay")
```

## Configuration

```elixir
# config/test.exs
config :paper_tiger,
  port: 4001,  # Avoids conflict with Phoenix's default 4000
  clock_mode: :real,
  webhook_secret: "whsec_test_secret"

# For contract testing (optional)
config :stripity_stripe,
  api_key: System.get_env("STRIPE_API_KEY") || "sk_test_mock"
```

### Initial Data

PaperTiger can pre-populate products, prices, and customers on startup via the `init_data` config. Since ETS is ephemeral, this runs on every application start - useful for development environments where you need consistent Stripe data available immediately.

```elixir
# config/dev.exs - From a JSON file
config :paper_tiger,
  init_data: "priv/paper_tiger/init_data.json"

# Or inline in config
config :paper_tiger,
  init_data: %{
    products: [
      %{
        id: "prod_dev_standard",
        name: "Standard Plan",
        active: true,
        metadata: %{credits: "100"}
      }
    ],
    prices: [
      %{
        id: "price_dev_standard_monthly",
        product: "prod_dev_standard",
        unit_amount: 7900,
        currency: "usd",
        recurring: %{interval: "month", interval_count: 1}
      }
    ]
  }
```

Use custom IDs (like `prod_dev_*`) to ensure deterministic data across restarts. This is particularly useful when your app syncs from Stripe on startup - the data will be there before your sync runs.

### Database Synchronization

For development environments where you have existing billing data in your database (e.g., from previous Stripe syncs), PaperTiger can load that data on startup using the `DataSource` behaviour. This is more dynamic than `init_data` since it reads directly from your application's database.

**When to use each approach:**

| Approach      | Use Case                                     |
| ------------- | -------------------------------------------- |
| `init_data`   | Static seed data (JSON file or config)       |
| `data_source` | Sync from your application's database tables |

#### Step 1: Implement the DataSource Behaviour

Create an adapter module that implements `PaperTiger.DataSource`:

```elixir
# lib/my_app/paper_tiger_adapter.ex
defmodule MyApp.PaperTigerAdapter do
  @moduledoc """
  Loads billing data from database into PaperTiger on startup.
  """

  @behaviour PaperTiger.DataSource

  import Ecto.Query
  alias MyApp.Repo
  alias MyApp.Billing.{Product, Price, Customer, Subscription}

  @impl true
  def load_products do
    from(p in Product, where: not is_nil(p.stripe_id))
    |> Repo.all()
    |> Enum.map(&map_product/1)
  end

  @impl true
  def load_prices do
    from(p in Price,
      left_join: prod in assoc(p, :product),
      where: not is_nil(p.stripe_id),
      select: %{p | product: prod}
    )
    |> Repo.all()
    |> Enum.map(&map_price/1)
  end

  @impl true
  def load_customers do
    from(c in Customer,
      left_join: u in assoc(c, :user),
      where: not is_nil(c.stripe_id),
      select: %{c | user: u}
    )
    |> Repo.all()
    |> Enum.map(&map_customer/1)
  end

  @impl true
  def load_subscriptions do
    from(s in Subscription,
      left_join: c in assoc(s, :customer),
      left_join: p in assoc(s, :price),
      where: not is_nil(s.stripe_id),
      select: %{s | customer: c, price: p}
    )
    |> Repo.all()
    |> Enum.map(&map_subscription/1)
  end

  # Return empty lists for resources you don't need to sync
  @impl true
  def load_plans, do: []

  @impl true
  def load_payment_methods do
    # Create generic payment methods from customer default_source
    from(c in Customer,
      where: not is_nil(c.stripe_id) and not is_nil(c.default_source),
      select: %{stripe_id: c.stripe_id, default_source: c.default_source}
    )
    |> Repo.all()
    |> Enum.map(&map_payment_method/1)
  end

  # Mapping functions - convert your schemas to Stripe format with atom keys
  defp map_product(product) do
    %{
      id: product.stripe_id,
      object: "product",
      name: product.name,
      active: product.active,
      metadata: product.metadata || %{},
      created: to_unix(product.inserted_at)
    }
  end

  defp map_price(price) do
    %{
      id: price.stripe_id,
      object: "price",
      product: price.product.stripe_id,
      unit_amount: price.amount,
      currency: price.currency || "usd",
      type: if(price.recurring_interval, do: "recurring", else: "one_time"),
      recurring: if(price.recurring_interval,
        do: %{
          interval: price.recurring_interval,
          interval_count: price.recurring_interval_count || 1
        }
      ),
      created: to_unix(price.inserted_at)
    }
  end

  defp map_customer(customer) do
    %{
      id: customer.stripe_id,
      object: "customer",
      email: customer.user && customer.user.email,
      name: customer.user && customer.user.name,
      default_source: customer.default_source,
      created: to_unix(customer.inserted_at),
      invoice_settings: %{
        default_payment_method: customer.default_source
      },
      metadata: %{}
    }
  end

  defp map_subscription(subscription) do
    %{
      id: subscription.stripe_id,
      object: "subscription",
      customer: subscription.customer.stripe_id,
      status: subscription.status || "active",
      current_period_start: to_unix(subscription.current_period_start_at),
      current_period_end: to_unix(subscription.current_period_end_at),
      cancel_at: to_unix(subscription.cancel_at),
      items: %{
        object: "list",
        data: [
          %{
            id: "si_#{subscription.stripe_id}",
            object: "subscription_item",
            price: subscription.price.stripe_id,
            quantity: 1
          }
        ]
      },
      created: to_unix(subscription.inserted_at)
    }
  end

  defp map_payment_method(%{stripe_id: customer_stripe_id, default_source: pm_id}) do
    %{
      id: pm_id,
      object: "payment_method",
      type: "card",
      customer: customer_stripe_id,
      card: %{
        brand: "visa",
        last4: "4242",
        exp_month: 12,
        exp_year: 2030
      },
      created: DateTime.utc_now() |> DateTime.to_unix()
    }
  end

  defp to_unix(%NaiveDateTime{} = ndt) do
    DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_unix()
  end

  defp to_unix(_), do: nil
end
```

#### Step 2: Configure PaperTiger

Point PaperTiger to your adapter and enable bootstrap:

```elixir
# config/dev.exs
config :paper_tiger,
  start: true,
  repo: MyApp.Repo,  # Required for bootstrap
  data_source: MyApp.PaperTigerAdapter,
  enable_bootstrap: true
```

**Important**: The `data_source` sync runs during application startup via the Bootstrap worker. Data loads only once when PaperTiger starts, not on every request.

#### Step 3: Verify Data Loading

Start your application and check the logs:

```
[info] PaperTiger bootstrap starting
[info] PaperTiger loaded 13 prices from data_source
[info] PaperTiger loaded 7 products from data_source
[info] PaperTiger loaded 2 customers from data_source
[info] PaperTiger loaded 4 subscriptions from data_source
[info] PaperTiger loaded 2 payment_methods from data_source
[info] PaperTiger bootstrap complete
```

#### Mapping Tips

1. **Use atom keys** - PaperTiger expects maps with atom keys, not string keys
2. **Map IDs correctly** - Your `stripe_id` column maps to the `id` field
3. **Convert timestamps** - Use Unix timestamps (integers), not `NaiveDateTime` or `DateTime` structs
4. **Map relationships** - Use Stripe IDs for associations (e.g., `customer: "cus_123"`, not database IDs)
5. **Include invoice_settings** - If your app uses `invoice_settings.default_payment_method`, include it on customers

#### Benefits

- **Realistic testing** - Use actual billing data from your database
- **Automatic sync** - Data loads on startup, no manual setup needed
- **Development parity** - Dev environment matches production data structure
- **Fast iteration** - Modify data in database, restart to reload

#### Combining with init_data

You can use both `init_data` and `data_source` together. PaperTiger loads them in this order:

1. Test tokens (e.g., `pm_card_visa`)
2. DataSource (your adapter)
3. init_data (JSON/config file)

This allows test tokens to be available first, then real data from your database, then any additional seed data.

## Development

### Running Tests

```bash
# All tests
mix test

# Specific resource tests
mix test test/paper_tiger/resources/customer_test.exs

# Contract tests (PaperTiger mode)
mix test test/paper_tiger/contract_test.exs

# Contract tests (Stripe validation mode)
STRIPE_API_KEY=sk_test_xxx VALIDATE_AGAINST_STRIPE=true \
  mix test test/paper_tiger/contract_test.exs
```

### Quality Checks

```bash
# Compilation warnings as errors
mix compile --warnings-as-errors

# Code formatting
mix format --check-formatted

# Static analysis
mix credo --strict --all

# Type checking
mix dialyzer

# All quality checks
mix compile --warnings-as-errors && \
  mix format --check-formatted && \
  mix credo --strict --all && \
  mix dialyzer && \
  mix test
```

## Implementation Details

### Type Coercion

Form-encoded parameters are automatically coerced to proper types:

```elixir
# Input: "cancel_at_period_end=true&quantity=5"
# Output: %{cancel_at_period_end: true, quantity: 5}
```

### Array Parameter Flattening

Bracket notation is converted to Elixir lists:

```elixir
# Input: "items[0][price]=price_123&items[1][price]=price_456"
# Output: %{items: [%{price: "price_123"}, %{price: "price_456"}]}
```

### Object Expansion

The Hydrator system supports Stripe's `expand[]` parameter:

```elixir
# Request: GET /v1/customers/cus_123?expand[]=default_payment_method
# Response includes full PaymentMethod object instead of ID string
```

### ID Generation

All resources generate Stripe-compatible IDs:

- Customers: `cus_` + 24 random chars
- Subscriptions: `sub_` + 24 random chars
- Invoices: `in_` + 24 random chars
- etc.

### Pagination

Cursor-based pagination using `starting_after`, `ending_before`, and `limit`:

```elixir
%{
  "object" => "list",
  "data" => [...],
  "has_more" => true,
  "url" => "/v1/customers"
}
```

## Known Limitations

- No persistent storage (in-memory only)
- Webhook delivery is asynchronous but not distributed
- Some Stripe API edge cases may differ from production
- Time-based features (trials, billing periods) require manual time control

## Contributing

Contributions are welcome. When adding support for new Stripe resources or operations:

1. Add the resource store using `use PaperTiger.Store` macro
2. Implement resource handlers in `lib/paper_tiger/resources/`
3. Add routes to `lib/paper_tiger/router.ex`
4. Write comprehensive tests in `test/paper_tiger/resources/`
5. Add contract tests to validate against real Stripe API
6. Update this README with new capabilities

## License

MIT

## Links

- [Stripe API Documentation](https://stripe.com/docs/api)
- [Stripity Stripe](https://github.com/beam-community/stripity-stripe) (Elixir Stripe client)
- [Hex Package](https://hex.pm/packages/paper_tiger)
