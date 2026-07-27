defmodule FIX.Session.Transport do
  @moduledoc """
  Transport contract for initiator sessions.

  Implementations move bytes and nothing else: they must not parse or
  interpret FIX messages. The session process is the controlling process
  for the socket; `connect/4` must return a passive socket, and the session
  re-arms delivery with `set_active_once/1` only after it has processed
  each socket event, so socket messages and sequence transitions stay
  serialized.
  """

  @type socket :: term()
  @type host :: binary() | charlist() | :inet.ip_address()

  @callback connect(host(), :inet.port_number(), options :: keyword(), timeout()) ::
              {:ok, socket()} | {:error, term()}

  @callback send(socket(), iodata()) :: :ok | {:error, term()}

  @callback set_active_once(socket()) :: :ok | {:error, term()}

  @callback close(socket()) :: :ok
end
