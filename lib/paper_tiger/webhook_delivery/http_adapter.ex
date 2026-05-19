defmodule PaperTiger.WebhookDelivery.HTTPAdapter do
  @moduledoc """
  Default `PaperTiger.WebhookDelivery.Adapter` — performs the HTTP POST
  itself using `Req`. This is the historical PaperTiger behavior and the
  adapter in effect when `:webhook_delivery_adapter` is not configured.

  - 2xx response → `{:ok, %Response{status: code, body: body}}` (terminal
    success; PaperTiger records the body on the delivery attempt).
  - non-2xx response → `{:error, {:http_status, code}}` (PaperTiger retries).
  - transport error / timeout → `{:error, reason}` (PaperTiger retries).
  """

  @behaviour PaperTiger.WebhookDelivery.Adapter

  alias PaperTiger.WebhookDelivery.Request
  alias PaperTiger.WebhookDelivery.Response

  require Logger

  @timeout_ms 30_000

  @impl true
  def deliver(%Request{} = request) do
    Logger.debug(
      "WebhookDelivery.HTTPAdapter: POST event #{request.event.id} to #{request.url} (t=#{request.timestamp})"
    )

    response =
      Req.post!(
        request.url,
        body: request.payload,
        headers: request.headers,
        receive_timeout: @timeout_ms,
        connect_options: [timeout: @timeout_ms]
      )

    if response.status >= 200 and response.status < 300 do
      {:ok, %Response{body: response.body || "", status: response.status}}
    else
      # Preserve the operator-facing "rejected with status" detail that the
      # pre-adapter code logged; the retry layer only sees {:error, reason}.
      Logger.warning(
        "WebhookDelivery.HTTPAdapter: event #{request.event.id} rejected by #{request.url} with status #{response.status}"
      )

      {:error, {:http_status, response.status}}
    end
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
