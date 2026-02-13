defmodule PaperTiger.Plugs.GetFormBody do
  @moduledoc """
  Parses form-encoded body params for GET requests.

  Plug.Parsers only parses request bodies for POST/PUT/PATCH/DELETE.
  Some HTTP clients (e.g. Stripe SDK wrappers using Req with `form:` option)
  send form-encoded params in the body even for GET requests. This plug reads
  the body and sets `body_params` so that Plug.Parsers merges them with
  query params correctly.
  """

  @behaviour Plug

  alias Plug.Conn.Query
  alias Plug.Conn.Unfetched

  def init(opts), do: opts

  def call(%{body_params: %Unfetched{}, method: "GET"} = conn, _opts) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      ["application/x-www-form-urlencoded" <> _] ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{conn | body_params: Query.decode(body)}

      _ ->
        conn
    end
  end

  def call(conn, _opts), do: conn
end
