defmodule PaperTiger.Port.Reservation do
  @moduledoc false

  use GenServer

  alias ThousandIsland.Transports.TCP

  @type reservation :: %{
          pid: pid(),
          port: integer(),
          transport_options: ThousandIsland.Transport.listen_options()
        }

  @spec start(integer(), ThousandIsland.Transport.listen_options()) ::
          {:ok, reservation()} | {:error, term()}
  def start(port, transport_options \\ []) when is_integer(port) do
    with {:ok, pid} <- GenServer.start(__MODULE__, {port, transport_options}),
         {:ok, reserved_port} <- GenServer.call(pid, :port) do
      {:ok, %{pid: pid, port: reserved_port, transport_options: transport_options}}
    end
  end

  @spec take(pid(), integer(), ThousandIsland.Transport.listen_options(), pid()) ::
          {:ok, :inet.socket()} | {:error, term()}
  def take(pid, expected_port, expected_transport_options, new_owner) do
    GenServer.call(pid, {:take, expected_port, expected_transport_options, new_owner})
  end

  @spec close(pid()) :: :ok
  def close(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init({port, transport_options}) do
    case TCP.listen(port, transport_options) do
      {:ok, socket} ->
        {:ok, {_ip, reserved_port}} = :inet.sockname(socket)
        {:ok, %{port: reserved_port, socket: socket, transport_options: transport_options}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _from, state) do
    {:reply, {:ok, state.port}, state}
  end

  def handle_call({:take, expected_port, _expected_transport_options, _new_owner}, _from, %{port: port} = state)
      when port != expected_port do
    {:stop, :normal, {:error, {:unexpected_port, port}}, state}
  end

  def handle_call(
        {:take, _expected_port, expected_transport_options, _new_owner},
        _from,
        %{transport_options: transport_options} = state
      )
      when expected_transport_options != transport_options do
    {:stop, :normal, {:error, {:unexpected_transport_options, transport_options}}, state}
  end

  def handle_call({:take, _expected_port, _expected_transport_options, new_owner}, _from, state) do
    case :gen_tcp.controlling_process(state.socket, new_owner) do
      :ok ->
        {:stop, :normal, {:ok, state.socket}, %{state | socket: nil}}

      {:error, reason} ->
        {:stop, :normal, {:error, reason}, state}
    end
  end

  @impl true
  def terminate(_reason, %{socket: nil}), do: :ok

  def terminate(_reason, %{socket: socket}) do
    :gen_tcp.close(socket)
  end
end
