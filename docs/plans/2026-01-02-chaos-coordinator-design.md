# ChaosCoordinator Design

ENA-7682: Comprehensive Chaos Testing Features

## Overview

Unified chaos testing infrastructure for PaperTiger. Consolidates payment chaos (currently in BillingEngine) with new event and API chaos capabilities.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      ChaosCoordinator                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │   Payment   │  │    Event    │  │     API     │              │
│  │    Chaos    │  │    Chaos    │  │    Chaos    │              │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘              │
│         │                │                │                     │
│  customer_overrides      event_buffer     endpoint_overrides    │
└─────────┼────────────────┼────────────────┼─────────────────────┘
          │                │                │
          ▼                ▼                ▼
   BillingEngine    TelemetryHandler    Plug.ApiChaos
          │                │                │
          ▼                ▼                ▼
   PaymentIntents   WebhookDelivery      Router
```

## Configuration API

```elixir
PaperTiger.ChaosCoordinator.configure(%{
  # Payment chaos (migrated from BillingEngine)
  payment: %{
    failure_rate: 0.1,
    decline_codes: [:card_declined, :insufficient_funds, :expired_card],
    decline_weights: %{card_declined: 0.5, insufficient_funds: 0.3, expired_card: 0.2}
  },

  # Event/webhook chaos
  events: %{
    out_of_order: true,
    duplicate_rate: 0.05,
    buffer_window_ms: 500
  },

  # API request chaos
  api: %{
    timeout_rate: 0.02,
    timeout_ms: 5000,
    rate_limit_rate: 0.01,
    error_rate: 0.01,
    endpoint_overrides: %{
      "/v1/subscriptions" => :rate_limit
    }
  }
})
```

## Components

### 1. ChaosCoordinator GenServer

Central state management for all chaos configuration.

**State:**

```elixir
%{
  config: %{
    payment: %{...},
    events: %{...},
    api: %{...}
  },
  customer_overrides: %{"cus_xxx" => :card_declined},
  event_buffer: [%{event: event, queued_at: timestamp}, ...],
  stats: %{
    payments_failed: 0,
    events_duplicated: 0,
    events_reordered: 0,
    api_timeouts: 0,
    api_rate_limits: 0,
    api_errors: 0
  }
}
```

**Public API:**

```elixir
# Configuration
configure(config) :: :ok
get_config() :: map()
reset() :: :ok

# Payment chaos (called by BillingEngine)
should_payment_fail?(customer_id) :: {:ok, :succeed} | {:ok, {:fail, decline_code}}
simulate_failure(customer_id, decline_code) :: :ok
clear_simulation(customer_id) :: :ok

# Event chaos (called by TelemetryHandler)
queue_event(event) :: :ok
flush_events() :: :ok

# API chaos (called by Plug.ApiChaos)
should_api_fail?(path) :: :ok | {:timeout, ms} | :rate_limit | :server_error

# Stats
get_stats() :: map()
```

### 2. Payment Chaos

Migrated from BillingEngine. Same logic, new home.

**Decision flow:**

1. Check customer_overrides first (deterministic per-customer failures)
2. If no override, check config.payment.failure_rate
3. If failing, select decline_code using weights or uniform distribution

**Decline codes supported:**

- Default: `card_declined`, `insufficient_funds`, `expired_card`, `processing_error`
- Extended: `do_not_honor`, `lost_card`, `stolen_card`, `fraudulent`, `authentication_required`, `incorrect_cvc`, `incorrect_zip`, `card_velocity_exceeded`, `generic_decline`, etc. (22 total)

### 3. Event Chaos

Intercepts events between TelemetryHandler and WebhookDelivery.

**Flow:**

```
TelemetryHandler emits event
        │
        ▼
ChaosCoordinator.queue_event(event)
        │
        ├── If no event chaos configured → immediate delivery
        │
        └── If event chaos enabled:
                │
                ├── Add to buffer with timestamp
                │
                ├── Maybe duplicate (based on duplicate_rate)
                │
                └── Timer fires after buffer_window_ms
                        │
                        ├── Shuffle buffer if out_of_order: true
                        │
                        └── Deliver all buffered events
