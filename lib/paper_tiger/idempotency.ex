defmodule PaperTiger.Idempotency do
  @moduledoc """
  Implements Stripe's idempotency mechanism to prevent duplicate requests.

  Stripe stores idempotency keys for 24 hours. Requests with the same
  Idempotency-Key header return the cached response without re-executing.

  ## Usage

  The `PaperTiger.Plugs.Idempotency` plug automatically handles this for POST requests.

  ## Implementation

  - Stores responses in ETS keyed by idempotency key
  - TTL: 24 hours (matches Stripe)
  - Cleanup runs hourly to remove expired entries

  ## Examples

      # Client retries request with same key
      headers = [{"idempotency-key", "req_123"}]

      # First request executes and caches response
      Stripe.Charge.create(%{...}, headers: headers)

      # Second request returns cached response (no duplicate charge)
      Stripe.Charge.create(%{...}, headers: headers)
  """

  use GenServer

  require Logger

  @table :paper_tiger_idempotency
  @ttl_seconds 24 * 60 * 60

  ## Client API

  @doc """
  Starts the Idempotency GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if a request with this idempotency key has been processed.

  Returns:
  - `{:cached, response}` - Key exists, return cached response
  - `:new_request` - Key doesn't exist, proceed with request (and reserves the key atomically)
  - `:in_progress` - Another request with this key is currently processing

  ## Race Condition Protection

  Uses atomic ETS insert_new to prevent race conditions. If two requests
  arrive simultaneously with the same key, only one will get `:new_request`,
  the other will get `:in_progress` and should retry or wait.
  """
  @spec check(String.t()) :: {:cached, map()} | :new_request | :in_progress
  def check(idempotency_key) when is_binary(idempotency_key) do
    namespace = PaperTiger.Test.current_namespace()
    key = {namespace, idempotency_key}
    now = PaperTiger.Clock.now()

    # First, try to atomically remove if it's expired (marker or cached response)
    # This prevents the race where two processes see it expired and both try to delete/re-insert
    :ets.select_delete(@table, [{{key, :_, :"$1"}, [{:<, :"$1", now}], [true]}])

    case :ets.lookup(@table, key) do
      [{^key, :in_progress, _expires_at}] ->
        Logger.debug("Idempotency key in progress: #{idempotency_key}")
        :in_progress

      [{^key, response, _expires_at}] ->
        Logger.debug("Idempotency cache hit: #{idempotency_key}")
        {:cached, response}

      [] ->
        # Atomically reserve this key with in-progress marker
        expires_at = now + @ttl_seconds

        case :ets.insert_new(@table, {key, :in_progress, expires_at}) do
          true ->
            Logger.debug("Idempotency: new request with key=#{idempotency_key}")
            :new_request

          false ->
            # Another process beat us to it, check again
            Logger.debug("Idempotency: race detected for key=#{idempotency_key}, rechecking")
            check(idempotency_key)
        end
    end
  end

  @doc """
  Stores a response for the given idempotency key.

  The response will be cached for 24 hours.
  """
  @spec store(String.t(), map()) :: :ok
  def store(idempotency_key, response) when is_binary(idempotency_key) do
    namespace = PaperTiger.Test.current_namespace()
    key = {namespace, idempotency_key}
    expires_at = PaperTiger.Clock.now() + @ttl_seconds
    :ets.insert(@table, {key, response, expires_at})
    Logger.debug("Idempotency stored: #{idempotency_key} (expires: #{expires_at})")
    :ok
  end

  @doc """
  Clears all idempotency keys.

  Useful for test cleanup.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc """
  Clears idempotency keys for a specific namespace.

  Used by `PaperTiger.Test` to clean up after each test.
  """
  @spec clear_namespace(pid() | :global) :: :ok
  def clear_namespace(namespace) do
    GenServer.call(__MODULE__, {:clear_namespace, namespace})
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    schedule_cleanup()
    Logger.debug("PaperTiger.Idempotency started (TTL: #{@ttl_seconds}s)")
    {:ok, %{}}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    Logger.debug("Idempotency cache cleared")
    {:reply, :ok, state}
  end

  def handle_call({:clear_namespace, namespace}, _from, state) do
    :ets.match_delete(@table, {{namespace, :_}, :_, :_})
    Logger.debug("Idempotency cache cleared for namespace")
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = PaperTiger.Clock.now()
    # Match pattern for namespaced keys: {{namespace, key}, response, expires_at}
    count = :ets.select_delete(@table, [{{{:_, :_}, :_, :"$1"}, [{:<, :"$1", now}], [true]}])

    if count > 0 do
      Logger.debug("Idempotency cleanup: removed #{count} expired entries")
    end

    schedule_cleanup()
    {:noreply, state}
  end

  ## Private Functions

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, :timer.hours(1))
  end
end
