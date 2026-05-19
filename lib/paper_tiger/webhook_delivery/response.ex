defmodule PaperTiger.WebhookDelivery.Response do
  @moduledoc """
  The successful result of a `PaperTiger.WebhookDelivery.Adapter.deliver/1`
  call.

  Returned inside `{:ok, %Response{}}` to signal the webhook was either
  delivered or durably accepted by the adapter. PaperTiger treats any
  `{:ok, %Response{}}` as terminal success and does not retry.

  - `:status` — for the built-in HTTP adapter, the 2xx status code from the
    endpoint. A host adapter that durably enqueues should use a synthetic
    `202` to mean "accepted, will deliver".
  - `:body` — response body if any (the built-in adapter records this on the
    event's delivery attempt). Empty string is fine.
  """

  @enforce_keys [:status]
  defstruct body: "", status: nil

  @type t :: %__MODULE__{body: String.t(), status: non_neg_integer()}
end
