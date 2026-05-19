defmodule PaperTiger.Resources.SetupAttempt do
  @moduledoc """
  Handles SetupAttempt resource endpoints.

  ## Endpoints

  - GET /v1/setup_attempts - List setup attempts
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.SetupAttempts

  @doc """
  Lists setup attempts, usually filtered by setup_intent.
  """
  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    pagination_opts = parse_pagination_params(conn.params)
    setup_intent_id = Map.get(conn.params, :setup_intent)

    setup_attempts =
      if setup_intent_id do
        SetupAttempts.find_by_setup_intent(setup_intent_id)
      else
        SetupAttempts.list(%{limit: 100}).data
      end

    result =
      setup_attempts
      |> PaperTiger.List.paginate(Map.put(pagination_opts, :url, "/v1/setup_attempts"))
      |> maybe_expand(conn.params)

    json_response(conn, 200, result)
  end

  defp maybe_expand(result, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(result, expand_params)
  end
end
