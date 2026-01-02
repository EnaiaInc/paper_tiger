# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
