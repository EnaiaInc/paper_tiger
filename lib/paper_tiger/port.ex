defmodule PaperTiger.Port do
  @moduledoc false

  alias PaperTiger.Port.Reservation
  alias PaperTiger.Port.ReservedTransport

  @min_port 59_000
  @max_port 60_000
  @attempts 10
  @reservation_key :port_reservation
  @transport_options_key :transport_options

  @spec resolve() :: integer()
  def resolve do
    case Application.get_env(:paper_tiger, :actual_port) do
      nil -> resolve_unstarted()
      port -> port
    end
  end

  @spec resolve_for_bandit() :: {integer(), keyword()}
  def resolve_for_bandit do
    case Application.get_env(:paper_tiger, :actual_port) do
      nil -> resolve_unstarted_for_bandit()
      port -> {port, []}
    end
  end

  @spec take_reserved_socket(pid(), integer(), ThousandIsland.Transport.listen_options(), pid()) ::
          {:ok, :inet.socket()} | {:error, term()}
  def take_reserved_socket(reservation, expected_port, expected_transport_options, new_owner)
      when is_pid(reservation) and is_integer(expected_port) and is_pid(new_owner) do
    case Reservation.take(reservation, expected_port, expected_transport_options, new_owner) do
      {:ok, socket} ->
        clear_reservation(reservation)
        {:ok, socket}

      {:error, reason} ->
        close_reserved_socket(reservation)
        {:error, reason}
    end
  end

  @spec close_reserved_socket(pid()) :: :ok
  def close_reserved_socket(reservation) when is_pid(reservation) do
    Reservation.close(reservation)
    clear_reservation(reservation)
  end

  defp resolve_unstarted do
    case System.get_env("PAPER_TIGER_PORT") do
      nil ->
        case Application.get_env(:paper_tiger, :port) do
          nil ->
            %{port: port} = reservation = reserve_available_port(@attempts)
            Application.put_env(:paper_tiger, :port, port)
            Application.put_env(:paper_tiger, @reservation_key, reservation)
            port

          port ->
            clear_reservation_unless(port)
            port
        end

      port_string ->
        port = String.to_integer(port_string)
        clear_reservation()
        Application.put_env(:paper_tiger, :port, port)
        port
    end
  end

  defp resolve_unstarted_for_bandit do
    case System.get_env("PAPER_TIGER_PORT") do
      nil ->
        resolve_configured_or_reserved_for_bandit()

      port_string ->
        port = String.to_integer(port_string)
        clear_reservation()
        Application.put_env(:paper_tiger, :port, port)
        {port, bandit_options(nil)}
    end
  end

  defp resolve_configured_or_reserved_for_bandit do
    case Application.get_env(:paper_tiger, :port) do
      nil ->
        %{port: port} = reservation = reserve_available_port(@attempts)
        Application.put_env(:paper_tiger, :port, port)
        {port, bandit_options(reservation)}

      port ->
        {port, port |> current_reservation() |> bandit_options()}
    end
  end

  defp reserve_available_port(attempts) when attempts > 0 do
    port = random_high_port()

    case Reservation.start(port, transport_options()) do
      {:ok, reservation} ->
        reservation

      {:error, :eaddrinuse} ->
        reserve_available_port(attempts - 1)

      {:error, _reason} ->
        reserve_available_port(attempts - 1)
    end
  end

  defp reserve_available_port(_attempts) do
    raise "PaperTiger could not reserve an available port in #{@min_port}-#{@max_port}"
  end

  defp random_high_port do
    @min_port + :rand.uniform(@max_port - @min_port + 1) - 1
  end

  defp current_reservation(port) do
    case Application.get_env(:paper_tiger, @reservation_key) do
      %{pid: pid, port: ^port} = reservation when is_pid(pid) ->
        if Process.alive?(pid) do
          reservation
        else
          clear_reservation(pid)
          nil
        end

      %{pid: pid} when is_pid(pid) ->
        Reservation.close(pid)
        Application.delete_env(:paper_tiger, @reservation_key)
        nil

      _reservation ->
        nil
    end
  end

  defp transport_options do
    Application.get_env(:paper_tiger, @transport_options_key, [])
  end

  defp bandit_options(nil) do
    case transport_options() do
      [] ->
        []

      options ->
        [thousand_island_options: [transport_options: options]]
    end
  end

  defp bandit_options(%{pid: pid, transport_options: transport_options}) when is_pid(pid) do
    [
      thousand_island_options: [
        transport_module: ReservedTransport,
        transport_options: [{:paper_tiger_port_reservation, pid} | transport_options]
      ]
    ]
  end

  defp clear_reservation do
    case Application.get_env(:paper_tiger, @reservation_key) do
      %{pid: pid} when is_pid(pid) ->
        Reservation.close(pid)

      _reservation ->
        :ok
    end

    Application.delete_env(:paper_tiger, @reservation_key)
  end

  defp clear_reservation(pid) do
    case Application.get_env(:paper_tiger, @reservation_key) do
      %{pid: ^pid} ->
        Application.delete_env(:paper_tiger, @reservation_key)

      _reservation ->
        :ok
    end
  end

  defp clear_reservation_unless(port) do
    case Application.get_env(:paper_tiger, @reservation_key) do
      %{port: ^port} ->
        :ok

      %{pid: pid} when is_pid(pid) ->
        Reservation.close(pid)
        Application.delete_env(:paper_tiger, @reservation_key)

      _reservation ->
        :ok
    end
  end
end
