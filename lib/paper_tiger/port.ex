defmodule PaperTiger.Port do
  @moduledoc false

  @min_port 59_000
  @max_port 60_000
  @attempts 10

  @spec resolve() :: integer()
  def resolve do
    case Application.get_env(:paper_tiger, :actual_port) do
      nil -> resolve_unstarted()
      port -> port
    end
  end

  defp resolve_unstarted do
    case System.get_env("PAPER_TIGER_PORT") do
      nil ->
        case Application.get_env(:paper_tiger, :port) do
          nil ->
            port = find_available_port(@attempts)
            Application.put_env(:paper_tiger, :port, port)
            port

          port ->
            port
        end

      port_string ->
        port = String.to_integer(port_string)
        Application.put_env(:paper_tiger, :port, port)
        port
    end
  end

  defp find_available_port(attempts) when attempts > 1 do
    port = random_high_port()

    if port_available?(port) do
      port
    else
      find_available_port(attempts - 1)
    end
  end

  defp find_available_port(_attempts) do
    random_high_port()
  end

  defp random_high_port do
    @min_port + :rand.uniform(@max_port - @min_port)
  end

  defp port_available?(port) do
    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end
end
