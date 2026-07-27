defmodule FIX.Session.Transport.TCP do
  @moduledoc """
  TCP initiator transport over `:gen_tcp`.

  Sockets are binary, unpacketized, and passive; the session enables each
  read with `set_active_once/1`. User options may tune the socket (buffer
  sizes, `:nodelay`, ...) but cannot override the mode, packeting, or
  active flag the session depends on.
  """

  @behaviour FIX.Session.Transport

  # Defaults first so options can override them; forced options last so
  # options cannot: inet applies later list entries over earlier ones.
  @defaults [nodelay: true, keepalive: true]
  @forced [mode: :binary, packet: :raw, active: false]

  @impl true
  def connect(host, port, options, timeout),
    do: :gen_tcp.connect(normalize_host(host), port, @defaults ++ options ++ @forced, timeout)

  @impl true
  def send(socket, bytes), do: :gen_tcp.send(socket, bytes)

  @impl true
  def set_active_once(socket), do: :inet.setopts(socket, active: :once)

  @impl true
  def close(socket), do: :gen_tcp.close(socket)

  defp normalize_host(host) when is_binary(host), do: String.to_charlist(host)
  defp normalize_host(host), do: host
end
