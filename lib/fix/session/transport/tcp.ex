defmodule FIX.Session.Transport.TCP do
  @moduledoc false

  @behaviour FIX.Session.Transport

  @impl true
  def connect(host, port, options, timeout) do
    socket_options = [:binary, packet: :raw, active: false, keepalive: true] ++ options
    :gen_tcp.connect(String.to_charlist(host), port, socket_options, timeout)
  end

  @impl true
  def send(socket, bytes), do: :gen_tcp.send(socket, bytes)

  @impl true
  def set_active_once(socket), do: :inet.setopts(socket, active: :once)

  @impl true
  def close(socket), do: :gen_tcp.close(socket)
end
