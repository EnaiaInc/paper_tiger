defmodule PaperTiger.Plugs.Sandbox do
  @moduledoc """
  Plug that extracts test namespace from HTTP headers for sandbox isolation.

  When a request includes the `x-paper-tiger-namespace` header, this plug
  sets the namespace in the process dictionary so that all PaperTiger
  operations scope data to that namespace.

  ## Usage in Tests

      # In your test setup
      setup :checkout_paper_tiger

      # When making HTTP requests, include the namespace header
      Req.post(url,
        headers: [
          {"authorization", "Bearer sk_test_mock"},
          {"x-paper-tiger-namespace", inspect(self())}
        ]
      )

      # Or use the helper from PaperTiger.Test
      Req.post(url, headers: PaperTiger.Test.sandbox_headers())

  ## How It Works

  1. Client sends `x-paper-tiger-namespace` header with the test PID as a string
  2. This plug parses the PID and sets it in the process dictionary
  3. All subsequent store operations in this request use that namespace
  4. Data is isolated from other concurrent tests
  """

  import Plug.Conn

  @namespace_header "x-paper-tiger-namespace"

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, @namespace_header) do
      [namespace_string | _] ->
        # Parse the namespace (could be a PID string like "#PID<0.123.0>")
        namespace = parse_namespace(namespace_string)
        Process.put(:paper_tiger_namespace, namespace)
        conn

      [] ->
        # No namespace header - use :global (default behavior)
        conn
    end
  end

  defp parse_namespace(string) do
    # Try to parse as a PID string first
    case parse_pid_string(string) do
      {:ok, pid} -> pid
      :error -> String.to_atom(string)
    end
  end

  # Parse PID string like "#PID<0.123.0>" or "0.123.0"
  defp parse_pid_string(string) do
    # Remove #PID< and > if present
    cleaned =
      string
      |> String.replace_prefix("#PID<", "")
      |> String.replace_suffix(">", "")

    case String.split(cleaned, ".") do
      [a, b, c] ->
        try do
          pid = :c.pid(String.to_integer(a), String.to_integer(b), String.to_integer(c))
          {:ok, pid}
        rescue
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
