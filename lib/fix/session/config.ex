defmodule FIX.Session.Config do
  @moduledoc "Configuration for an initiator FIX session."

  @enforce_keys [:session_id, :host, :port, :sender_comp_id, :target_comp_id]
  defstruct [
    :session_id,
    :host,
    :port,
    :sender_comp_id,
    :target_comp_id,
    begin_string: "FIX.4.4",
    dictionary: FIX.Dictionary.FIX44,
    heartbeat_interval: 30,
    reset_on_logon: false,
    default_appl_ver_id: nil,
    reconnect_interval: 5_000,
    connect_timeout: 5_000,
    transport: FIX.Session.Transport.TCP,
    transport_options: [],
    store: FIX.Session.Store.ETS,
    store_ref: FIX.Session.Store.ETS,
    app: nil,
    name: nil
  ]

  @type t :: %__MODULE__{
          session_id: term(),
          host: binary(),
          port: :inet.port_number(),
          sender_comp_id: binary(),
          target_comp_id: binary(),
          begin_string: binary(),
          dictionary: module(),
          heartbeat_interval: non_neg_integer(),
          reset_on_logon: boolean(),
          default_appl_ver_id: binary() | nil,
          reconnect_interval: non_neg_integer(),
          connect_timeout: pos_integer(),
          transport: module(),
          transport_options: keyword(),
          store: module(),
          store_ref: term(),
          app: module() | nil,
          name: GenServer.name() | nil
        }

  @spec new!(keyword()) :: t()
  def new!(options) do
    config = struct!(__MODULE__, options)

    unless is_binary(config.host) and is_integer(config.port) and config.port in 1..65_535 do
      raise ArgumentError, "host must be a string and port must be between 1 and 65535"
    end

    unless is_binary(config.sender_comp_id) and is_binary(config.target_comp_id) do
      raise ArgumentError, "sender_comp_id and target_comp_id must be strings"
    end

    unless is_integer(config.heartbeat_interval) and config.heartbeat_interval >= 0 do
      raise ArgumentError, "heartbeat_interval must be a non-negative integer"
    end

    # store_ref is deliberately opaque to the session, so only the module is
    # checked here. The store must already be running when a session starts.
    unless is_atom(config.store) do
      raise ArgumentError, "store must be a module implementing FIX.Session.Store"
    end

    config
  end
end
