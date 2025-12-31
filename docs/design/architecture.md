# PaperTiger - Design Document

**Date:** 2025-12-31
**Status:** Design Phase
**Type:** New OSS Library
**Tagline:** _"A paper tiger of a Stripe server—looks fierce, completely harmless"_

## Executive Summary

**PaperTiger** is a stateful mock Stripe server for testing Elixir applications. Inspired by Python's [localstripe](https://github.com/adrienverge/localstripe), PaperTiger is not a port—it's a complete redesign leveraging Elixir's strengths (OTP, ETS, concurrency) to create a superior testing tool for the Elixir community.

**Name Origin:** A "paper tiger" appears powerful but is harmless—perfect for a mock Stripe server. Plus, tigers have **stripes**! 🐯

**Target Release:** Hex package as standalone OSS library
**Package Name:** `paper_tiger`
**Module:** `PaperTiger`

**Primary Use Cases:**

- PR app environments (ephemeral test deployments)
- Local development for all developers
- Integration test suites
- Unit tests with mocked Stripe

**Key Improvements Over Python localstripe:**

- OTP supervision tree (fault tolerance)
- ETS-backed storage (concurrent, fast)
- Controllable time system (accelerate 30-day tests to milliseconds)
- Configurable behavior (static vs simulated)
- First-class ExUnit integration
- End-to-end test suite
- Native Elixir idioms (structs, pattern matching, behaviours)

## Problem Statement

### The Stripe Testing Nightmare

Testing Stripe integrations is **painful**. There are no good options:

**Option 1: Shared Stripe Test Mode** ❌

- All environments share one test mode
- Webhook collisions: PR apps receive each other's webhooks
- Data pollution: can't isolate test data
- Race conditions: parallel tests interfere with each other

**Option 2: Stripe Sandboxes** ❌

- Max **5 sandboxes** per account (not enough for all PR apps)
- Dashboard-only creation (no API for programmatic provisioning)
- Manual management hell
- Stripe Insiders has open request for sandbox API (not available)

**Option 3: Stateless Mocks (stripe-mock)** ❌

- Hardcoded responses
- No state: create customer → can't retrieve it
- **No webhooks** (the main pain point!)
- Can't test real-world flows

**Option 4: Test Clocks API** ⚠️

- Limits: 3 customers, 3 subscriptions per clock
- Auto-delete after 30 days
- Still uses shared test mode (webhook collision problem)
- Helps with time, not isolation

### Real-World Impact

**Example: Referral Credits Feature (ENA-XXXX)**

- User converts from trial → paid subscription
- Triggers `invoice.payment_succeeded` webhook
- Awards referral credit to referring user
- **Cannot test in PR apps** because:
  - MockStripe doesn't send webhooks
  - Shared test mode → webhooks go to wrong environment
  - QA blocked from black-box testing

### What We Need

A **stateful, isolated mock Stripe server** that:

- ✅ Maintains state across requests (like real Stripe)
- ✅ Sends real webhooks with proper signatures
- ✅ Runs per-environment (no shared state)
- ✅ Supports time travel (test 30-day billing cycles in seconds)
- ✅ Works offline (no external dependencies)
- ✅ Easy to run (Docker/embedded)

**PaperTiger solves this.**

## Goals

### Primary Goals

1. **Full Stripe API Coverage** - Support 28+ resources matching Python localstripe
2. **Production Quality** - Enterprise-grade tooling from day one (Credo, Dialyzer, Quokka, CI)
3. **Better DX** - ExUnit helpers, time control, easy configuration
4. **Community OSS** - Publish to Hex, comprehensive docs, examples

### Non-Goals

- Stripe Connect support (not in Python version either)
- 100% API compatibility with every Stripe version (latest API only)
- Real payment processing (mock only)

## Architecture

### Technology Stack

**HTTP Layer:**

