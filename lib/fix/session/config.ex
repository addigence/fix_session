defmodule FIX.Session.Config do
  @moduledoc """
  Validated configuration for one initiator FIX session.

  Build with `new!/1`. Required fields identify the session and the
  counterparty endpoint; everything else has a working default:

    * `:session_id` — term identifying the logical session in the store
    * `:host`, `:port` — counterparty endpoint
    * `:sender_comp_id`, `:target_comp_id` — SenderCompID(49) and
      TargetCompID(56) as sent by this side

  `:heartbeat_interval` is HeartBtInt(108) in seconds; `0` disables both
  idle timers. `:store_ref` defaults to the store module itself, which
  matches `FIX.Session.Store.ETS` running with its default named table.
  """

  @enforce_keys [:session_id, :host, :port, :sender_comp_id, :target_comp_id]
  defstruct [
    :session_id,
    :host,
    :port,
    :sender_comp_id,
    :target_comp_id,
    :store_ref,
    name: nil,
    begin_string: "FIX.4.4",
    heartbeat_interval: 30,
    connect_timeout: 10_000,
    logon_timeout: 10_000,
    logout_timeout: 10_000,
    reconnect_interval: 5_000,
    transport: FIX.Session.Transport.TCP,
    transport_options: [],
    store: FIX.Session.Store.ETS,
    dictionary: FIX.Dictionary.FIX44,
    app: nil,
    reset_on_logon: false,
    default_appl_ver_id: nil
  ]

  @type t :: %__MODULE__{
          session_id: term(),
          name: atom() | :gen_statem.server_name() | nil,
          host: binary() | charlist() | :inet.ip_address(),
          port: :inet.port_number(),
          begin_string: binary(),
          sender_comp_id: binary(),
          target_comp_id: binary(),
          heartbeat_interval: non_neg_integer(),
          connect_timeout: pos_integer(),
          logon_timeout: pos_integer(),
          logout_timeout: pos_integer(),
          reconnect_interval: pos_integer(),
          transport: module(),
          transport_options: keyword(),
          store: module(),
          store_ref: term(),
          dictionary: module(),
          app: module() | nil,
          reset_on_logon: boolean(),
          default_appl_ver_id: binary() | nil
        }

  @doc """
  Builds a validated config from `options`.

  Raises `ArgumentError` on missing required fields, unknown fields, or
  values of the wrong type.
  """
  @spec new!(keyword()) :: t()
  def new!(options) when is_list(options) do
    options =
      options
      |> Keyword.put_new(:store, FIX.Session.Store.ETS)
      |> then(&Keyword.put_new(&1, :store_ref, Keyword.fetch!(&1, :store)))

    __MODULE__ |> struct!(options) |> validate!()
  end

  defp validate!(%__MODULE__{} = config) do
    ensure!(
      is_binary(config.host) or is_list(config.host) or is_tuple(config.host),
      :host,
      config.host,
      "a hostname binary or charlist, or an IP tuple"
    )

    ensure!(
      is_integer(config.port) and config.port in 1..65_535,
      :port,
      config.port,
      "a port number"
    )

    ensure!(is_binary(config.begin_string), :begin_string, config.begin_string, "a binary")
    ensure!(is_binary(config.sender_comp_id), :sender_comp_id, config.sender_comp_id, "a binary")
    ensure!(is_binary(config.target_comp_id), :target_comp_id, config.target_comp_id, "a binary")

    ensure!(
      is_integer(config.heartbeat_interval) and config.heartbeat_interval >= 0,
      :heartbeat_interval,
      config.heartbeat_interval,
      "seconds as a non-negative integer (0 disables heartbeats)"
    )

    ensure!(
      is_integer(config.connect_timeout) and config.connect_timeout > 0,
      :connect_timeout,
      config.connect_timeout,
      "milliseconds as a positive integer"
    )

    ensure!(
      is_integer(config.logon_timeout) and config.logon_timeout > 0,
      :logon_timeout,
      config.logon_timeout,
      "milliseconds as a positive integer"
    )

    ensure!(
      is_integer(config.logout_timeout) and config.logout_timeout > 0,
      :logout_timeout,
      config.logout_timeout,
      "milliseconds as a positive integer"
    )

    ensure!(
      is_integer(config.reconnect_interval) and config.reconnect_interval > 0,
      :reconnect_interval,
      config.reconnect_interval,
      "milliseconds as a positive integer"
    )

    ensure!(is_atom(config.transport), :transport, config.transport, "a module")

    ensure!(
      is_list(config.transport_options),
      :transport_options,
      config.transport_options,
      "a list"
    )

    ensure!(is_atom(config.store), :store, config.store, "a module")
    ensure!(is_atom(config.dictionary), :dictionary, config.dictionary, "a module")
    ensure!(is_atom(config.app), :app, config.app, "a module or nil")

    ensure!(
      config.reset_on_logon == false,
      :reset_on_logon,
      config.reset_on_logon,
      "false (ResetSeqNumFlag logon reset is not implemented)"
    )

    ensure!(
      is_nil(config.default_appl_ver_id) or is_binary(config.default_appl_ver_id),
      :default_appl_ver_id,
      config.default_appl_ver_id,
      "a binary or nil"
    )

    config
  end

  defp ensure!(true, _key, _value, _expected), do: :ok

  defp ensure!(false, key, value, expected) do
    raise ArgumentError, "expected #{inspect(key)} to be #{expected}, got: #{inspect(value)}"
  end
end
