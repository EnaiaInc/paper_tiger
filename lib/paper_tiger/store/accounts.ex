defmodule PaperTiger.Store.Accounts do
  @moduledoc """
  ETS-backed storage for Connect Account resources.
  """

  use PaperTiger.Store,
    table: :paper_tiger_accounts,
    resource: "account",
    prefix: "acct",
    plural: "accounts"
end
