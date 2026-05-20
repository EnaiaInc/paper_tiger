defmodule PaperTiger.Store.ConfirmationTokens do
  @moduledoc """
  ETS-backed storage for ConfirmationToken resources.
  """

  use PaperTiger.Store,
    table: :paper_tiger_confirmation_tokens,
    resource: "confirmation_token",
    plural: "confirmation_tokens",
    prefix: "ctoken"
end
