defmodule PaperTiger.WebhookDelivery.Request do
  @moduledoc """
  A fully-prepared webhook delivery request handed to a
  `PaperTiger.WebhookDelivery.Adapter`.

  PaperTiger has already JSON-encoded the event, computed the
  Stripe-compatible HMAC signature, and built the header list. An adapter
  has everything required to deliver (or durably enqueue) the webhook
  without re-encoding or re-signing.

  Fields:

  - `:url` — destination URL of the registered webhook endpoint.
  - `:payload` — the exact JSON byte string that was signed. Send this
    verbatim; re-encoding the event would invalidate the signature.
  - `:headers` — the full header list, including `Stripe-Signature`,
    `Content-Type`, and `User-Agent`.
  - `:signature_header` — the `t=...,v1=...` value (also present in
    `:headers`), exposed separately for convenience.
  - `:timestamp` — the Unix timestamp used in the signed content.
  - `:event` — the source PaperTiger event map.
  - `:webhook` — the source webhook-endpoint map (`:id`, `:url`,
    `:secret`, ...).
  """

  @enforce_keys [:url, :payload, :headers, :signature_header, :timestamp, :event, :webhook]
  defstruct [:event, :headers, :payload, :signature_header, :timestamp, :url, :webhook]

  @type t :: %__MODULE__{
          event: map(),
          headers: [{String.t(), String.t()}],
          payload: String.t(),
          signature_header: String.t(),
          timestamp: integer(),
          url: String.t(),
          webhook: map()
        }
end
