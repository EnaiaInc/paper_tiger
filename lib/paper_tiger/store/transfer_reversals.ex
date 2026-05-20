defmodule PaperTiger.Store.TransferReversals do
  @moduledoc """
  ETS-backed storage for Connect Transfer Reversal resources.
  """

  use PaperTiger.Store,
    table: :paper_tiger_transfer_reversals,
    resource: "transfer_reversal",
    prefix: "trr",
    plural: "transfer_reversals",
    url_path: "/v1/transfers"

  @doc """
  Lists reversals for a transfer in the current request scope.
  """
  @spec find_by_transfer(String.t()) :: [map()]
  def find_by_transfer(transfer_id) when is_binary(transfer_id) do
    namespace = PaperTiger.Connect.storage_namespace()

    :ets.match_object(@table, {{namespace, :_}, %{transfer: transfer_id}})
    |> Enum.map(fn {_key, reversal} -> reversal end)
  end
end