```

**Chaos behaviors:**

- `out_of_order: true` - Shuffles events in buffer before release
- `duplicate_rate: 0.05` - 5% chance each event gets sent twice
- `buffer_window_ms: 500` - Hold events up to 500ms

### 4. API Chaos (Plug)

Plug middleware that randomly fails requests before they reach handlers.

```elixir
defmodule PaperTiger.Plug.ApiChaos do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case PaperTiger.ChaosCoordinator.should_api_fail?(conn.request_path) do
      :ok ->
        conn

      {:timeout, ms} ->
        Process.sleep(ms)
        conn |> send_resp(504, gateway_timeout_error()) |> halt()

      :rate_limit ->
        conn |> send_resp(429, rate_limit_error()) |> halt()

      :server_error ->
        code = Enum.random([500, 502, 503])
        conn |> send_resp(code, server_error(code)) |> halt()
    end
  end

  defp gateway_timeout_error do
    Jason.encode!(%{error: %{type: "api_error", message: "Request timed out"}})
  end

  defp rate_limit_error do
    Jason.encode!(%{error: %{type: "rate_limit_error", message: "Rate limit exceeded"}})
  end

  defp server_error(code) do
    Jason.encode!(%{error: %{type: "api_error", message: "Server error (#{code})"}})
  end
end
```

**Decision flow:**

1. Check endpoint_overrides for path-specific failures
2. Roll dice against timeout_rate, rate_limit_rate, error_rate
3. Return appropriate failure or :ok

### 5. Test Helpers

```elixir
defmodule PaperTiger.ChaosHelpers do
  @doc "Run block with temporary chaos config, reset after"
  def with_chaos(config, fun) do
    original = PaperTiger.ChaosCoordinator.get_config()
    PaperTiger.ChaosCoordinator.configure(config)
    try do
      fun.()
    after
      PaperTiger.ChaosCoordinator.configure(original)
    end
  end
end
```

## Migration from BillingEngine

BillingEngine currently has:

- `@default_decline_codes` / `@extended_decline_codes`
- `@default_chaos_config`
- `set_mode/2`, `get_mode/0`
- `simulate_failure/2`, `clear_simulation/1`
- `determine_payment_result/1`

**Migration steps:**

1. Move decline code constants to ChaosCoordinator
2. Move chaos config and simulation state to ChaosCoordinator
3. BillingEngine calls `ChaosCoordinator.should_payment_fail?/1`
4. Keep `BillingEngine.set_mode/2` as thin wrapper that calls `ChaosCoordinator.configure/1`
5. Deprecate direct chaos methods on BillingEngine (delegate to ChaosCoordinator)

## Implementation Order

1. **ChaosCoordinator GenServer** - Core state management, payment chaos API
2. **Migrate BillingEngine** - Delegate chaos decisions to ChaosCoordinator
3. **Event chaos** - Buffer, reorder, duplicate logic
4. **TelemetryHandler integration** - Route events through ChaosCoordinator
5. **Plug.ApiChaos** - HTTP-level chaos
6. **Router integration** - Add plug to pipeline
7. **Test helpers** - `with_chaos/2` and friends
8. **Tests** - Comprehensive coverage for each chaos type

## Testing Strategy

Each chaos type needs:

1. Unit tests for the chaos logic itself
2. Integration tests showing end-to-end behavior
3. Stats validation (chaos was actually applied)

**Example tests:**

```elixir
describe "event chaos" do
  test "out_of_order shuffles events" do
    ChaosCoordinator.configure(%{events: %{out_of_order: true, buffer_window_ms: 100}})

    # Queue events in order
    for i <- 1..10, do: ChaosCoordinator.queue_event(event(i))

    # Wait for buffer release
    Process.sleep(150)

    # Verify events were delivered out of order
    delivered = get_delivered_events()
    assert delivered != Enum.sort_by(delivered, & &1.created)
  end

  test "duplicate_rate sends some events twice" do
    ChaosCoordinator.configure(%{events: %{duplicate_rate: 1.0}})  # 100% dupes

    ChaosCoordinator.queue_event(event())
    ChaosCoordinator.flush_events()

    assert length(get_delivered_events()) == 2
  end
end
```

## Backwards Compatibility

- `BillingEngine.set_mode/2` continues to work (delegates to ChaosCoordinator)
- `BillingEngine.simulate_failure/2` continues to work (delegates)
- Existing tests pass without modification
- New chaos features are opt-in via `ChaosCoordinator.configure/1`
