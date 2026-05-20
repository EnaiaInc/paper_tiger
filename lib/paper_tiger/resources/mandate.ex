defmodule PaperTiger.Resources.Mandate do
  @moduledoc """
  Handles Mandate resource endpoints.
  """

  import PaperTiger.Resource

  alias PaperTiger.Store.Mandates

  @doc """
  Retrieves a mandate by ID.
  """
  @spec retrieve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retrieve(conn, id) do
    case Mandates.get(id) do
      {:ok, mandate} ->
        mandate
        |> maybe_expand(conn.params)
        |> then(&json_response(conn, 200, &1))

      {:error, :not_found} ->
        error_response(conn, PaperTiger.Error.not_found("mandate", id))
    end
  end

  defp maybe_expand(mandate, params) do
    expand_params = parse_expand_params(params)
    PaperTiger.Hydrator.hydrate(mandate, expand_params)
  end
end
