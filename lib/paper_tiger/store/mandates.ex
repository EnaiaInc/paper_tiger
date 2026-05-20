defmodule PaperTiger.Store.Mandates do
  @moduledoc """
  ETS-backed storage for Mandate resources.
  """

  use PaperTiger.Store,
    table: :paper_tiger_mandates,
    resource: "mandate",
    plural: "mandates",
    prefix: "mandate"
end
