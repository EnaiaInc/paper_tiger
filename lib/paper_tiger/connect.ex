defmodule PaperTiger.Connect do
  @moduledoc """
  Request-scoped helpers for Stripe Connect behavior.

  Stripe's `Stripe-Account` header is per request. PaperTiger models that by
  storing the connected account ID in the process dictionary for the duration
  of a request, then using it as part of the ETS storage namespace for normal
  resources. Platform-owned resources can temporarily opt back into the base
  namespace with `without_account/1`.
  """

  @account_key :paper_tiger_connected_account

  @type account_id :: String.t()
  @type storage_namespace :: pid() | :global | {pid() | :global, account_id()}

  @doc """
  Returns the connected account ID for the current request, if any.
  """
  @spec current_account() :: account_id() | nil
  def current_account do
    Process.get(@account_key)
  end

  @doc """
  Returns the storage namespace for the current sandbox + connected account.
  """
  @spec storage_namespace() :: storage_namespace()
  def storage_namespace do
    storage_namespace(PaperTiger.Test.current_namespace())
  end

  @doc """
  Returns the storage namespace for a base sandbox namespace.
  """
  @spec storage_namespace(pid() | :global) :: storage_namespace()
  def storage_namespace(base_namespace) do
    case current_account() do
      nil -> base_namespace
      account_id -> {base_namespace, account_id}
    end
  end

  @doc """
  Sets the connected account for the current process.
  """
  @spec put_account(account_id()) :: :ok
  def put_account(account_id) when is_binary(account_id) do
    Process.put(@account_key, account_id)
    :ok
  end

  @doc """
  Clears any connected account from the current process.
  """
  @spec clear_account() :: :ok
  def clear_account do
    Process.delete(@account_key)
    :ok
  end

  @doc """
  Runs `fun` with the given connected account ID in the process dictionary.
  """
  @spec with_account(account_id() | nil, (-> result)) :: result when result: term()
  def with_account(account_id, fun) when is_function(fun, 0) do
    previous = Process.get(@account_key, :unset)

    if is_nil(account_id) do
      Process.delete(@account_key)
    else
      Process.put(@account_key, account_id)
    end

    try do
      fun.()
    after
      restore(previous)
    end
  end

  @doc """
  Runs `fun` in platform scope even if the request is account-scoped.
  """
  @spec without_account((-> result)) :: result when result: term()
  def without_account(fun) when is_function(fun, 0), do: with_account(nil, fun)

  @doc """
  Returns true when an ID looks like a Stripe connected account ID.
  """
  @spec account_id?(term()) :: boolean()
  def account_id?(id), do: is_binary(id) and String.starts_with?(id, "acct_")

  defp restore(:unset), do: Process.delete(@account_key)
  defp restore(account_id), do: Process.put(@account_key, account_id)
end
