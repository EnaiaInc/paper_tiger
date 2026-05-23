defmodule PaperTiger.PortTest do
  use ExUnit.Case, async: false

  alias PaperTiger.Port.Reservation
  alias PaperTiger.Port.ReservedTransport

  defmodule TestPlug do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      send_resp(conn, 200, "ok")
    end
  end

  setup do
    env_port = System.get_env("PAPER_TIGER_PORT")
    config_port = Application.get_env(:paper_tiger, :port)
    actual_port = Application.get_env(:paper_tiger, :actual_port)
    reservation = Application.get_env(:paper_tiger, :port_reservation)
    transport_options = Application.get_env(:paper_tiger, :transport_options)

    on_exit(fn ->
      current_reservation = Application.get_env(:paper_tiger, :port_reservation)

      if current_reservation != reservation do
        close_reservation(current_reservation)
      end

      if is_nil(env_port) do
        System.delete_env("PAPER_TIGER_PORT")
      else
        System.put_env("PAPER_TIGER_PORT", env_port)
      end

      if is_nil(config_port) do
        Application.delete_env(:paper_tiger, :port)
      else
        Application.put_env(:paper_tiger, :port, config_port)
      end

      if is_nil(actual_port) do
        Application.delete_env(:paper_tiger, :actual_port)
      else
        Application.put_env(:paper_tiger, :actual_port, actual_port)
      end

      if is_nil(reservation) do
        Application.delete_env(:paper_tiger, :port_reservation)
      else
        Application.put_env(:paper_tiger, :port_reservation, reservation)
      end

      if is_nil(transport_options) do
        Application.delete_env(:paper_tiger, :transport_options)
      else
        Application.put_env(:paper_tiger, :transport_options, transport_options)
      end
    end)

    :ok
  end

  test "get_port resolves and caches before startup" do
    System.delete_env("PAPER_TIGER_PORT")
    Application.delete_env(:paper_tiger, :port)
    Application.delete_env(:paper_tiger, :actual_port)

    port = PaperTiger.get_port()

    assert is_integer(port)
    assert port >= 59_000
    assert port <= 60_000
    assert Application.get_env(:paper_tiger, :port) == port
    assert PaperTiger.get_port() == port
  end

  test "random port stays reserved until Bandit takes the listener socket" do
    System.delete_env("PAPER_TIGER_PORT")
    Application.delete_env(:paper_tiger, :port)
    Application.delete_env(:paper_tiger, :actual_port)

    {port, bandit_options} = PaperTiger.Port.resolve_for_bandit()
    reservation = reservation_from_bandit_options(bandit_options)

    on_exit(fn ->
      close_reservation(reservation)
    end)

    refute Application.get_env(:paper_tiger, :port_reservation)

    assert {:error, :eaddrinuse} =
             :gen_tcp.listen(port, mode: :binary, active: false, reuseaddr: true)

    spec =
      {Bandit, [plug: TestPlug, port: port, scheme: :http, startup_log: false] ++ bandit_options}

    pid = start_supervised!(spec)

    assert {:ok, {_ip, ^port}} = ThousandIsland.listener_info(pid)
    refute Application.get_env(:paper_tiger, :port_reservation)
  end

  test "port resolved before startup stays reserved until Bandit takes it" do
    System.delete_env("PAPER_TIGER_PORT")
    Application.delete_env(:paper_tiger, :port)
    Application.delete_env(:paper_tiger, :actual_port)

    port = PaperTiger.get_port()
    reservation = Application.get_env(:paper_tiger, :port_reservation)

    assert %{pid: reservation_pid, port: ^port} = reservation

    assert {:error, :eaddrinuse} =
             :gen_tcp.listen(port, mode: :binary, active: false, reuseaddr: true)

    {^port, bandit_options} = PaperTiger.Port.resolve_for_bandit()
    assert reservation_pid == reservation_from_bandit_options(bandit_options)

    spec =
      {Bandit, [plug: TestPlug, port: port, scheme: :http, startup_log: false] ++ bandit_options}

    pid = start_supervised!(spec)

    assert {:ok, {_ip, ^port}} = ThousandIsland.listener_info(pid)
    refute Process.alive?(reservation_pid)
    refute Application.get_env(:paper_tiger, :port_reservation)
  end

  test "failed reservation handoff clears the reservation" do
    {:ok, reservation} = Reservation.start(0)
    Application.put_env(:paper_tiger, :port_reservation, reservation)

    dead_owner = spawn(fn -> :ok end)
    ref = Process.monitor(dead_owner)
    assert_receive {:DOWN, ^ref, :process, ^dead_owner, :normal}

    assert {:error, _reason} =
             PaperTiger.Port.take_reserved_socket(reservation.pid, reservation.port, [], dead_owner)

    refute Process.alive?(reservation.pid)
    refute Application.get_env(:paper_tiger, :port_reservation)
  end

  test "reserved transport preserves reserved transport options" do
    transport_options = [ip: {127, 0, 0, 1}]

    {:ok, reservation} = Reservation.start(0, transport_options)
    Application.put_env(:paper_tiger, :port_reservation, reservation)

    assert {:ok, socket} =
             ReservedTransport.listen(
               reservation.port,
               paper_tiger_port_reservation: reservation.pid,
               ip: {127, 0, 0, 1}
             )

    assert {:ok, {{127, 0, 0, 1}, reservation.port}} == :inet.sockname(socket)

    :gen_tcp.close(socket)
    refute Process.alive?(reservation.pid)
    refute Application.get_env(:paper_tiger, :port_reservation)
  end

  test "resolve_for_bandit reserves with configured transport options" do
    System.delete_env("PAPER_TIGER_PORT")
    Application.delete_env(:paper_tiger, :port)
    Application.delete_env(:paper_tiger, :actual_port)
    Application.put_env(:paper_tiger, :transport_options, ip: {127, 0, 0, 1})

    {port, bandit_options} = PaperTiger.Port.resolve_for_bandit()
    reservation = Application.get_env(:paper_tiger, :port_reservation)

    on_exit(fn ->
      close_reservation(reservation_from_bandit_options(bandit_options))
      close_reservation(reservation)
    end)

    assert reservation_from_bandit_options(bandit_options)

    spec =
      {Bandit, [plug: TestPlug, port: port, scheme: :http, startup_log: false] ++ bandit_options}

    pid = start_supervised!(spec)

    assert {:ok, {{127, 0, 0, 1}, ^port}} = ThousandIsland.listener_info(pid)
    refute Application.get_env(:paper_tiger, :port_reservation)
  end

  test "reservation from transient early resolver survives the resolver process" do
    System.delete_env("PAPER_TIGER_PORT")
    Application.delete_env(:paper_tiger, :port)
    Application.delete_env(:paper_tiger, :actual_port)

    parent = self()

    resolver =
      spawn(fn ->
        port = PaperTiger.get_port()
        reservation = Application.get_env(:paper_tiger, :port_reservation)
        send(parent, {:resolved, port, reservation})
        exit(:resolver_done)
      end)

    ref = Process.monitor(resolver)

    assert_receive {:resolved, port, %{pid: reservation_pid, port: reservation_port}}
    assert reservation_port == port
    assert_receive {:DOWN, ^ref, :process, ^resolver, :resolver_done}
    assert Process.alive?(reservation_pid)

    {^port, bandit_options} = PaperTiger.Port.resolve_for_bandit()

    spec =
      {Bandit, [plug: TestPlug, port: port, scheme: :http, startup_log: false] ++ bandit_options}

    pid = start_supervised!(spec)

    assert {:ok, {_ip, ^port}} = ThousandIsland.listener_info(pid)
    refute Process.alive?(reservation_pid)
    refute Application.get_env(:paper_tiger, :port_reservation)
  end

  defp close_reservation(%{pid: pid}) when is_pid(pid) do
    Reservation.close(pid)
  end

  defp close_reservation(pid) when is_pid(pid) do
    Reservation.close(pid)
  end

  defp close_reservation(_reservation), do: :ok

  defp reservation_from_bandit_options(bandit_options) do
    bandit_options
    |> get_in([:thousand_island_options, :transport_options, :paper_tiger_port_reservation])
  end
end
