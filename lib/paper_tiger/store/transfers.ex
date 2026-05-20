defmodule PaperTiger.Store.Transfers do
  @moduledoc """
  ETS-backed storage for Connect Transfer resources.
  """

  use PaperTiger.Store,
    table: :paper_tiger_transfers,
    resource: "transfer",
    prefix: "tr",
    plural: "transfers"

  @doc """
  Finds transfers by destination account in the current request scope.
  """
  @spec find_by_destination(String.t()) :: [map()]
  def find_by_destination(destination) when is_binary(destination) do
    namespace = PaperTiger.Connect.storage_namespace()

    :ets.match_object(@table, {{namespace, :_}, %{destination: destination}})
    |> Enum.map(fn {_key, transfer} -> transfer end)
  end
end
