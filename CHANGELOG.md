# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.21] - 2026-01-19

### Changed

- Reduced startup log noise by changing initialization messages from `Logger.info` to `Logger.debug` across all Store modules, Application, Bootstrap, and core services. Startup messages are now only visible at debug level while operational logs remain at appropriate levels.

## [0.9.20] - 2026-01-11

### Changed

- **Checkout sessions now auto-complete transparently**: Checkout session URLs now point to PaperTiger's own endpoint (`/checkout/:id/complete`) instead of fake Stripe URLs. When visited, the session auto-completes and redirects to `success_url`. This eliminates the need for `paper_tiger_enabled?` checks in application code - checkout flows now work identically in dev/test and production.

## [0.9.19] - 2026-01-10

### Added

- **Chaos testing cleanup function**: Added `ChaosCoordinator.cleanup/0` and `ChaosHelpers.cleanup_chaos/0` that reset chaos configuration AND flush all Paper Tiger stores. Call after chaos testing to prevent test data from being synced to the host application's database.

## [0.9.18] - 2026-01-08

_No changes yet._

## [0.9.17] - 2026-01-08

### Added

- **Bootstrap worker for async data loading**: Refactored startup initialization into a dedicated `PaperTiger.Bootstrap` worker that handles async data loading without blocking application startup
- **DataSource behaviour**: New `PaperTiger.DataSource` behaviour enables synchronization of initial billing data from external application databases
- **Payment method sync from database**: StripityStripe adapter now loads existing payment methods and generates placeholders for missing customer `default_source` tokens

### Changed

- **Trialing → active subscription transitions**: Subscriptions updated with a past or `:now` `trial_end` now correctly transition from `trialing` to `active` status
- **`interval_count` optional in recurring prices**: Matches Stripe API specs where `interval_count` defaults to 1 if not provided

## [0.9.16] - 2026-01-07

### Changed

