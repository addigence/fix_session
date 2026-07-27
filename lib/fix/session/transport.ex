defmodule FIX.Session.Transport do
  @moduledoc "Transport contract used by the session state machine."

  @callback connect(binary(), :inet.port_number(), keyword(), timeout()) ::
              {:ok, term()} | {:error, term()}
  @callback send(term(), iodata()) :: :ok | {:error, term()}
  @callback set_active_once(term()) :: :ok | {:error, term()}
  @callback close(term()) :: :ok
end
