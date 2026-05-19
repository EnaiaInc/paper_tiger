defmodule PaperTiger.WebhookDelivery.Adapter do
  @moduledoc """
  Behaviour for delivering a signed webhook request.

  PaperTiger signs the payload, builds the `Stripe-Signature` header, emits
  the `[:paper_tiger, :webhook, :delivering]` telemetry event (observability
  only), then calls the configured adapter's `deliver/1` with a
  `PaperTiger.WebhookDelivery.Request`.

  Configure with:

      config :paper_tiger,
        webhook_delivery_adapter: MyApp.WebhookSink

  The default is `PaperTiger.WebhookDelivery.HTTPAdapter`, which performs the
  HTTP POST itself (the historical behavior). Override it when embedding
  PaperTiger inside a system that must own webhook delivery durably (e.g. a
  hosting layer that persists webhooks so they survive node restarts).

  ## Return contract

  - `{:ok, %PaperTiger.WebhookDelivery.Response{}}` — the adapter has taken
    terminal ownership of this webhook. Either it delivered successfully, or
    it durably enqueued it and will deliver/retry itself. PaperTiger records a
    successful delivery attempt on the event and does **not** apply its own
    retry. A durable-enqueue adapter should return `%Response{status: 202}`.

  - `{:error, reason}` — the adapter could not take ownership (HTTP non-2xx,
    transport error, failed to enqueue, ...). PaperTiger applies its own
    exponential-backoff retry exactly as it does for a failed built-in POST,
    and records `:failed` after the retry budget is exhausted.

  An adapter must never return `{:ok, ...}` unless it has genuinely accepted
  responsibility for the webhook. Returning `{:ok, ...}` after a best-effort
  non-durable attempt is the one way to cause silent webhook loss; that is the
  adapter's contract to uphold, and the reason delivery is an explicit
  behaviour rather than a telemetry side effect.
  """

  alias PaperTiger.WebhookDelivery.Request
  alias PaperTiger.WebhookDelivery.Response

  @callback deliver(Request.t()) ::
              {:ok, Response.t()} | {:error, term()}
end
