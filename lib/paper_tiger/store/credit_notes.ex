defmodule PaperTiger.Store.CreditNotes do
  @moduledoc false

  use PaperTiger.Store,
    table: :paper_tiger_credit_notes,
    resource: "credit_note",
    prefix: "cn",
    plural: "credit_notes",
    url_path: "/v1/credit_notes"

  @doc """
  Lists credit notes for an invoice.
  """
  @spec find_by_invoice(String.t()) :: [map()]
  def find_by_invoice(invoice_id) when is_binary(invoice_id) do
    namespace = PaperTiger.Test.current_namespace()

    @table
    |> :ets.match_object({{namespace, :_}, :_})
    |> Enum.map(fn {_key, credit_note} -> credit_note end)
    |> Enum.filter(fn credit_note -> Map.get(credit_note, :invoice) == invoice_id end)
    |> Enum.sort_by(&Map.get(&1, :created), :desc)
  end
end