- **StripityStripe adapter now syncs from database instead of Stripe API**: Completely rewrote `PaperTiger.Adapters.StripityStripe` to query local database tables (`billing_customers`, `billing_subscriptions`, `billing_products`, `billing_prices`, `billing_plans`) instead of calling the real Stripe API. This properly mocks Stripe for dev/PR environments using stripity_stripe's local data.

  **Configuration required**: Add to your config:

  ```elixir
  config :paper_tiger, repo: MyApp.Repo
  ```

  **Note**: Auto-sync on startup is disabled when using database sync (repo isn't available at PaperTiger startup). You must manually trigger sync after your application starts, typically in your application's `start/2` callback after the repo is started:

  ```elixir
  # In your application.ex
  def start(_type, _args) do
    children = [MyApp.Repo, ...]
    opts = [strategy: :one_for_one, name: MyApp.Supervisor]

    result = Supervisor.start_link(children, opts)

    # Sync PaperTiger from database after repo is started
    if Application.get_env(:paper_tiger, :repo) do
      PaperTiger.Adapters.StripityStripe.sync_all()
    end

    result
  end
  ```

### Added

- **User adapter architecture**: New `PaperTiger.UserAdapter` behavior allows customizing how user information (name, email) is retrieved for customers during sync
- **Auto-discovering user adapter**: `PaperTiger.UserAdapters.AutoDiscover` automatically discovers common user schema patterns including:
  - Email fields: `email`, `email_address`, or foreign key `primary_email_id` → `emails.address`
  - Name fields: `name`, `full_name`, or `first_name + last_name`
  - User tables: `users` or `user`
- **Plan ID support for subscriptions**: Subscription creation now accepts both `price_id` and `plan_id` (legacy) for the `:price` parameter, matching Stripe API behavior. Plans are automatically converted to price format in responses.

## [0.9.15] - 2026-01-06

### Added

- **Stripe data sync adapter**: Automatically syncs customer, subscription, product, price, and plan data from real Stripe API on startup when stripity_stripe is detected. Solves the problem of dev/PR apps losing subscription data on restart. Sync adapter is pluggable via `PaperTiger.SyncAdapter` behavior for custom implementations.

### Changed

- **Reduced debug logging**: Removed per-operation debug logs from store operations (insert/update/delete/clear) and resource creation. Startup logging is now more concise with single-line summaries.

## [0.9.14] - 2026-01-05

### Fixed

- **`init_data` priv paths now work in releases**: Paths starting with `priv/` (e.g., `init_data: "priv/paper_tiger/init_data.json"`) are now automatically resolved by searching all loaded applications' priv directories. This fixes init_data not loading in releases where the working directory differs from the project root.

## [0.9.13] - 2026-01-04

### Fixed

- **Mix.env() check at runtime, not compile time**: Dependencies are compiled in `:dev` environment by default, so the compile-time `@mix_env` module attribute was always `:dev` even when running tests. Now checks `Mix.env()` at runtime (after verifying Mix is available) to correctly detect test environment.

## [0.9.12] - 2026-01-04

### Fixed

- **Namespace isolation for InvoiceItem**: Fixed `InvoiceItem.list` to properly filter by namespace, preventing test isolation leaks when listing invoice items.

## [0.9.11] - 2026-01-04

### Fixed

- **Mix.env() called at compile time**: Fixed crash in releases where `Mix.env()` was called at runtime but Mix isn't available in releases. Now captured at compile time via module attribute.

## [0.9.10] - 2026-01-04

### Added

- **`PaperTiger.StripityStripeHackney` for automatic sandbox isolation**: New HTTP module that wraps `:hackney` and injects namespace headers for test isolation when using stripity_stripe
  - Configure stripity_stripe with `http_module: PaperTiger.StripityStripeHackney`
  - Works with child processes (LiveView, async tasks) via shared namespace in Application env
  - `checkout_paper_tiger/1` now automatically sets up shared namespace for child process support

### Changed

- **`checkout_paper_tiger/1` sets shared namespace via Application env**: Child processes (like Phoenix LiveView) can now automatically access the same PaperTiger sandbox as the test process without additional configuration

## [0.9.9] - 2026-01-04

### Added

- **Pre-defined Stripe test payment method tokens**: PaperTiger now provides all standard Stripe test tokens (`pm_card_visa`, `pm_card_mastercard`, `pm_card_amex`, `tok_visa`, etc.) out of the box
  - Card brand tokens: visa, mastercard, amex, discover, diners, jcb, unionpay (plus debit/prepaid variants)
  - Decline test cards: `pm_card_chargeDeclined`, `pm_card_chargeDeclinedInsufficientFunds`, `pm_card_chargeDeclinedFraudulent`, etc.
  - Tokens are loaded at startup and persist across `flush()` calls
  - Test tokens work in namespace-isolated tests via global namespace fallback

## [0.9.8] - 2026-01-03

### Fixed

- **Contract tests use pm*card*\* tokens**: PaymentMethod contract tests now use Stripe test tokens (`pm_card_visa`, `pm_card_mastercard`, `pm_card_amex`) instead of raw card data, which works with both PaperTiger mock and real Stripe API

## [0.9.7] - 2026-01-03

### Fixed

- **Invoice `charge` field matches real Stripe behavior**: Draft invoices no longer include the `charge` key at all (not nil, just absent), matching real Stripe API behavior

### Added

- **Centralized test card helpers**: `TestClient.test_card/0` for real Stripe API testing and `TestClient.test_card_simple/0` for PaperTiger-style card data

## [0.9.6] - 2026-01-03

### Added

- **`get_optional_integer/2` helper**: Distinguishes "key not present" from "0" for optional integer params like `trial_end`
- **`normalize_integer_map/1` helper**: Converts string integer values in maps (e.g., form-encoded params) to actual integers
- **Auto-create Plan for recurring Prices**: When `Price.create` is called with `recurring` params, a matching Plan object is automatically created (Stripe legacy API compatibility)

### Fixed

- **Subscription default status is "active"**: Fixed bug where subscriptions without trial periods incorrectly defaulted to "trialing" status
- **Explicit status parameter respected**: `Subscription.create` now respects explicit `status` param instead of always computing it
- **Subscription list filtering**: Uses `list_namespace/1` for proper namespace-scoped queries instead of undefined store methods

## [0.9.5] - 2026-01-03

### Added

- **Subscription items include `plan` field for backwards compatibility**: Stripe API populates both `plan` and `price` on subscription items. PaperTiger now does the same via `build_plan_from_price/1`.
- **PaymentMethod.create supports custom IDs**: Use `id` parameter to create payment methods with deterministic IDs for testing.
- **Contract tests for subscription item plan field and payment method custom IDs**

### Fixed

- **Price.recurring now includes `interval_count`**: Added `build_recurring/1` function that defaults `interval_count` to 1 when not specified, matching Stripe API behavior.
- **Invoice list filtering by status**: Fixed status filter to work correctly with string status values.
- **PaymentMethod.list now requires customer parameter**: Matches real Stripe API behavior. Returns empty list without customer param.
- **PaymentMethods.find_by_customer uses proper namespacing**: Fixed ETS query to use namespace-scoped keys for test isolation.

## [0.9.4] - 2026-01-02

### Added

- **ChaosCoordinator for unified chaos testing**: New module consolidating all chaos testing capabilities
  - Payment chaos: configurable failure rates, decline codes, per-customer overrides
  - Event chaos: out-of-order delivery, duplicate events, buffered delivery windows
  - API chaos: timeout simulation, rate limiting, server errors
  - Statistics tracking for all chaos types
  - Integrated with `Invoice.pay` for realistic payment failure simulation

- **Contract tests for InvoiceItem, Invoice finalize/pay, and card decline errors**

### Fixed

- **Subscription status now matches Stripe API exactly** (e.g., `active` vs `trialing`)
- **TestClient normalizes delete responses** with `deleted=true` field
- **Card decline test assertions** check correct fields

### Changed

- **Clock uses ETS for lock-free reads**: `now/0` reads directly from ETS instead of GenServer call, avoiding bottleneck under load
- **Hydrator uses compile-time prefix registry**: No runtime map traversal for ID prefix lookups
- **Idempotency uses atomic select_delete**: Fixes potential race condition
- **ChaosCoordinator uses namespace isolation**: Per-namespace ETS state with proper timer cancellation on reset
- **Store modules export `prefix` option** for Hydrator registry
- **Tests use `assert_receive` instead of `Process.sleep`** for reliability

## [0.9.3] - 2026-01-02

### Added

- **Test sandbox for concurrent test support**: New `PaperTiger.Test` module provides Ecto SQL Sandbox-style test isolation
  - Use `setup :checkout_paper_tiger` to isolate test data per process
  - Tests can now run with `async: true` without data interference
  - All stores now support namespace-scoped operations
  - Automatic cleanup on test exit
- **HTTP sandbox via headers**: `PaperTiger.Plugs.Sandbox` enables sandbox isolation for HTTP API tests
  - Include `x-paper-tiger-namespace` header to scope HTTP requests to a test namespace
  - New `PaperTiger.Test.sandbox_headers/0` returns headers for sandbox isolation
  - New `PaperTiger.Test.auth_headers/1` combines auth + sandbox headers
  - New `PaperTiger.Test.base_url/1` helper for building PaperTiger URLs

### Changed

- **Storage layer uses namespaced keys**: All ETS stores now key data by `{namespace, id}` instead of just `id`
  - Backwards compatible: non-sandboxed code uses `:global` namespace automatically
  - New functions: `clear_namespace/1`, `list_namespace/1` on all stores
  - Idempotency cache also supports namespacing

## [0.9.2] - 2026-01-02

### Fixed

- **Proper Stripe error responses for missing resources**: Instead of crashing, PaperTiger now returns the same error format as Stripe when a resource doesn't exist
  - Returns `resource_missing` error code with proper message format: "No such <resource>: '<id>'"
  - Includes correct `param` values matching Stripe (e.g., `id` for customers, `price` for prices)
  - HTTP 404 status code for not found errors

### Added

- Contract tests verifying error responses match Stripe's format

## [0.9.1] - 2026-01-02

### Fixed

- **Events missing `delivery_attempts` field**: Events created via telemetry now include `delivery_attempts: []` field, fixing KeyError when accessing this field

### Added

- **Auto-register webhooks from application config on startup**: PaperTiger now automatically registers webhooks configured via `config :paper_tiger, webhooks: [...]` when the application starts, eliminating need for manual registration in your Application module

## [0.9.0] - 2026-01-02

### Fixed

- **Subscription `latest_invoice`**: Now populated with the actual latest Invoice object for the subscription instead of always being null
- **PaymentIntent `charges` field removed**: Real Stripe API does not include `charges` on PaymentIntent - charges are accessed via separate endpoint `GET /v1/charges?payment_intent=pi_xxx`. PaperTiger now matches this behavior.
- **Charge `balance_transaction`**: Successful charges now create and link a BalanceTransaction with proper fee calculation (2.9% + $0.30)
- **Refund `balance_transaction`**: Refunds now create and link a BalanceTransaction with negative amounts
- **Contract tests now run against real Stripe**: Removed all `paper_tiger_only` tagged tests. All contract tests now pass against both PaperTiger mock and real Stripe API.

### Added

- **Checkout Session completion support**: New endpoints for completing and expiring checkout sessions
  - `POST /v1/checkout/sessions/:id/expire` - Expires an open session (matches Stripe API)
  - `POST /_test/checkout/sessions/:id/complete` - Test helper to simulate successful checkout completion
  - Based on mode, creates appropriate side effects:
    - `payment`: Creates a succeeded PaymentIntent
    - `subscription`: Creates an active Subscription with items
    - `setup`: Creates a succeeded SetupIntent
  - Fires `checkout.session.completed` and `checkout.session.expired` webhook events
  - Creates PaymentMethod and fires `payment_method.attached` event on completion
- **Environment-specific port configuration**: New env vars `PAPER_TIGER_PORT_DEV` and `PAPER_TIGER_PORT_TEST` allow different ports per Mix environment. Enables running dev server and tests simultaneously without port conflicts. Precedence: `PAPER_TIGER_PORT_{ENV}` > `PAPER_TIGER_PORT` > config > 4001.
- `PaperTiger.BalanceTransactionHelper` module for creating balance transactions with Stripe-compatible fee calculations

### Removed

- **PaymentMethod raw card number support tests**: Tests using raw card numbers don't work with real Stripe API. Use test tokens like `pm_card_visa` instead.

## [0.8.5] - 2026-01-02

### Added

- **Synchronous webhook delivery mode**: Configure `webhook_mode: :sync` to have API calls block until webhooks are delivered. Useful for testing where you need to assert on webhook side effects immediately after API calls.
- `WebhookDelivery.deliver_event_sync/2` function for explicit synchronous delivery

## [0.8.4] - 2026-01-02

### Fixed

- **Subscription items now return full price object**: `subscription.items.data[].price` is now a full price object (with `id`, `object`, `currency`, etc.) instead of just the price ID string, matching real Stripe API behavior
- Same fix applied to `subscription_item.price` when creating/updating subscription items directly
- When price doesn't exist in the store, returns a minimal price object with required fields for API compatibility

### Added

- Contract test validating subscription item price structure against real Stripe API
- `TestClient.create_product/1` and `TestClient.create_price/1` helpers for contract testing

## [0.8.3] - 2026-01-02

### Fixed

- Remove unused `cleanup_payment_method/1` function that caused warnings-as-errors CI failure

## [0.8.2] - 2026-01-02

### Fixed

- **Contract test fixes**: Tests now properly pass the API key to all stripity_stripe calls
- **PaymentMethod and Subscription tests**: Skipped for real Stripe (require tokens/pre-created prices that can't be created via API) - these test PaperTiger's convenience features
- **Clearer test mode messaging**: Contract tests now display "RUNNING AGAINST REAL STRIPE TEST API" with explicit "API key validated as TEST MODE"

## [0.8.1] - 2026-01-02

### Added

- **Live key safety guard**: `TestClient` now performs two-layer validation before running contract tests against real Stripe:
  1. Validates API key prefix (rejects `sk_live_*`, `rk_live_*`)
  2. Makes a live API call to `/v1/balance` and verifies `livemode: false`

  This prevents accidental production usage even if someone crafts a key with a fake prefix

### Fixed

- BillingEngine now retries existing open invoices instead of creating duplicates on each billing cycle
- Subscriptions correctly marked `past_due` after 4 failed payment attempts

## [0.8.0] - 2026-01-01

### Added

- `PaperTiger.BillingEngine` GenServer for subscription billing lifecycle simulation
- Processes subscriptions whose `current_period_end` has passed
- Creates invoices, payment intents, and charges automatically
- Fires all relevant telemetry events for webhook delivery (invoice.created, charge.succeeded, etc.)
- Two billing modes: `:happy_path` (all payments succeed) and `:chaos` (random failures)
- Per-customer failure simulation via `BillingEngine.simulate_failure/2`
- Configurable chaos mode with custom failure rates and decline codes
- Integrates with PaperTiger's clock modes (real, accelerated, manual)
- `invoice.upcoming` telemetry event support in TelemetryHandler
- Enable with config: `config :paper_tiger, :billing_engine, true`

## [0.7.1] - 2026-01-01

### Added

- Custom ID support for deterministic data - pass `id` parameter to create endpoints for Customer, Subscription, Invoice, Product, and Price resources
- Enables stable `stripe_id` values across database resets for testing scenarios
- `PaperTiger.Initializer` module for loading initial data from config on startup
- Config option `init_data` accepts JSON file path or inline map with products, prices, and customers
- Initial data loads automatically after ETS stores initialize, ensuring data is available before dependent apps start

## [0.7.0] - 2026-01-01

### Added

- Automatic event emission via telemetry - resource operations (create/update/delete) now automatically emit Stripe events and deliver webhooks
- `PaperTiger.TelemetryHandler` module for bridging resource operations to webhook delivery
- Comprehensive Stripe API coverage including Customers, Subscriptions, Invoices, PaymentMethods, Products, Prices, and more
- ETS-backed storage layer with concurrent reads and serialized writes
- HMAC-signed webhook delivery with exponential backoff retry logic
- Dual-mode contract testing (PaperTiger vs real Stripe API)
- Time control (real, accelerated, manual modes)
- Idempotency key support with 24-hour TTL
- Object expansion (hydrator system for nested resources)
- `PaperTiger.stripity_stripe_config/1` helper for easy stripity_stripe integration
- `PaperTiger.register_configured_webhooks/0` for automatic webhook registration from config
- Environment variable support: `PAPER_TIGER_AUTO_START` and `PAPER_TIGER_PORT`
- Phoenix integration helpers and documentation
- Interactive Livebook tutorial (`examples/getting_started.livemd`)
