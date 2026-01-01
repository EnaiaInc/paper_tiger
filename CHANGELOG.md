# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
