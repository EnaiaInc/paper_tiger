defmodule PaperTiger.WebhookDelivery do
  @moduledoc """
  Manages webhook event delivery to registered endpoints.

  This GenServer delivers webhook events with:
  - Stripe-compatible HMAC SHA256 signing of payloads
  - Exponential backoff retry logic (max 5 attempts)
  - Detailed delivery attempt tracking in Event object
  - Concurrent delivery to multiple endpoints
  - Optional synchronous mode for testing

  ## Delivery Modes

  By default, webhooks are delivered asynchronously. For testing, you can enable
  synchronous mode so API calls block until webhooks are delivered:

      config :paper_tiger, webhook_mode: :sync

  In sync mode, `deliver_event_sync/2` is used which blocks until the webhook
  is delivered (or fails after all retries).

  ## Delivery adapter (host-owned delivery)

  How and where the signed request is sent is a pluggable
  `PaperTiger.WebhookDelivery.Adapter`:

      config :paper_tiger, webhook_delivery_adapter: MyApp.WebhookSink

  The default is `PaperTiger.WebhookDelivery.HTTPAdapter`, which performs the
  HTTP POST itself (historical behavior). A host embedding PaperTiger
  implements the behaviour to take durable ownership of delivery — persist
  the webhook so it survives restarts, then deliver/retry on its own
  schedule. The adapter contract (`{:ok, %Response{}}` = terminal success /
  ownership taken; `{:error, reason}` = PaperTiger retries) is explicit and
  enforced by a real function return, so a missing or crashing host cannot
  silently drop webhooks. See `PaperTiger.WebhookDelivery.Adapter`.

  This is separate from `:webhook_mode` (`:sync`/`:async`/`:collect`), which
  controls *when* delivery is dispatched, not *where* it goes.

  ## Telemetry

  `[:paper_tiger, :webhook, :delivering]` is emitted for **every** delivery,
  in every adapter, immediately after the payload is signed and the headers
  are built and immediately before the adapter is called.

  - measurements: `%{system_time: System.system_time()}`
  - metadata: `%{event: map, webhook: map, url: String.t(), payload: String.t(),
    headers: [{String.t(), String.t()}], signature_header: String.t(),
    timestamp: integer(), namespace: term()}`

  This event is **observability only** — it is not the delivery mechanism.
  Delivery handoff is the `Adapter` behaviour. Use this event for metrics and
  tracing, not for correctness-critical work.

  ## Architecture

  - **Async delivery**: `deliver_event/2` - Queues a delivery task (default)
  - **Sync delivery**: `deliver_event_sync/2` - Blocks until complete
  - **Signing**: `sign_payload/2` - Creates Stripe-compatible HMAC SHA256 signature
  - **Signed request construction**: `build_signed_request/3` - Produces the
    exact raw body, `Stripe-Signature` header, and HTTP headers without
    delivering the webhook
  - **HTTP client**: Uses Req library for reliable, timeout-aware requests
  - **Retry strategy**: Exponential backoff (1s, 2s, 4s, 8s, 16s)
  - **Tracking**: Stores delivery attempts in Event object via Store.Events

  ## Stripe Signature Format

  The `Stripe-Signature` header follows Stripe's format:
  ```
  Stripe-Signature: t={timestamp},v1={signature}
  ```

  Where:
  - `t` = Unix timestamp when webhook was created
  - `v1` = HMAC SHA256 signature of "{timestamp}.{payload}" using webhook secret

  ## Examples

      # Deliver an event asynchronously (default)
      {:ok, _ref} = PaperTiger.WebhookDelivery.deliver_event("evt_123", "we_456")

      # Deliver an event synchronously (for testing)
      {:ok, :delivered} = PaperTiger.WebhookDelivery.deliver_event_sync("evt_123", "we_456")

      # Manually create a signature for testing
      signature = PaperTiger.WebhookDelivery.sign_payload("body", "secret")

      # Build the exact webhook request a controller test should verify
      request = PaperTiger.WebhookDelivery.build_signed_request(event, webhook)
  """

  use GenServer

  alias PaperTiger.Store.Events
  alias PaperTiger.Store.Webhooks
  alias PaperTiger.WebhookDelivery.HTTPAdapter
  alias PaperTiger.WebhookDelivery.Request
  alias PaperTiger.WebhookDelivery.Response

  require Logger

  @max_retries 5
  @base_backoff_ms 1000
  @namespace_key :paper_tiger_namespace

  ## Client API
  ## Server Callbacks
  # Spawn a task so we don't block the GenServer during retries/backoff
  # Wait indefinitely for the task to complete
  ## Private Functions
  # Dispatches a delivery by spawning an async task
  # Dispatches a delivery synchronously, waiting for completion
  # Synchronous version of deliver_with_retries - blocks until complete
  # Terminal success: the adapter delivered, or durably accepted
  # ownership. No retry.
  # Wait for backoff, then retry synchronously
  # Delivers with exponential backoff retry logic
  # Update event with final failed delivery attempt
  # Terminal success: the adapter delivered, or durably accepted
  # ownership. No retry.
  # Schedule retry with exponential backoff
  # Signs the payload, emits the observability telemetry event, then hands a
  # fully-prepared Request to the configured delivery adapter. The adapter's
  # `{:ok, %Response{}} | {:error, reason}` return is interpreted by the
  # retry machinery (success is terminal; error retries with backoff).
  # Create Stripe-compatible signature: HMAC(secret, "{timestamp}.{payload}")
  # Build Stripe-Signature header
  # Observability ONLY. This telemetry event is emitted for every delivery
  # in every adapter, but it is not load-bearing — delivery handoff happens
  # via the explicit `Adapter` behaviour below, not via whoever may or may
  # not be attached to this event. Use it for metrics/tracing.
  # Invokes the configured adapter and guarantees a normalized
  # `{:ok, %Response{}} | {:error, reason}` result no matter how badly the
  # adapter misbehaves. This is what actually enforces the "a missing or
  # crashing host cannot silently drop webhooks" guarantee: a raising,
  # exiting, throwing, undefined, or wrong-shape-returning adapter is turned
  # into an `{:error, reason}` so `deliver_with_retries/{3,4}` apply
  # PaperTiger's own backoff/retry and record a delivery attempt, instead of
  # the spawned delivery task crashing before the retry machinery runs (and,
  # in sync mode, taking the linked `Task.async` / GenServer down with it).
  # Resolves the configured webhook delivery adapter. Defaults to the
  # built-in HTTP adapter (historical behavior). A host embedding PaperTiger
  # sets `config :paper_tiger, webhook_delivery_adapter: MyApp.WebhookSink`
  @doc """
  Starts the WebhookDelivery GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Delivers a webhook event to a specific endpoint.

  This function queues the delivery asynchronously. Multiple calls with different
  webhook_endpoint_ids deliver to all endpoints.

  ## Parameters

  - `event_id` - ID of the event to deliver (e.g., "evt_123")
  - `webhook_endpoint_id` - ID of the webhook endpoint (e.g., "we_456")

  ## Returns

  - `{:ok, reference}` - Delivery queued successfully
  - `{:error, reason}` - Delivery could not be queued

  ## Examples

      {:ok, _ref} = PaperTiger.WebhookDelivery.deliver_event("evt_123", "we_456")
  """
  @spec deliver_event(String.t(), String.t()) :: {:ok, reference()} | {:error, term()}
  def deliver_event(event_id, webhook_endpoint_id) when is_binary(event_id) and is_binary(webhook_endpoint_id) do
    deliver_event(event_id, webhook_endpoint_id, PaperTiger.Test.current_namespace())
  end

  @doc false
  @spec deliver_event(String.t(), String.t(), term()) :: {:ok, reference()} | {:error, term()}
  # to take durable ownership of delivery.
  # Schedules a retry after exponential backoff delay
  # Calculate backoff: 1s, 2s, 4s, 8s, 16s
  def deliver_event(event_id, webhook_endpoint_id, namespace)
      when is_binary(event_id) and is_binary(webhook_endpoint_id) do
    GenServer.call(__MODULE__, {:deliver_event, namespace, event_id, webhook_endpoint_id})
  end

  # Send to GenServer, not to spawned process (which exits immediately)
  # Updates the event's delivery_attempts array with the result
  # Build delivery attempt record
  @doc """
  Delivers a webhook event synchronously, waiting for completion.

  Unlike `deliver_event/2`, this function blocks until the webhook has been
  delivered (or fails after all retries). Use this in test environments where
  you need webhooks to be processed before assertions.

  ## Parameters

  - `event_id` - ID of the event to deliver (e.g., "evt_123")
  - `webhook_endpoint_id` - ID of the webhook endpoint (e.g., "we_456")

  ## Returns

  - `{:ok, :delivered}` - Webhook delivered successfully
  - `{:ok, :failed}` - Delivery failed after all retries
  - `{:error, reason}` - Event or webhook not found

  ## Examples

      {:ok, :delivered} = PaperTiger.WebhookDelivery.deliver_event_sync("evt_123", "we_456")
  """
  @spec deliver_event_sync(String.t(), String.t()) :: {:ok, :delivered | :failed} | {:error, term()}
  def deliver_event_sync(event_id, webhook_endpoint_id) when is_binary(event_id) and is_binary(webhook_endpoint_id) do
    deliver_event_sync(event_id, webhook_endpoint_id, PaperTiger.Test.current_namespace())
  end

  @doc false
  @spec deliver_event_sync(String.t(), String.t(), term()) :: {:ok, :delivered | :failed} | {:error, term()}
  def deliver_event_sync(event_id, webhook_endpoint_id, namespace)
      when is_binary(event_id) and is_binary(webhook_endpoint_id) do
    GenServer.call(__MODULE__, {:deliver_event_sync, namespace, event_id, webhook_endpoint_id}, :infinity)
  end

  @doc """
  Signs a payload using HMAC SHA256 (Stripe-compatible).

  Creates the signature component for the `Stripe-Signature` header.
  The actual signature is computed on "{timestamp}.{payload}".

  ## Parameters

  - `payload` - JSON string (or any string data) to sign
  - `secret` - Webhook secret from the webhook endpoint

  ## Returns

  String containing the hex-encoded HMAC SHA256 signature.

  ## Examples

      signature = PaperTiger.WebhookDelivery.sign_payload(payload, "whsec_...")
      # Returns: "abcd1234..."
  """
  @spec sign_payload(String.t(), String.t()) :: String.t()
  def sign_payload(payload, secret) when is_binary(payload) and is_binary(secret) do
    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Builds a Stripe-compatible signed webhook request without delivering it.

  The returned `PaperTiger.WebhookDelivery.Request` contains the exact raw
  JSON body and `Stripe-Signature` header that PaperTiger will hand to the
  delivery adapter. Tests can pass `request.payload` and
  `request.signature_header` directly to `Stripe.Webhook.construct_event/5`.

  By default, the signature timestamp uses wall-clock time
  (`System.system_time(:second)`), matching Stripe's webhook delivery
  semantics. PaperTiger's simulated resource clock controls object timestamps,
  not webhook signature freshness.

  Options:

  - `:namespace` - PaperTiger namespace to attach to the request.
  - `:timestamp` - Signature timestamp override, useful for stale-signature
    tests.
  """
  @spec build_signed_request(map(), map(), keyword()) :: Request.t()
  def build_signed_request(event, webhook, opts \\ []) when is_map(event) and is_map(webhook) do
    timestamp = Keyword.get_lazy(opts, :timestamp, fn -> System.system_time(:second) end)
    namespace = Keyword.get(opts, :namespace, PaperTiger.Test.current_namespace())
    payload = Jason.encode!(event)
    signed_content = "#{timestamp}.#{payload}"
    signature = sign_payload(signed_content, webhook_secret(webhook))
    stripe_signature = "t=#{timestamp},v1=#{signature}"

    headers = [
      {"Stripe-Signature", stripe_signature},
      {"Content-Type", "application/json"},
      {"User-Agent", "Stripe/1.0 (+https://stripe.com/docs/webhooks)"}
    ]

    %Request{
      event: event,
      headers: headers,
      namespace: namespace,
      payload: payload,
      signature_header: stripe_signature,
      timestamp: timestamp,
      url: webhook_url(webhook),
      webhook: webhook
    }
  end

  @impl true
  def init(_opts) do
    Logger.debug("PaperTiger.WebhookDelivery started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:deliver_event, namespace, event_id, webhook_endpoint_id}, _from, state) do
    result = dispatch_delivery(namespace, event_id, webhook_endpoint_id)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:deliver_event_sync, namespace, event_id, webhook_endpoint_id}, _from, state) do
    task =
      Task.async(fn ->
        dispatch_delivery_sync(namespace, event_id, webhook_endpoint_id)
      end)

    result = Task.await(task, :infinity)
    {:reply, result, state}
  end

  defp dispatch_delivery(namespace, event_id, webhook_endpoint_id) do
    case fetch_delivery_resources(namespace, event_id, webhook_endpoint_id) do
      {:ok, event, webhook} -> start_delivery_task(namespace, event, webhook)
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_delivery_sync(namespace, event_id, webhook_endpoint_id) do
    case fetch_delivery_resources(namespace, event_id, webhook_endpoint_id) do
      {:ok, event, webhook} ->
        with_namespace(namespace, fn ->
          deliver_with_retries_sync(event, webhook, namespace, 0)
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_delivery_resources(namespace, event_id, webhook_endpoint_id) do
    with_namespace(namespace, fn ->
      do_fetch_delivery_resources(event_id, webhook_endpoint_id)
    end)
  end

  defp do_fetch_delivery_resources(event_id, webhook_endpoint_id) do
    case {Events.get(event_id), Webhooks.get(webhook_endpoint_id)} do
      {{:ok, event}, {:ok, webhook}} ->
        {:ok, event, webhook}

      {{:error, :not_found}, _} ->
        Logger.warning("WebhookDelivery: Event not found: #{event_id}")
        {:error, :event_not_found}

      {_, {:error, :not_found}} ->
        Logger.warning("WebhookDelivery: Webhook endpoint not found: #{webhook_endpoint_id}")
        {:error, :webhook_not_found}
    end
  end

  defp start_delivery_task(namespace, event, webhook) do
    ref = make_ref()

    Task.Supervisor.start_child(PaperTiger.TaskSupervisor, fn ->
      with_namespace(namespace, fn ->
        deliver_with_retries(event, webhook, namespace, 0, ref)
      end)
    end)

    {:ok, ref}
  end

  defp deliver_with_retries_sync(event, webhook, _namespace, attempt) when attempt >= @max_retries do
    Logger.error("WebhookDelivery: Max retries (#{@max_retries}) exceeded for event #{event.id} to #{webhook.url}")
    update_event_delivery_attempts(event, webhook, attempt, :failed, nil)
    {:ok, :failed}
  end

  defp deliver_with_retries_sync(event, webhook, namespace, attempt) do
    case perform_delivery(event, webhook, namespace) do
      {:ok, %Response{} = response} ->
        Logger.info("WebhookDelivery: Event #{event.id} delivered to #{webhook.url} (attempt #{attempt + 1})")
        update_event_delivery_attempts(event, webhook, attempt, :delivered, response.body)
        {:ok, :delivered}

      {:error, reason} ->
        Logger.warning(
          "WebhookDelivery: Event #{event.id} delivery to #{webhook.url} failed: #{inspect(reason)} (attempt #{attempt + 1}/#{@max_retries})"
        )

        delay_ms = @base_backoff_ms * Integer.pow(2, attempt)
        Process.sleep(delay_ms)
        deliver_with_retries_sync(event, webhook, namespace, attempt + 1)
    end
  end

  defp deliver_with_retries(event, webhook, _namespace, attempt, _ref) when attempt >= @max_retries do
    Logger.error("WebhookDelivery: Max retries (#{@max_retries}) exceeded for event #{event.id} to #{webhook.url}")
    update_event_delivery_attempts(event, webhook, attempt, :failed, nil)
  end

  defp deliver_with_retries(event, webhook, namespace, attempt, _ref) do
    case perform_delivery(event, webhook, namespace) do
      {:ok, %Response{} = response} ->
        Logger.info("WebhookDelivery: Event #{event.id} delivered to #{webhook.url} (attempt #{attempt + 1})")
        update_event_delivery_attempts(event, webhook, attempt, :delivered, response.body)

      {:error, reason} ->
        Logger.warning(
          "WebhookDelivery: Event #{event.id} delivery to #{webhook.url} failed: #{inspect(reason)} (attempt #{attempt + 1}/#{@max_retries})"
        )

        schedule_retry(event, webhook, namespace, attempt)
    end
  end

  defp perform_delivery(event, webhook, namespace) do
    request = build_signed_request(event, webhook, namespace: namespace)

    :telemetry.execute(
      [:paper_tiger, :webhook, :delivering],
      %{system_time: System.system_time()},
      %{
        event: request.event,
        headers: request.headers,
        namespace: request.namespace,
        payload: request.payload,
        signature_header: request.signature_header,
        timestamp: request.timestamp,
        url: request.url,
        webhook: request.webhook
      }
    )

    safe_adapter_deliver(delivery_adapter(), request)
  end

  defp webhook_secret(webhook) do
    Map.get(webhook, :secret) || Map.get(webhook, "secret") ||
      Application.get_env(:stripity_stripe, :webhook_signing_key, "whsec_paper_tiger_test")
  end

  defp webhook_url(webhook), do: Map.get(webhook, :url) || Map.get(webhook, "url")

  defp safe_adapter_deliver(adapter, request) do
    cond do
      not is_atom(adapter) ->
        {:error, {:invalid_adapter, adapter}}

      not Code.ensure_loaded?(adapter) ->
        {:error, {:adapter_not_loaded, adapter}}

      not function_exported?(adapter, :deliver, 1) ->
        {:error, {:adapter_missing_deliver, adapter}}

      true ->
        invoke_adapter(adapter, request)
    end
  end

  defp invoke_adapter(adapter, request) do
    case adapter.deliver(request) do
      {:ok, %Response{}} = ok -> ok
      {:error, _reason} = err -> err
      other -> {:error, {:invalid_adapter_response, other}}
    end
  rescue
    e ->
      {:error, {:adapter_raised, Exception.format(:error, e, __STACKTRACE__)}}
  catch
    :throw, value ->
      {:error, {:adapter_threw, value}}

    :exit, reason ->
      {:error, {:adapter_exited, reason}}
  end

  @spec delivery_adapter() :: module()
  defp delivery_adapter do
    Application.get_env(
      :paper_tiger,
      :webhook_delivery_adapter,
      HTTPAdapter
    )
  end

  defp schedule_retry(event, webhook, namespace, attempt) do
    delay_ms = @base_backoff_ms * Integer.pow(2, attempt)

    Logger.debug(
      "WebhookDelivery: Scheduling retry for event #{event.id} after #{delay_ms}ms (attempt #{attempt + 2}/#{@max_retries})"
    )

    Process.send_after(
      __MODULE__,
      {:retry_delivery, namespace, event, webhook, attempt + 1},
      delay_ms
    )
  end

  defp update_event_delivery_attempts(event, webhook, attempt, status, response_body) do
    now = PaperTiger.Clock.now()

    delivery_attempt = %{
      attempt: attempt + 1,
      # Would be filled in if we had status code
      http_status: nil,
      response_body: response_body,
      status: status,
      timestamp: now,
      webhook_endpoint_id: webhook.id
    }

    # Get existing delivery_attempts or create empty list
    delivery_attempts = event.delivery_attempts || []

    # Update event with new delivery attempt
    updated_event = %{event | delivery_attempts: delivery_attempts ++ [delivery_attempt]}

    case Events.update(updated_event) do
      {:ok, _} ->
        Logger.debug("WebhookDelivery: Updated event #{event.id} with #{status} attempt to #{webhook.url}")
    end
  end

  # Handle info messages for retries (if using handle_info pattern)
  @impl true
  def handle_info({:retry_delivery, namespace, event, webhook, attempt}, state) do
    with_namespace(namespace, fn ->
      deliver_with_retries(event, webhook, namespace, attempt, make_ref())
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp with_namespace(namespace, fun) do
    unset = make_ref()
    previous = Process.get(@namespace_key, unset)
    Process.put(@namespace_key, namespace)

    try do
      fun.()
    after
      restore_namespace(previous, unset)
    end
  end

  defp restore_namespace(previous, unset) when previous == unset do
    Process.delete(@namespace_key)
  end

  defp restore_namespace(previous, _unset) do
    Process.put(@namespace_key, previous)
  end
end
