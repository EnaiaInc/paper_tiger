defmodule PaperTiger.Store.SetupAttempts do
  @moduledoc """
  ETS-backed storage for SetupAttempt resources.

  SetupAttempts record each SetupIntent confirmation attempt and are scoped by
  the same PaperTiger test namespace as the SetupIntent they belong to.
  """

  use PaperTiger.Store,
    table: :paper_tiger_setup_attempts,
    resource: "setup_attempt",
    plural: "setup_attempts",
    prefix: "setatt"

  @doc """
  Finds setup attempts associated with a SetupIntent ID.

  **Direct ETS access** - does not go through GenServer.
  """
  @spec find_by_setup_intent(String.t() | nil) :: [map()]
  def find_by_setup_intent(nil), do: []

  def find_by_setup_intent(setup_intent_id) when is_binary(setup_intent_id) do
    namespace = PaperTiger.Test.current_namespace()

    :ets.match_object(@table, {{namespace, :_}, %{setup_intent: setup_intent_id}})
    |> Enum.map(fn {_key, setup_attempt} -> setup_attempt end)
  end
end
