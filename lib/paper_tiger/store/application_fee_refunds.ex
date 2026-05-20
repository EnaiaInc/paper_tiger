defmodule PaperTiger.Store.ApplicationFeeRefunds do
  @moduledoc """
  ETS-backed storage for Application Fee Refund resources.
  """

  use PaperTiger.Store,
    table: :paper_tiger_application_fee_refunds,
    resource: "fee_refund",
    prefix: "fr",
    plural: "application_fee_refunds",
    url_path: "/v1/application_fees"

  @doc """
  Lists refunds for an application fee in platform scope.
  """
  @spec find_by_fee(String.t()) :: [map()]
  def find_by_fee(fee_id) when is_binary(fee_id) do
    PaperTiger.Connect.without_account(fn ->
      namespace = PaperTiger.Connect.storage_namespace()

      :ets.match_object(@table, {{namespace, :_}, %{fee: fee_id}})
      |> Enum.map(fn {_key, refund} -> refund end)
    end)
  end
end
