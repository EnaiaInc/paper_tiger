defmodule PaperTiger.Port.ReservedTransport do
  @moduledoc false

  @behaviour ThousandIsland.Transport

  alias ThousandIsland.Transports.TCP

  @impl ThousandIsland.Transport
  def listen(port, user_options) do
    case pop_reservation(user_options) do
      {nil, options} ->
        TCP.listen(port, options)

      {reservation, options} ->
        PaperTiger.Port.take_reserved_socket(reservation, port, options, self())
    end
  end

  defp pop_reservation(user_options) do
    {reservation, options} =
      Enum.reduce(user_options, {nil, []}, fn
        {:paper_tiger_port_reservation, reservation}, {_current, options} ->
          {reservation, options}

        option, {reservation, options} ->
          {reservation, [option | options]}
      end)

    {reservation, Enum.reverse(options)}
  end

  @impl ThousandIsland.Transport
  defdelegate accept(listener_socket), to: TCP

  @impl ThousandIsland.Transport
  defdelegate handshake(socket), to: TCP

  @impl ThousandIsland.Transport
  defdelegate upgrade(socket, options), to: TCP

  @impl ThousandIsland.Transport
  defdelegate controlling_process(socket, pid), to: TCP

  @impl ThousandIsland.Transport
  defdelegate recv(socket, length, timeout), to: TCP

  @impl ThousandIsland.Transport
  defdelegate send(socket, data), to: TCP

  @impl ThousandIsland.Transport
  defdelegate sendfile(socket, filename, offset, length), to: TCP

  @impl ThousandIsland.Transport
  defdelegate getopts(socket, options), to: TCP

  @impl ThousandIsland.Transport
  defdelegate setopts(socket, options), to: TCP

  @impl ThousandIsland.Transport
  defdelegate shutdown(socket, way), to: TCP

  @impl ThousandIsland.Transport
  defdelegate close(socket), to: TCP

  @impl ThousandIsland.Transport
  defdelegate sockname(socket), to: TCP

  @impl ThousandIsland.Transport
  defdelegate peername(socket), to: TCP

  @impl ThousandIsland.Transport
  defdelegate peercert(socket), to: TCP

  @impl ThousandIsland.Transport
  defdelegate secure?(), to: TCP

  @impl ThousandIsland.Transport
  defdelegate getstat(socket), to: TCP

  @impl ThousandIsland.Transport
  defdelegate negotiated_protocol(socket), to: TCP

  @impl ThousandIsland.Transport
  defdelegate connection_information(socket), to: TCP
end