- [Bandit](https://hex.pm/packages/bandit) `~> 1.6` - Modern HTTP/2 server
- [Plug](https://hex.pm/packages/plug) `~> 1.16` - Request routing and middleware
- [Req](https://hex.pm/packages/req) `~> 0.5` - HTTP client for webhooks

**Core:**

- OTP GenServers for store management
- ETS tables for fast concurrent storage
- Task.Supervisor for async webhook delivery

**Quality:**

- [Credo](https://hex.pm/packages/credo) `~> 1.7` - Static analysis
- [Dialyxir](https://hex.pm/packages/dialyxir) `~> 1.4` - Type checking
- [Quokka](https://hex.pm/packages/quokka) `~> 2.7` - Auto-formatting
- [ExCoveralls](https://hex.pm/packages/excoveralls) `~> 0.18` - Test coverage
- Multi-version CI matrix (Elixir 1.16-1.18, OTP 26-28)

### Supervision Tree

```
PaperTiger.Application (Supervisor)
├── PaperTiger.Clock (GenServer)
│   └── Controls time (real/accelerated/manual modes)
│
├── PaperTiger.Idempotency (GenServer + ETS)
│   └── Prevents duplicate requests (24hr TTL)
│
├── PaperTiger.Store.Supervisor (Supervisor)
│   ├── PaperTiger.Store.Customers (GenServer + ETS)
│   ├── PaperTiger.Store.Subscriptions (GenServer + ETS)
│   ├── PaperTiger.Store.Invoices (GenServer + ETS)
│   ├── PaperTiger.Store.PaymentMethods (GenServer + ETS)
│   └── ... (24 more resource stores)
│
├── Task.Supervisor [PaperTiger.Webhook.Supervisor]
│   └── Async webhook delivery tasks
│
├── PaperTiger.Workers.SubscriptionRenewer (GenServer, optional)
│   └── Only starts if time_mode: :simulated
│   └── Handles time jumps: calculates delta, applies instantly
│
├── PaperTiger.Workers.InvoiceFinalizer (GenServer, optional)
│   └── Only starts if time_mode: :simulated
│   └── Handles time jumps: calculates delta, applies instantly
│
└── Bandit HTTP Server
    └── Serves PaperTiger.Router (Plug.Router)
```

**Fault Isolation:**

- Webhook failures don't affect storage
- Store crashes only reset that resource type
- HTTP crashes don't lose ETS data
- Independent worker restarts

## Core Systems

### 1. Resource Modeling

Each Stripe resource is a strict struct with a behaviour contract:

```elixir
defmodule PaperTiger.Resource do
  @callback create(attrs :: map()) :: {:ok, struct()} | {:error, term()}
  @callback retrieve(id :: String.t()) :: {:ok, struct()} | {:error, :not_found}
  @callback update(id :: String.t(), attrs :: map()) :: {:ok, struct()} | {:error, term()}
  @callback delete(id :: String.t()) :: {:ok, struct()} | {:error, term()}
  @callback list(filters :: map()) :: {:ok, PaperTiger.List.t()}
end

defmodule PaperTiger.Customer do
  @behaviour PaperTiger.Resource

  @enforce_keys [:id, :object, :created, :livemode]
  defstruct [
    :id, :object, :created, :livemode,
    :email, :name, :description, :default_source,
    :metadata, :subscriptions
  ]

  def create(attrs) do
    customer = %__MODULE__{
      id: generate_id("cus_"),
      object: "customer",
      created: PaperTiger.Clock.now(),
      livemode: false,
      email: attrs["email"],
      metadata: attrs["metadata"] || %{}
    }

    PaperTiger.Store.Customers.insert(customer)
    PaperTiger.Webhook.trigger("customer.created", customer)
    {:ok, customer}
  end

  # ... retrieve, update, delete, list
end
```

**28 Resources to Implement:**

- Customer, Subscription, SubscriptionItem, Invoice, InvoiceItem
- PaymentMethod, PaymentIntent, SetupIntent, Charge, Refund
- Product, Price, Plan (legacy), Coupon, TaxRate
- Source, Token, Card, BalanceTransaction, Payout
- Event, Webhook, List (pagination helper)
- Checkout Session (for Stripe Checkout flow)
- Plus 6 more from Python version

### 2. Storage Layer

Each resource type gets a GenServer wrapping an ETS table:

```elixir
defmodule PaperTiger.Store.Customers do
  use GenServer

  @table :paper_tiger_customers

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  # Public API
  # CRITICAL: Reads go directly to ETS (concurrent), writes go through GenServer (serialized)
  def get(id) do
    case :ets.lookup(@table, id) do
      [{^id, customer}] -> {:ok, customer}
      [] -> {:error, :not_found}
    end
  end

  def insert(customer), do: GenServer.call(__MODULE__, {:insert, customer})
  def update(customer), do: GenServer.call(__MODULE__, {:update, customer})
  def delete(id), do: GenServer.call(__MODULE__, {:delete, id})
  def clear(), do: GenServer.call(__MODULE__, :clear)

  # Query helpers (direct ETS access)
  def find_by_email(email) do
    :ets.match_object(@table, {:_, %{email: email}})
  end

  def list(opts \\ %{}) do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, customer} -> customer end)
    |> PaperTiger.List.paginate(opts)
  end

  # GenServer callbacks (only writes are serialized)
  def handle_call({:insert, customer}, _from, state) do
    :ets.insert(@table, {customer.id, customer})
    {:reply, {:ok, customer}, state}
  end

  def handle_call({:update, customer}, _from, state) do
    :ets.insert(@table, {customer.id, customer})
    {:reply, {:ok, customer}, state}
  end

  def handle_call({:delete, id}, _from, state) do
    :ets.delete(@table, id)
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end
end
```

**Optional Persistence:**

```elixir
# config/dev.exs
config :paper_tiger,
  persist_state: true,
  persistence_dir: ".paper_tiger/data"  # Relative to project root (gitignored)

# config/pr_app.exs
config :paper_tiger,
  persist_state: true,
  persistence_dir: System.get_env("PAPER_TIGER_DATA_DIR") || "/data/paper_tiger"

# config/test.exs
config :paper_tiger, persist_state: false  # Always start fresh
```

**Persistence Implementation (DETS):**

```elixir
defmodule PaperTiger.Store.Persistence do
  @moduledoc "Handles saving/loading ETS tables to/from disk using DETS"

  def persist_on_shutdown do
    if Application.get_env(:paper_tiger, :persist_state, false) do
      dir = persistence_dir()
      File.mkdir_p!(dir)

      PaperTiger.Store.list_stores()
      |> Enum.each(fn store_module ->
        table_name = store_module.table_name()
        file_path = Path.join(dir, "#{table_name}.dets")

        {:ok, dets} = :dets.open_file(String.to_atom(file_path), [file: String.to_charlist(file_path)])
        :ets.to_dets(table_name, dets)
        :dets.close(dets)
      end)
    end
  end

  def load_on_startup(table_name) do
    if Application.get_env(:paper_tiger, :persist_state, false) do
      dir = persistence_dir()
      file_path = Path.join(dir, "#{table_name}.dets")

      if File.exists?(file_path) do
        {:ok, dets} = :dets.open_file(String.to_atom(file_path), [file: String.to_charlist(file_path)])
        :dets.to_ets(dets, table_name)
        :dets.close(dets)
      end
    end
  end

  defp persistence_dir do
    Application.get_env(:paper_tiger, :persistence_dir, ".paper_tiger/data")
    |> Path.expand()
  end
end
```

### 3. Time Control System

The killer feature—controllable time for testing:

```elixir
defmodule PaperTiger.Clock do
  use GenServer

  @moduledoc """
  Manages time for PaperTiger. Three modes:

  - :real - Uses System.system_time(:second)
  - :accelerated - Real time × multiplier (1 real sec = 100 PaperTiger secs)
  - :manual - Frozen time, advance via PaperTiger.advance_time/1
  """

  def init(_) do
    mode = Application.get_env(:paper_tiger, :time_mode, :real)
    multiplier = Application.get_env(:paper_tiger, :time_multiplier, 1)

    state = %{
      mode: mode,
      multiplier: multiplier,
      offset: 0,
      started_at: System.system_time(:second)
    }

    {:ok, state}
  end

  def now, do: GenServer.call(__MODULE__, :now)

  def advance(seconds) when is_integer(seconds) do
    GenServer.call(__MODULE__, {:advance, seconds})
  end

  def handle_call(:now, _from, %{mode: :real} = state) do
    {:reply, System.system_time(:second), state}
  end

  def handle_call(:now, _from, %{mode: :accelerated, multiplier: m, started_at: start, offset: offset} = state) do
    elapsed = System.system_time(:second) - start
    accelerated_time = start + (elapsed * m) + offset
    {:reply, accelerated_time, state}
  end

  def handle_call(:now, _from, %{mode: :manual, started_at: start, offset: offset} = state) do
    {:reply, start + offset, state}
  end

  def handle_call({:advance, seconds}, _from, state) do
    {:reply, :ok, %{state | offset: state.offset + seconds}}
  end
end
```

**Usage in tests:**

```elixir
test "subscription renews after 30 days" do
  # Create monthly subscription
  {:ok, sub} = Stripe.Subscription.create(%{
    customer: customer.id,
    items: [%{price: monthly_price.id}]
  })

  # Fast-forward 30 days instantly
  PaperTiger.advance_time(days: 30)

  # Subscription period should have advanced
  updated_sub = Stripe.Subscription.retrieve(sub.id)
  assert updated_sub.current_period_start > sub.current_period_start

  # Invoice created and payment attempted
  assert_receive_webhook("invoice.payment_succeeded")
end
```

**Configuration:**

```elixir
# config/test.exs
config :paper_tiger, time_mode: :manual  # Full control in tests

# config/int_test.exs
config :paper_tiger,
  time_mode: :accelerated,
  time_multiplier: 100  # 1 real sec = 100 Stripe secs

# config/pr_app.exs
config :paper_tiger, time_mode: :real  # Realistic behavior
```

### 4. Object Expansion System (CRITICAL)

Stripe allows expanding related objects via `expand[]=customer`. This is mandatory for testing real integrations.

**Problem:** When a Subscription references a Customer, the response can be either:

- String ID: `{"customer": "cus_123"}`
- Expanded object: `{"customer": {"id": "cus_123", "email": "...", ...}}`

**Solution:** Hydrator layer in response rendering.

```elixir
defmodule PaperTiger.Hydrator do
  @moduledoc """
  Expands nested object references based on expand[] query params.

  Example:
    expand[]=customer&expand[]=customer.default_source
  """

  def hydrate(resource, expand_params) when is_list(expand_params) do
    Enum.reduce(expand_params, resource, fn path, acc ->
      expand_path(acc, String.split(path, "."))
    end)
  end

  defp expand_path(resource, [field]) do
    case Map.get(resource, String.to_atom(field)) do
      id when is_binary(id) and byte_size(id) > 0 ->
        # Fetch from appropriate store based on ID prefix
        case fetch_by_id(id) do
          {:ok, expanded} -> Map.put(resource, String.to_atom(field), expanded)
          _error -> resource  # Leave as ID if not found
        end
      _not_expandable -> resource
    end
  end

  defp expand_path(resource, [field | rest]) do
    # Nested expansion: customer.default_source
    case Map.get(resource, String.to_atom(field)) do
      id when is_binary(id) ->
        case fetch_by_id(id) do
          {:ok, expanded} ->
            nested = expand_path(expanded, rest)
            Map.put(resource, String.to_atom(field), nested)
          _error -> resource
        end
      already_expanded when is_map(already_expanded) ->
        nested = expand_path(already_expanded, rest)
        Map.put(resource, String.to_atom(field), nested)
      _other -> resource
    end
  end

  defp fetch_by_id("cus_" <> _rest = id), do: PaperTiger.Store.Customers.get(id)
  defp fetch_by_id("sub_" <> _rest = id), do: PaperTiger.Store.Subscriptions.get(id)
  defp fetch_by_id("pm_" <> _rest = id), do: PaperTiger.Store.PaymentMethods.get(id)
  defp fetch_by_id("price_" <> _rest = id), do: PaperTiger.Store.Prices.get(id)
  defp fetch_by_id("prod_" <> _rest = id), do: PaperTiger.Store.Products.get(id)
  defp fetch_by_id("card_" <> _rest = id), do: PaperTiger.Store.Cards.get(id)
  defp fetch_by_id("src_" <> _rest = id), do: PaperTiger.Store.Sources.get(id)
  # ... add all resource prefixes
  defp fetch_by_id(_unknown), do: {:error, :not_found}
end
```

**Usage in Router:**

```elixir
defmodule PaperTiger.Resources.Subscription do
  def retrieve(conn, %{"id" => id}) do
    with {:ok, sub} <- PaperTiger.Store.Subscriptions.get(id),
         expand_params <- parse_expand_params(conn.query_params),
         hydrated <- PaperTiger.Hydrator.hydrate(sub, expand_params) do
      json(conn, 200, hydrated)
    end
  end

  defp parse_expand_params(%{"expand" => expand}) when is_list(expand), do: expand
  defp parse_expand_params(%{"expand[]" => expand}) when is_list(expand), do: expand
  defp parse_expand_params(%{"expand" => expand}) when is_binary(expand), do: [expand]
  defp parse_expand_params(_), do: []
end
```

**Test Example:**

```elixir
test "expand customer and default source" do
  {:ok, customer} = Stripe.Customer.create(%{email: "test@example.com"})
  {:ok, card} = Stripe.Card.create(customer.id, %{number: "4242..."})
  {:ok, _} = Stripe.Customer.update(customer.id, %{default_source: card.id})

  # Without expansion
  {:ok, sub} = Stripe.Subscription.create(%{customer: customer.id, ...})
  assert is_binary(sub.customer)  # "cus_123"

  # With expansion
  {:ok, sub} = Stripe.Subscription.retrieve(sub.id, expand: ["customer"])
  assert is_map(sub.customer)  # Full customer object
  assert sub.customer.email == "test@example.com"

  # Nested expansion
  {:ok, sub} = Stripe.Subscription.retrieve(sub.id, expand: ["customer.default_source"])
  assert is_map(sub.customer.default_source)  # Full card object
  assert sub.customer.default_source.last4 == "4242"
end
```

### 5. Idempotency System (CRITICAL)

Stripe's idempotency mechanism prevents duplicate charges from network retries. This is mandatory for payment testing.

```elixir
defmodule PaperTiger.Idempotency do
  use GenServer

  @table :paper_tiger_idempotency
  @ttl_seconds 24 * 60 * 60  # 24 hours (matches Stripe)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @doc "Check if request with this idempotency key has been processed"
  def check(idempotency_key) when is_binary(idempotency_key) do
    case :ets.lookup(@table, idempotency_key) do
      [{^idempotency_key, response, _expires_at}] -> {:cached, response}
      [] -> :new_request
    end
  end

  @doc "Store response for idempotency key"
  def store(idempotency_key, response) when is_binary(idempotency_key) do
    expires_at = PaperTiger.Clock.now() + @ttl_seconds
    :ets.insert(@table, {idempotency_key, response, expires_at})
    :ok
  end

  # Cleanup expired entries every hour
  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, :timer.hours(1))
  end

  def handle_info(:cleanup, state) do
    now = PaperTiger.Clock.now()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_cleanup()
    {:noreply, state}
  end
end
```

**Idempotency Plug:**

```elixir
defmodule PaperTiger.Plugs.Idempotency do
  @moduledoc "Handles Stripe Idempotency-Key header"
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    # Only applies to POST requests
    if conn.method == "POST" do
      case get_req_header(conn, "idempotency-key") do
        [key] -> handle_idempotency(conn, key)
        [] -> conn  # No idempotency key, proceed normally
      end
    else
      conn
    end
  end

  defp handle_idempotency(conn, key) do
    case PaperTiger.Idempotency.check(key) do
      {:cached, response} ->
        # Return cached response
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(response))
        |> halt()

      :new_request ->
        # Register callback to store response after request completes
        register_before_send(conn, fn conn ->
          if conn.status in 200..299 do
            # Extract response body and cache it
            {:ok, body} = Jason.decode(conn.resp_body)
            PaperTiger.Idempotency.store(key, body)
          end
          conn
        end)
    end
  end
end
```

**Add to router:**

```elixir
plug PaperTiger.Plugs.Idempotency  # Before :dispatch
```

**Test Example:**

```elixir
test "idempotency prevents duplicate charges" do
  key = "test-#{:rand.uniform(1_000_000)}"

  # First request creates charge
  {:ok, charge1} = Stripe.Charge.create(
    %{amount: 1000, currency: "usd", source: "tok_visa"},
    idempotency_key: key
  )

  # Retry with same key returns same charge (no duplicate)
  {:ok, charge2} = Stripe.Charge.create(
    %{amount: 1000, currency: "usd", source: "tok_visa"},
    idempotency_key: key
  )

  assert charge1.id == charge2.id

  # Different key creates new charge
  {:ok, charge3} = Stripe.Charge.create(
    %{amount: 1000, currency: "usd", source: "tok_visa"},
    idempotency_key: "different-key"
  )

  assert charge3.id != charge1.id
end
```

### 6. Search & Pagination System

Stripe's list API uses cursor-based pagination with `starting_after`, `ending_before`, and `limit`.

```elixir
defmodule PaperTiger.List do
  @moduledoc "Handles Stripe-style pagination for list endpoints"

  defstruct [
    :object,
    :data,
    :has_more,
    :url
  ]

  @default_limit 10
  @max_limit 100

  def paginate(items, opts \\ %{}) when is_list(items) do
    limit = min(opts[:limit] || @default_limit, @max_limit)
    starting_after = opts[:starting_after]
    ending_before = opts[:ending_before]

    # Sort by created timestamp descending (newest first, like Stripe)
    sorted = Enum.sort_by(items, & &1.created, :desc)

    # Apply cursor filtering
    filtered = apply_cursor(sorted, starting_after, ending_before)

    # Take limit + 1 to check if there are more results
    page = Enum.take(filtered, limit + 1)

    has_more = length(page) > limit
    data = Enum.take(page, limit)

    %__MODULE__{
      object: "list",
      data: data,
      has_more: has_more,
      url: opts[:url] || "/v1/unknown"
    }
  end

  defp apply_cursor(items, nil, nil), do: items

  defp apply_cursor(items, starting_after, nil) when is_binary(starting_after) do
    # Return items after the specified ID
    Enum.drop_while(items, fn item ->
      item.id != starting_after
    end)
    |> Enum.drop(1)  # Drop the cursor item itself
  end

  defp apply_cursor(items, nil, ending_before) when is_binary(ending_before) do
    # Return items before the specified ID
    Enum.take_while(items, fn item ->
      item.id != ending_before
    end)
  end

  defp apply_cursor(items, _starting_after, ending_before) do
    # If both provided, ending_before takes precedence (matches Stripe behavior)
    apply_cursor(items, nil, ending_before)
  end
end
```

**Usage in Store:**

```elixir
defmodule PaperTiger.Store.Customers do
  def list(opts \\ %{}) do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, customer} -> customer end)
    |> PaperTiger.List.paginate(Map.put(opts, :url, "/v1/customers"))
  end
end
```

**Test Example:**

```elixir
test "pagination with starting_after" do
  # Create 25 customers
  customers = for i <- 1..25 do
    {:ok, c} = Stripe.Customer.create(%{email: "user#{i}@test.com"})
    c
  end

  # First page (default limit: 10)
  {:ok, page1} = Stripe.Customer.list()
  assert length(page1.data) == 10
  assert page1.has_more == true

  # Second page using cursor
  last_id = List.last(page1.data).id
  {:ok, page2} = Stripe.Customer.list(starting_after: last_id)
  assert length(page2.data) == 10
  assert page2.has_more == true

  # Third page
  last_id = List.last(page2.data).id
  {:ok, page3} = Stripe.Customer.list(starting_after: last_id)
  assert length(page3.data) == 5
  assert page3.has_more == false
end
```

### 7. Webhook System

Async delivery with HMAC-SHA256 signing (exactly like Stripe):

```elixir
defmodule PaperTiger.Webhook do
  defstruct [:id, :url, :secret, :events]

  def register(id, url, secret, events \\ nil) do
    webhook = %__MODULE__{id: id, url: url, secret: secret, events: events}
    PaperTiger.Store.Webhooks.insert(webhook)
  end

  def trigger(event_type, data_object) do
    event = PaperTiger.Event.create(event_type, data_object)
    PaperTiger.Store.Events.insert(event)

    PaperTiger.Store.Webhooks.list()
    |> Enum.filter(&should_deliver?(&1, event_type))
    |> Enum.each(&dispatch_async(&1, event))
  end

  defp dispatch_async(webhook, event) do
    Task.Supervisor.start_child(PaperTiger.Webhook.Supervisor, fn ->
      deliver(webhook, event)
    end)
  end

  defp deliver(webhook, event) do
    payload = Jason.encode!(event)
    timestamp = event.created
    signature = sign_payload(payload, timestamp, webhook.secret)

    Req.post!(webhook.url,
      json: payload,
      headers: [
        {"stripe-signature", "t=#{timestamp},v1=#{signature}"}
      ],
      retry: false
    )
  end

  defp sign_payload(payload, timestamp, secret) do
    signed_payload = "#{timestamp}.#{payload}"
    :crypto.mac(:hmac, :sha256, secret, signed_payload)
    |> Base.encode16(case: :lower)
  end
end
```

**Webhook events supported:**

- `customer.created`, `customer.updated`, `customer.deleted`
- `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`
- `invoice.created`, `invoice.payment_succeeded`, `invoice.payment_failed`
- `payment_method.attached`, `payment_intent.succeeded`, `payment_intent.payment_failed`
- `product.created`, `plan.created`, `customer.source.created`
- Plus ~15 more to match Python version

### 8. HTTP Router

DRY macro-based routing with flexible action support:

```elixir
defmodule PaperTiger.Router do
  use Plug.Router

  plug :match
  plug PaperTiger.Plugs.Auth
  plug PaperTiger.Plugs.CORS
  plug PaperTiger.Plugs.Idempotency  # CRITICAL: Must come before :dispatch
  plug PaperTiger.Plugs.UnflattenParams  # card[number] -> %{card: %{number: ...}}
  plug :dispatch

  # Macro generates 5 routes per resource (create, retrieve, update, delete, list)
  # Supports :only and :except options for resources that don't follow full CRUD
  defmacro stripe_resource(path, module, opts \\ []) do
    all_actions = [:create, :retrieve, :update, :delete, :list]
    only = opts[:only]
    except = opts[:except] || []

    actions = if only, do: only, else: all_actions -- except

    quote do
      unquote(
        for action <- actions do
          case action do
            :create ->
              quote do
                post unquote("/v1/#{path}"), to: unquote(module), init_opts: [action: :create]
              end
            :retrieve ->
              quote do
                get unquote("/v1/#{path}/:id"), to: unquote(module), init_opts: [action: :retrieve]
              end
            :update ->
              quote do
                post unquote("/v1/#{path}/:id"), to: unquote(module), init_opts: [action: :update]
              end
            :delete ->
              quote do
                delete unquote("/v1/#{path}/:id"), to: unquote(module), init_opts: [action: :delete]
              end
            :list ->
              quote do
                get unquote("/v1/#{path}"), to: unquote(module), init_opts: [action: :list]
              end
          end
        end
      )
    end
  end

  # Standard CRUD resources
  stripe_resource "customers", PaperTiger.Resources.Customer
  stripe_resource "subscriptions", PaperTiger.Resources.Subscription
  stripe_resource "invoices", PaperTiger.Resources.Invoice
  stripe_resource "payment_methods", PaperTiger.Resources.PaymentMethod
  stripe_resource "products", PaperTiger.Resources.Product
  stripe_resource "prices", PaperTiger.Resources.Price

  # Charges: create, retrieve, list only (no delete, update is partial)
  stripe_resource "charges", PaperTiger.Resources.Charge, only: [:create, :retrieve, :list, :update]

  # Refunds: create, retrieve, list only
  stripe_resource "refunds", PaperTiger.Resources.Refund, only: [:create, :retrieve, :list]

  # Payouts: no delete
  stripe_resource "payouts", PaperTiger.Resources.Payout, except: [:delete]

  # ... 20 more resources

  # Custom endpoints (non-CRUD)
  post "/v1/subscriptions/:id/cancel", to: PaperTiger.Resources.Subscription, init_opts: [action: :cancel]
  get "/v1/invoices/upcoming", to: PaperTiger.Resources.Invoice, init_opts: [action: :upcoming]
  post "/v1/checkout/sessions", to: PaperTiger.Resources.CheckoutSession, init_opts: [action: :create]
  post "/v1/payment_methods/:id/attach", to: PaperTiger.Resources.PaymentMethod, init_opts: [action: :attach]
  post "/v1/payment_methods/:id/detach", to: PaperTiger.Resources.PaymentMethod, init_opts: [action: :detach]

  # Config endpoints for test orchestration
  post "/_config/webhooks/:id", to: PaperTiger.Config, init_opts: [action: :register_webhook]
  delete "/_config/data", to: PaperTiger.Config, init_opts: [action: :flush_all]
  post "/_config/time/advance", to: PaperTiger.Config, init_opts: [action: :advance_time]

  # Stripe.js mock script
  get "/js.stripe.com/v3/", to: PaperTiger.JS, init_opts: []
end
```

### 6. Error Handling

Stripe-compatible error responses:

```elixir
defmodule PaperTiger.Error do
  defexception [:type, :message, :code, :param, :status]

  def invalid_request(message, param \\ nil) do
    %__MODULE__{
      type: "invalid_request_error",
      message: message,
      param: param,
      status: 400
    }
  end

  def not_found(resource_type, id) do
    %__MODULE__{
      type: "invalid_request_error",
      message: "No such #{resource_type}: '#{id}'",
      status: 404
    }
  end

  def card_declined(code \\ "card_declined") do
    %__MODULE__{
      type: "card_error",
      code: code,
      message: "Your card was declined.",
      status: 402
    }
  end

  def to_json(%__MODULE__{} = error) do
    %{
      error: %{
        type: error.type,
        message: error.message,
        code: error.code,
        param: error.param
      }
    }
  end
end
```

### 7. ExUnit Integration

First-class test helpers:

```elixir
defmodule PaperTiger.Case do
  use ExUnit.CaseTemplate

  using do
    quote do
      import PaperTiger.Test.Helpers

      setup do
        PaperTiger.flush()
        :ok
      end
    end
  end
end

defmodule PaperTiger.Test.Helpers do
  def assert_receive_webhook(event_type, timeout \\ 1000, assertion_fn \\ nil) do
    # Wait for webhook delivery
  end

  def create_customer(attrs \\ %{}) do
    PaperTiger.Resources.Customer.create(attrs)
  end

  # ... more helpers
end
```

**Usage:**

```elixir
defmodule MyAppTest do
  use ExUnit.Case
  use PaperTiger.Case

  setup do
    # Configure stripity_stripe to use PaperTiger
    Application.put_env(:stripity_stripe, :api_base_url, "http://localhost:4444")

    # Register webhook for this test
    PaperTiger.register_webhook(
      url: "http://localhost:4000/stripe/webhook",
      secret: "whsec_test123",
      events: ["customer.subscription.created"]
    )

    :ok
  end

  test "creating subscription triggers webhook" do
    {:ok, customer} = Stripe.Customer.create(%{email: "test@example.com"})
    {:ok, sub} = Stripe.Subscription.create(%{
      customer: customer.id,
      items: [%{price: "price_123"}]
    })

    assert_receive_webhook("customer.subscription.created", fn event ->
      assert event.data.object.id == sub.id
    end)
  end
end
```

### 8. End-to-End Testing

**Critical:** PaperTiger must have comprehensive end-to-end tests that validate complete workflows.

```elixir
defmodule PaperTiger.E2ETest do
  use ExUnit.Case
  use PaperTiger.Case

  @moduletag :e2e

  describe "complete subscription lifecycle" do
    setup do
      # Start PaperTiger with webhook receiver
      {:ok, webhook_pid} = start_webhook_receiver()

      PaperTiger.register_webhook(
        url: "http://localhost:#{webhook_port()}",
        secret: "whsec_test_secret",
        events: nil  # All events
      )

      %{webhook_pid: webhook_pid}
    end

    test "customer creates subscription, adds payment, subscription activates" do
      # Step 1: Create customer
      {:ok, customer} = Stripe.Customer.create(%{
        email: "test@example.com",
        name: "Test User"
      })

      assert_webhook_received("customer.created", fn event ->
        assert event.data.object.id == customer.id
      end)

      # Step 2: Create product and price
      {:ok, product} = Stripe.Product.create(%{name: "Pro Plan"})
      {:ok, price} = Stripe.Price.create(%{
        product: product.id,
        unit_amount: 2000,
        currency: "usd",
        recurring: %{interval: "month"}
      })

      # Step 3: Create subscription (starts in incomplete status)
      {:ok, sub} = Stripe.Subscription.create(%{
        customer: customer.id,
        items: [%{price: price.id}],
        payment_behavior: "default_incomplete"
      })

      assert sub.status == "incomplete"
      assert_webhook_received("customer.subscription.created")

      # Step 4: Add payment method
      {:ok, pm} = Stripe.PaymentMethod.create(%{
        type: "card",
        card: %{number: "4242424242424242", exp_month: 12, exp_year: 2030, cvc: "123"}
      })

      {:ok, _pm} = Stripe.PaymentMethod.attach(pm.id, %{customer: customer.id})
      assert_webhook_received("payment_method.attached")

      # Step 5: Subscription should auto-activate
      updated_sub = Stripe.Subscription.retrieve(sub.id)
      assert updated_sub.status == "active"

      # Step 6: Invoice should be created and paid
      assert_webhook_received("invoice.created")
      assert_webhook_received("invoice.payment_succeeded")

      # Step 7: Fast-forward 30 days, subscription should renew
      PaperTiger.advance_time(days: 30)

      # New invoice created for renewal
      assert_webhook_received("invoice.created")
      assert_webhook_received("customer.subscription.updated")

      # Step 8: Cancel subscription
      {:ok, canceled_sub} = Stripe.Subscription.delete(sub.id)
      assert canceled_sub.status == "canceled"
      assert_webhook_received("customer.subscription.deleted")
    end

    test "failed payment triggers proper webhooks and subscription status" do
      {:ok, customer} = Stripe.Customer.create(%{email: "fail@example.com"})
      {:ok, product} = Stripe.Product.create(%{name: "Test Plan"})
      {:ok, price} = Stripe.Price.create(%{
        product: product.id,
        unit_amount: 1000,
        currency: "usd",
        recurring: %{interval: "month"}
      })

      # Create subscription
      {:ok, sub} = Stripe.Subscription.create(%{
        customer: customer.id,
        items: [%{price: price.id}]
      })

      # Attach failing card
      {:ok, pm} = Stripe.PaymentMethod.create(%{
        type: "card",
        card: %{number: "4000000000000341", exp_month: 12, exp_year: 2030, cvc: "123"}
      })

      {:ok, _} = Stripe.PaymentMethod.attach(pm.id, %{customer: customer.id})

      # Payment should fail
      assert_webhook_received("invoice.payment_failed")

      # Subscription should be past_due
      updated_sub = Stripe.Subscription.retrieve(sub.id)
      assert updated_sub.status == "past_due"
    end

    test "checkout session complete flow" do
      {:ok, product} = Stripe.Product.create(%{name: "Test Product"})
      {:ok, price} = Stripe.Price.create(%{
        product: product.id,
        unit_amount: 5000,
        currency: "usd",
        recurring: %{interval: "month"}
      })

      # Create checkout session
      {:ok, session} = Stripe.CheckoutSession.create(%{
        mode: "subscription",
        line_items: [%{price: price.id, quantity: 1}],
        success_url: "https://example.com/success",
        cancel_url: "https://example.com/cancel"
      })

      assert session.status == "open"
      assert session.url =~ "checkout.stripe.com"

      # Simulate customer completing checkout
      {:ok, completed_session} = PaperTiger.CheckoutSession.complete(session.id, %{
        customer_email: "checkout@example.com"
      })

      assert completed_session.status == "complete"

      # Verify customer and subscription were created
      assert completed_session.customer != nil
      assert completed_session.subscription != nil

      assert_webhook_received("customer.created")
      assert_webhook_received("customer.subscription.created")
      assert_webhook_received("invoice.payment_succeeded")
    end
  end

  describe "webhook signature validation" do
    test "rejects webhook with invalid signature" do
      # Implementation to verify webhook signature validation
    end

    test "accepts webhook with valid signature" do
      # Implementation to verify correct signature handling
    end
  end

  describe "time control end-to-end" do
    test "accelerated time mode processes renewals correctly" do
      # Set up subscription with accelerated time
      Application.put_env(:paper_tiger, :time_mode, :accelerated)
      Application.put_env(:paper_tiger, :time_multiplier, 1000)

      # Create subscription, wait 30 seconds real time = 30000 seconds PaperTiger time
      {:ok, customer} = Stripe.Customer.create(%{email: "time@test.com"})
      # ... create subscription

      # Wait for renewal to process
      Process.sleep(35_000)  # 30 days + buffer

      # Verify renewal happened
      assert_webhook_received("invoice.created")
    end
  end

  # Webhook receiver helpers
  defp start_webhook_receiver do
    # Start simple Bandit server to receive webhooks
  end

  defp assert_webhook_received(event_type, assertion_fn \\ nil) do
    # Poll webhook receiver for event
  end
end
```

**E2E Test Organization:**

```
test/
├── e2e/
│   ├── subscription_lifecycle_test.exs
│   ├── payment_flows_test.exs
│   ├── checkout_session_test.exs
│   ├── webhook_delivery_test.exs
│   ├── time_control_test.exs
│   └── stripity_stripe_compatibility_test.exs
├── paper_tiger/
│   ├── resources/
│   ├── store/
│   └── webhook/
└── test_helper.exs
```

**Run E2E tests separately:**

```bash
# Run fast unit tests
mix test --exclude e2e

# Run slow E2E tests
mix test --only e2e

# CI runs both
mix test
```

## Developer Experience

### Installation

```elixir
# mix.exs
def deps do
  [
    {:paper_tiger, "~> 0.1", only: [:dev, :test]},
    {:stripity_stripe, "~> 3.0"}  # Your Stripe client
  ]
end
```

### Configuration

```elixir
# config/test.exs
config :stripity_stripe,
  api_key: "sk_test_anything",
  api_base_url: "http://localhost:4444"

config :paper_tiger,
  port: 4444,
  time_mode: :manual,
  auto_start: true  # Start automatically in test env

# config/dev.exs
config :stripity_stripe,
  api_key: "sk_test_dev",
  api_base_url: "http://localhost:4444"

config :paper_tiger,
  port: 4444,
  time_mode: :real,
  persist_state: true  # Keep data between restarts

# config/int_test.exs
config :paper_tiger,
  time_mode: :accelerated,
  time_multiplier: 100
```

### Public API

```elixir
defmodule PaperTiger do
  # Start/stop
  def start_link(opts \\ [])
  def child_spec(opts)

  # Test helpers
  def flush()  # Clear all data
  def flush(:customers)  # Clear specific resource
  def register_webhook(url, secret, events \\ nil)

  # Time control
  def advance_time(days: 30)
  def advance_time(seconds: 3600)
  def set_time_mode(:real | :accelerated | :manual)

  # Inspection
  def inspect_store(:customers)
  def list_webhooks()
  def get_event(event_id)
end
```

## Quality Standards

### Required Tools

All tools configured from day one (no excuses):

```elixir
# mix.exs
defp deps do
  [
    # ... runtime deps

    # Quality (non-negotiable)
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
    {:ex_doc, "~> 0.35", only: :dev, runtime: false},
    {:quokka, "~> 2.7", only: [:dev, :test], runtime: false},
    {:mix_test_watch, "~> 1.2", only: :dev, runtime: false},
    {:excoveralls, "~> 0.18", only: :test}
  ]
end
```

### CI Pipeline

Multi-version matrix testing:

```yaml
strategy:
  matrix:
    include:
      - elixir: "1.16.0"
        otp: "26.0"
      - elixir: "1.17.3"
        otp: "27.1"
      - elixir: "1.18.4"
        otp: "28.0"

steps:
  - Compile with --warnings-as-errors
  - mix format --check-formatted
  - mix credo --strict
  - mix dialyzer
  - mix test --trace
  - mix test --only e2e --trace
  - mix coveralls.html
```

### Quality Command

Run before every commit:

```bash
mix format && mix credo --strict && mix dialyzer && mix test
```

### Files

```
.tool-versions           # asdf: erlang 28.0.2, elixir 1.18.4-otp-28
.formatter.exs           # Quokka config
.credo.exs               # Comprehensive linting
.dialyzer_ignore.exs     # Type checking exceptions
.editorconfig            # Editor consistency
.git-blame-ignore-revs   # Formatting commit hashes
.github/workflows/elixir.yml  # CI matrix
CHANGELOG.md             # Detailed version history
README.md                # Comprehensive documentation
LICENSE                  # MIT
```

## Implementation Phases

### Phase 1: Foundation (Week 1)

- [ ] Project setup with quality tooling
- [ ] Supervision tree skeleton
- [ ] Clock system (all 3 modes)
- [ ] ETS store pattern (1 example)
- [ ] HTTP server + basic routing
- [ ] Error handling system

### Phase 2: Core Resources (Week 2-3)

- [ ] Customer, Subscription, SubscriptionItem
- [ ] Invoice, InvoiceItem
- [ ] PaymentMethod, PaymentIntent
- [ ] Product, Price, Plan
- [ ] Event, List

### Phase 3: Payment Resources (Week 4)

- [ ] Charge, Refund
- [ ] SetupIntent
- [ ] Source, Token, Card
- [ ] BalanceTransaction, Payout

### Phase 4: Advanced Features (Week 5)

- [ ] Webhook system with signing
- [ ] Checkout Session
- [ ] TaxRate, Coupon
- [ ] Time-based workers (subscription renewal, invoice finalization)
- [ ] Stripe.js mock script

### Phase 5: Testing & Docs (Week 6)

- [ ] ExUnit helpers
- [ ] PaperTiger.Case template
- [ ] **End-to-end test suite**
- [ ] Compatibility tests against stripity_stripe
- [ ] README with examples
- [ ] HexDocs with guides
- [ ] CHANGELOG

### Phase 6: Polish & Release (Week 7)

- [ ] Full test coverage (>90%)
- [ ] Performance benchmarks
- [ ] Example Phoenix app
- [ ] Hex package publish
- [ ] Announcement blog post

## Success Criteria

### Must Have (v1.0)

- ✅ 28+ Stripe resources implemented
- ✅ **Comprehensive end-to-end test suite**
- ✅ Passes stripity_stripe integration tests
- ✅ All 3 time modes working
- ✅ Webhook delivery with correct signatures
- ✅ ExUnit helpers and test case template
- ✅ CI passing on 3 Elixir/OTP versions
- ✅ >90% test coverage
- ✅ Credo/Dialyzer passing
- ✅ Published to Hex

### Nice to Have (Future)

- Performance benchmarks vs Python version
- Stripe Elements full simulation
- GraphQL API support (Stripe GraphQL)
- Docker image for non-Elixir projects
- Stripe CLI webhook forwarding integration

## Validation Strategy & Limitations

### What PaperTiger Validates

**Structural Validation** (Yes):

- Required fields present
- Field types correct (string, integer, boolean)
- ID format matches (cus*\*, sub*_, pm\__)
- Referenced resources exist
- Enum values valid

**Business Logic Validation** (No):

- Stripe's complex validation rules are proprietary and undocumented
- Example: Stripe may reject certain card + currency combinations
- PaperTiger validates structure, not business rules

**Example:**

```elixir
# PaperTiger accepts this (valid structure)
Stripe.Charge.create(%{
  amount: 1000,
  currency: "usd",
  source: "tok_visa"
})

# Real Stripe might reject it (business rule)
# "Cannot charge USD with this source configuration"
```

### Recommendation

**Document clearly in README:**

> **⚠️ Validation Scope**
>
> PaperTiger validates API structure, not Stripe's business logic.
>
> - ✅ Use PaperTiger for: Integration testing, webhook flows, time-dependent billing
> - ⚠️ Also test against: Real Stripe Test Mode for critical payment paths
>
> PaperTiger won't catch validation errors that real Stripe would reject.
> Maintain a small suite of "live" tests against actual Stripe Sandboxes for critical flows.

### OpenAPI Spec Generation (Future)

Stripe publishes an OpenAPI spec: https://github.com/stripe/openapi

**Future enhancement**: Generate PaperTiger resource structs and basic validations from the spec.

```bash
# Potential tooling
mix paper_tiger.gen.from_openapi spec/openapi.yaml

# Generates:
# - lib/paper_tiger/resources/customer.ex (struct + validations)
# - lib/paper_tiger/resources/subscription.ex
# - ... all 28 resources
```

This would:

- Reduce maintenance by 90%
- Keep PaperTiger up-to-date with Stripe API changes
- Auto-generate field validations from JSON Schema

**For v1.0**: Manual implementation
**For v2.0**: Consider spec generation

## Risks & Mitigations

| Risk                           | Impact | Mitigation                                                                                   |
| ------------------------------ | ------ | -------------------------------------------------------------------------------------------- |
| Stripe API changes frequently  | High   | Focus on current API version, document version support, consider OpenAPI generation for v2.0 |
| Validation differs from Stripe | High   | Document limitations clearly, recommend live tests for critical paths                        |
| 28 resources = lots of code    | Medium | Use macros, behaviours, generators for repetitive code, consider OpenAPI spec in v2.0        |
| Time system complexity         | Medium | Extensive tests, clear documentation, start simple, handle time jumps properly               |
| Webhook timing issues          | Low    | Task.Supervisor handles concurrency, configurable delays                                     |
| E2E tests are slow             | Low    | Run separately in CI, optimize with time acceleration                                        |

## Open Questions

1. **Should we support Stripe API versioning?** Python version doesn't, suggest we don't for v1.0
2. **Mock Stripe Elements fully or just token generation?** Start minimal, expand based on feedback
3. **Support custom pricing tiers?** Python has basic support, we should match
4. **E2E test timeout strategy?** Use accelerated time mode to speed up long-running tests
5. **Worker interval configuration?** For simulated mode, allow configurable check intervals (default: 1 second)

## References

- Python localstripe (inspiration): https://github.com/adrienverge/localstripe
- Stripe API docs: https://stripe.com/docs/api
- stripity_stripe: https://hex.pm/packages/stripity_stripe
- Bandit: https://hex.pm/packages/bandit
- Your docusign project: ~/xuku/docusign_elixir (quality standards reference)

## Next Steps

1. Create GitHub repo for `paper_tiger`
2. Initialize project with quality tooling
3. Begin Phase 1 implementation
4. Set up CI pipeline
5. Create project board for tracking
6. Design tiger logo with stripes 🐯

---

**Ready for Implementation:** YES
**Design Approved By:** [Pending]
**Target Start Date:** 2026-01-01
**Tagline:** _"A paper tiger of a Stripe server—looks fierce, completely harmless"_
