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

  ## Architecture

  - **Async delivery**: `deliver_event/2` - Queues a delivery task (default)
  - **Sync delivery**: `deliver_event_sync/2` - Blocks until complete
  - **Signing**: `sign_payload/2` - Creates Stripe-compatible HMAC SHA256 signature
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
  """

  use GenServer

  alias PaperTiger.Store.Events
  alias PaperTiger.Store.Webhooks

  require Logger

  @max_retries 5
  @base_backoff_ms 1000
  @timeout_ms 30_000

  ## Client API

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
    GenServer.call(__MODULE__, {:deliver_event, event_id, webhook_endpoint_id})
  end

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
    GenServer.call(__MODULE__, {:deliver_event_sync, event_id, webhook_endpoint_id}, :infinity)
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

  ## Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("PaperTiger.WebhookDelivery started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:deliver_event, event_id, webhook_endpoint_id}, _from, state) do
    result = dispatch_delivery(event_id, webhook_endpoint_id)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:deliver_event_sync, event_id, webhook_endpoint_id}, _from, state) do
    result = dispatch_delivery_sync(event_id, webhook_endpoint_id)
    {:reply, result, state}
  end

  ## Private Functions

  # Dispatches a delivery by spawning an async task
  defp dispatch_delivery(event_id, webhook_endpoint_id) do
    # Fetch the event and webhook endpoint
    case {Events.get(event_id), Webhooks.get(webhook_endpoint_id)} do
      {{:ok, event}, {:ok, webhook}} ->
        # Spawn async task to handle delivery with retries
        ref = make_ref()

        spawn_link(fn ->
          deliver_with_retries(event, webhook, 0, ref)
        end)

        {:ok, ref}

      {{:error, :not_found}, _} ->
        Logger.warning("WebhookDelivery: Event not found: #{event_id}")
        {:error, :event_not_found}

      {_, {:error, :not_found}} ->
        Logger.warning("WebhookDelivery: Webhook endpoint not found: #{webhook_endpoint_id}")
        {:error, :webhook_not_found}
    end
  end

  # Dispatches a delivery synchronously, waiting for completion
  defp dispatch_delivery_sync(event_id, webhook_endpoint_id) do
    case {Events.get(event_id), Webhooks.get(webhook_endpoint_id)} do
      {{:ok, event}, {:ok, webhook}} ->
        deliver_with_retries_sync(event, webhook, 0)

      {{:error, :not_found}, _} ->
        Logger.warning("WebhookDelivery: Event not found: #{event_id}")
        {:error, :event_not_found}

      {_, {:error, :not_found}} ->
        Logger.warning("WebhookDelivery: Webhook endpoint not found: #{webhook_endpoint_id}")
        {:error, :webhook_not_found}
    end
  end

  # Synchronous version of deliver_with_retries - blocks until complete
  defp deliver_with_retries_sync(event, webhook, attempt) when attempt >= @max_retries do
    Logger.error("WebhookDelivery: Max retries (#{@max_retries}) exceeded for event #{event.id} to #{webhook.url}")
    update_event_delivery_attempts(event, webhook, attempt, :failed, nil)
    {:ok, :failed}
  end

  defp deliver_with_retries_sync(event, webhook, attempt) do
    case perform_delivery(event, webhook) do
      {:ok, status_code, response_body} when status_code >= 200 and status_code < 300 ->
        Logger.info("WebhookDelivery: Event #{event.id} delivered to #{webhook.url} (attempt #{attempt + 1})")
        update_event_delivery_attempts(event, webhook, attempt, :delivered, response_body)
        {:ok, :delivered}

      {:ok, status_code, _response_body} ->
        Logger.warning(
          "WebhookDelivery: Event #{event.id} rejected by #{webhook.url} with status #{status_code} (attempt #{attempt + 1}/#{@max_retries})"
        )

        # Wait for backoff, then retry synchronously
        delay_ms = @base_backoff_ms * Integer.pow(2, attempt)
        Process.sleep(delay_ms)
        deliver_with_retries_sync(event, webhook, attempt + 1)

      {:error, reason} ->
        Logger.warning(
          "WebhookDelivery: Event #{event.id} delivery to #{webhook.url} failed: #{inspect(reason)} (attempt #{attempt + 1}/#{@max_retries})"
        )

        # Wait for backoff, then retry synchronously
        delay_ms = @base_backoff_ms * Integer.pow(2, attempt)
        Process.sleep(delay_ms)
        deliver_with_retries_sync(event, webhook, attempt + 1)
    end
  end

  # Delivers with exponential backoff retry logic
  defp deliver_with_retries(event, webhook, attempt, _ref) when attempt >= @max_retries do
    Logger.error("WebhookDelivery: Max retries (#{@max_retries}) exceeded for event #{event.id} to #{webhook.url}")

    # Update event with final failed delivery attempt
    update_event_delivery_attempts(event, webhook, attempt, :failed, nil)
  end

  defp deliver_with_retries(event, webhook, attempt, _ref) do
    case perform_delivery(event, webhook) do
      {:ok, status_code, response_body} when status_code >= 200 and status_code < 300 ->
        Logger.info("WebhookDelivery: Event #{event.id} delivered to #{webhook.url} (attempt #{attempt + 1})")

        # Update event with successful delivery
        update_event_delivery_attempts(event, webhook, attempt, :delivered, response_body)

      {:ok, status_code, _response_body} ->
        Logger.warning(
          "WebhookDelivery: Event #{event.id} rejected by #{webhook.url} with status #{status_code} (attempt #{attempt + 1}/#{@max_retries})"
        )

        # Schedule retry with exponential backoff
        schedule_retry(event, webhook, attempt)

      {:error, reason} ->
        Logger.warning(
          "WebhookDelivery: Event #{event.id} delivery to #{webhook.url} failed: #{inspect(reason)} (attempt #{attempt + 1}/#{@max_retries})"
        )

        # Schedule retry with exponential backoff
        schedule_retry(event, webhook, attempt)
    end
  end

  # Performs the actual HTTP POST to the webhook endpoint
  defp perform_delivery(event, webhook) do
    timestamp = PaperTiger.Clock.now()
    payload = Jason.encode!(event)

    # Create Stripe-compatible signature: HMAC(secret, "{timestamp}.{payload}")
    signed_content = "#{timestamp}.#{payload}"
    signature = sign_payload(signed_content, webhook.secret)

    # Build Stripe-Signature header
    stripe_signature = "t=#{timestamp},v1=#{signature}"

    headers = [
      {"Stripe-Signature", stripe_signature},
      {"Content-Type", "application/json"},
      {"User-Agent", "PaperTiger/1.0"}
    ]

    Logger.debug("WebhookDelivery: Posting event #{event.id} to #{webhook.url} with timestamp #{timestamp}")

    # Use Req library for HTTP POST
    try do
      response =
        Req.post!(
          webhook.url,
          body: payload,
          headers: headers,
          receive_timeout: @timeout_ms,
          connect_timeout: @timeout_ms
        )

      {:ok, response.status, response.body || ""}
    rescue
      e in Req.HTTPError ->
        {:error, {:http_error, inspect(e)}}

      e ->
        {:error, {:unexpected_error, inspect(e)}}
    catch
      :exit, {:timeout, _} ->
        {:error, :timeout}

      :exit, reason ->
        {:error, {:exit, reason}}
    end
  end

  # Schedules a retry after exponential backoff delay
  defp schedule_retry(event, webhook, attempt) do
    # Calculate backoff: 1s, 2s, 4s, 8s, 16s
    delay_ms = @base_backoff_ms * Integer.pow(2, attempt)

    Logger.debug(
      "WebhookDelivery: Scheduling retry for event #{event.id} after #{delay_ms}ms (attempt #{attempt + 2}/#{@max_retries})"
    )

    # Send to GenServer, not to spawned process (which exits immediately)
    Process.send_after(
      __MODULE__,
      {:retry_delivery, event, webhook, attempt + 1},
      delay_ms
    )
  end

  # Updates the event's delivery_attempts array with the result
  defp update_event_delivery_attempts(event, webhook, attempt, status, response_body) do
    now = PaperTiger.Clock.now()

    # Build delivery attempt record
    delivery_attempt = %{
      webhook_endpoint_id: webhook.id,
      attempt: attempt + 1,
      timestamp: now,
      status: status,
      response_body: response_body,
      # Would be filled in if we had status code
      http_status: nil
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
  def handle_info({:retry_delivery, event, webhook, attempt}, state) do
    deliver_with_retries(event, webhook, attempt, make_ref())
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
