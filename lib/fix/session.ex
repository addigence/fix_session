defmodule FIX.Session do
  @moduledoc """
  Initiator-side FIX session state machine.

  `FIX.Session.Protocol` makes deterministic protocol decisions. This module
  owns runtime effects: transport, persistence, timers, and application
  delivery.
  """

  @behaviour :gen_statem

  alias FIX.Session.Config
  alias FIX.Session.Framing
  alias FIX.Session.Messages
  alias FIX.Session.Protocol
  alias FIX.Session.State

  require Logger

  defmodule Data do
    @moduledoc false
    @enforce_keys [:config, :protocol]
    defstruct [:config, :protocol, :socket, buffer: <<>>, auto_reconnect: true]
  end

  @spec child_spec(Config.t()) :: Supervisor.child_spec()
  def child_spec(%Config{} = config) do
    %{
      id: config.session_id,
      start: {__MODULE__, :start_link, [config]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec start_link(Config.t(), keyword()) :: :gen_statem.start_ret()
  def start_link(%Config{} = config, options \\ []) do
    name = Keyword.get(options, :name, config.name)

    case name do
      nil -> :gen_statem.start_link(__MODULE__, config, [])
      name when is_atom(name) -> :gen_statem.start_link({:local, name}, __MODULE__, config, [])
      name -> :gen_statem.start_link(name, __MODULE__, config, [])
    end
  end

  @spec send_message(:gen_statem.server_ref(), FIX.Message.t()) :: :ok | {:error, term()}
  def send_message(session, %FIX.Message{} = message),
    do: :gen_statem.call(session, {:send, message})

  @spec logout(:gen_statem.server_ref(), binary() | nil) :: :ok | {:error, term()}
  def logout(session, text \\ nil), do: :gen_statem.call(session, {:logout, text})

  # ----------------------------------------------------------------------------
  # Callbacks
  # ----------------------------------------------------------------------------

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(%Config{} = config) do
    case config.store.load(config.store_ref, config.session_id) do
      {:ok, sequences} ->
        protocol = %State{
          begin_string: config.begin_string,
          sender_comp_id: config.sender_comp_id,
          target_comp_id: config.target_comp_id,
          heartbeat_interval: config.heartbeat_interval,
          next_in: sequences.next_in,
          next_out: sequences.next_out
        }

        {:ok, :disconnected, %Data{config: config, protocol: protocol},
         [{:next_event, :internal, :connect}]}

      {:error, reason} ->
        {:stop, {:store_load_failed, reason}}
    end
  end

  @impl true
  def handle_event(:enter, _old_state, :disconnected, data) do
    case data |> close() |> reload_sequences() do
      {:ok, data} ->
        reconnect =
          if data.auto_reconnect,
            do: [{{:timeout, :reconnect}, data.config.reconnect_interval, :retry}],
            else: []

        {:keep_state, %{data | protocol: %{data.protocol | status: :disconnected}},
         [
           {{:timeout, :outbound_idle}, :cancel},
           {{:timeout, :inbound_idle}, :cancel}
           | reconnect
         ]}

      {:error, reason} ->
        # In-memory sequences may run ahead of the durable ones; carrying on
        # with them risks reusing or skipping sequence numbers on the next
        # connection. A restart reloads from the store once it is reachable.
        {:stop, {:store_load_failed, reason}}
    end
  end

  def handle_event(:enter, _old_state, :connecting, data) do
    {:keep_state, data, [{{:timeout, :reconnect}, :cancel}]}
  end

  def handle_event(:enter, _old_state, :awaiting_logon, data) do
    {:keep_state, data, [{:state_timeout, data.config.logon_timeout, :logon}]}
  end

  def handle_event(:enter, _old_state, :awaiting_logout, data) do
    {:keep_state, data, [{:state_timeout, data.config.logout_timeout, :logout}]}
  end

  def handle_event(:enter, _old_state, :logged_on, data) do
    Logger.info("FIX session active with #{data.config.target_comp_id}")
    {:keep_state, data, heartbeat_timers(data)}
  end

  def handle_event(:enter, _old_state, _state, data), do: {:keep_state, data}

  def handle_event(:state_timeout, :logon, :awaiting_logon, data),
    do: disconnect(data, :logon_timeout)

  def handle_event(:state_timeout, :logout, :awaiting_logout, data),
    do: disconnect(data, :logout_timeout)

  def handle_event({:timeout, :reconnect}, :retry, :disconnected, data),
    do: {:next_state, :connecting, data, [{:next_event, :internal, :connect}]}

  def handle_event(:internal, :connect, :disconnected, data),
    do: {:next_state, :connecting, data, [{:next_event, :internal, :connect}]}

  def handle_event(:internal, :connect, :connecting, data) do
    config = data.config

    case config.transport.connect(
           config.host,
           config.port,
           config.transport_options,
           config.connect_timeout
         ) do
      {:ok, socket} ->
        protocol = %{data.protocol | status: :awaiting_logon}
        data = %{data | socket: socket, buffer: <<>>, protocol: protocol}

        case emit_new(data, logon_message(config)) do
          {:ok, data} ->
            case config.transport.set_active_once(socket) do
              :ok -> {:next_state, :awaiting_logon, data}
              {:error, reason} -> disconnect(data, {:transport_activation_failed, reason})
            end

          {:error, reason, data} ->
            disconnect(data, {:logon_send_failed, reason})
        end

      {:error, reason} ->
        Logger.warning("FIX connect failed: #{inspect(reason)}")
        {:next_state, :disconnected, data}
    end
  end

  def handle_event({:timeout, :outbound_idle}, :send, :logged_on, data) do
    case emit_new(data, Messages.heartbeat()) do
      {:ok, data} -> {:keep_state, data, outbound_timer(data)}
      {:error, reason, data} -> disconnect(data, {:heartbeat_send_failed, reason})
    end
  end

  def handle_event(
        {:timeout, :inbound_idle},
        :probe,
        :logged_on,
        %Data{protocol: %State{pending_test_request: nil}} = data
      ) do
    id = "TR-#{System.unique_integer([:positive])}"
    data = %{data | protocol: %{data.protocol | pending_test_request: id}}

    case emit_new(data, Messages.test_request(id)) do
      {:ok, data} -> {:keep_state, data, inbound_timer(data)}
      {:error, reason, data} -> disconnect(data, {:test_request_send_failed, reason})
    end
  end

  def handle_event({:timeout, :inbound_idle}, :probe, :logged_on, data),
    do: disconnect(data, :test_request_timeout)

  def handle_event(:info, {:tcp, socket, bytes}, state, %Data{socket: socket} = data),
    do: handle_bytes(bytes, state, data)

  def handle_event(:info, {:ssl, socket, bytes}, state, %Data{socket: socket} = data),
    do: handle_bytes(bytes, state, data)

  def handle_event(:info, {:tcp_closed, socket}, _state, %Data{socket: socket} = data),
    do: disconnect(data, :peer_closed)

  def handle_event(:info, {:ssl_closed, socket}, _state, %Data{socket: socket} = data),
    do: disconnect(data, :peer_closed)

  def handle_event(:info, {:tcp_error, socket, reason}, _state, %Data{socket: socket} = data),
    do: disconnect(data, {:transport_error, reason})

  def handle_event(:info, {:ssl_error, socket, reason}, _state, %Data{socket: socket} = data),
    do: disconnect(data, {:transport_error, reason})

  def handle_event({:call, from}, {:send, message}, :logged_on, data) do
    case emit_new(data, message) do
      {:ok, data} ->
        {:keep_state, data, [{:reply, from, :ok} | outbound_timer(data)]}

      {:error, reason, data} ->
        {:next_state, :disconnected, close(data), [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, {:send, _message}, state, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, {:not_logged_on, state}}}]}

  def handle_event({:call, from}, {:logout, text}, :logged_on, data) do
    case emit_new(data, Messages.logout(text)) do
      {:ok, data} ->
        # An operator-requested logout is terminal: once the session
        # disconnects it must stay down instead of logging straight back on.
        protocol = %{data.protocol | status: :awaiting_logout}
        data = %{data | protocol: protocol, auto_reconnect: false}
        {:next_state, :awaiting_logout, data, [{:reply, from, :ok}]}

      {:error, reason, data} ->
        {:next_state, :disconnected, close(data), [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, {:logout, _text}, state, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, {:not_logged_on, state}}}]}

  def handle_event(kind, event, state, _data) do
    Logger.debug("FIX unhandled #{inspect(kind)} #{inspect(event)} in #{state}")
    :keep_state_and_data
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp handle_bytes(bytes, state, data) do
    case Framing.drain(data.buffer <> bytes, data.config.dictionary) do
      {:ok, messages, rest} ->
        data = %{data | buffer: rest}

        case process_messages(messages, data) do
          {:ok, data} ->
            case data.config.transport.set_active_once(data.socket) do
              :ok ->
                next_state = data.protocol.status
                actions = if messages == [], do: [], else: inbound_timer(data)

                if next_state == state do
                  {:keep_state, data, actions}
                else
                  {:next_state, next_state, data, actions}
                end

              {:error, reason} ->
                disconnect(data, {:transport_activation_failed, reason})
            end

          {:disconnect, reason, data} ->
            disconnect(data, reason)
        end

      {:error, reason} ->
        disconnect(data, {:parse_error, reason})
    end
  end

  defp process_messages(messages, data) do
    Enum.reduce_while(messages, {:ok, data}, fn message, {:ok, data} ->
      {protocol, actions} = Protocol.handle_message(message, data.protocol)

      case execute_actions(actions, %{data | protocol: protocol}) do
        {:ok, data} -> {:cont, {:ok, data}}
        {:disconnect, reason, data} -> {:halt, {:disconnect, reason, data}}
      end
    end)
  end

  defp execute_actions(actions, data) do
    Enum.reduce_while(actions, {:ok, data}, fn
      {:persist_inbound, next_in}, {:ok, data} ->
        config = data.config

        case config.store.save_inbound(config.store_ref, config.session_id, next_in) do
          :ok -> {:cont, {:ok, data}}
          {:error, reason} -> {:halt, {:disconnect, {:store_write_failed, reason}, data}}
        end

      {:send_new, message}, {:ok, data} ->
        case emit_new(data, message) do
          {:ok, data} -> {:cont, {:ok, data}}
          {:error, reason, data} -> {:halt, {:disconnect, {:send_failed, reason}, data}}
        end

      {:send_replay, message}, {:ok, data} ->
        case emit_replay(data, message) do
          {:ok, data} -> {:cont, {:ok, data}}
          {:error, reason, data} -> {:halt, {:disconnect, {:send_failed, reason}, data}}
        end

      {:deliver, message}, {:ok, data} ->
        deliver(message, data.config)
        {:cont, {:ok, data}}

      {:disconnect, reason}, {:ok, data} ->
        {:halt, {:disconnect, reason, data}}
    end)
  end

  defp emit_new(%Data{socket: nil} = data, _message), do: {:error, :not_connected, data}

  defp emit_new(data, %FIX.Message{} = message) do
    config = data.config
    seq_num = data.protocol.next_out

    message = %{
      message
      | begin_string: config.begin_string,
        seq_num: seq_num,
        sender_comp_id: config.sender_comp_id,
        target_comp_id: config.target_comp_id,
        sending_time: utc_timestamp()
    }

    wire = FIX.Message.to_fix(message)

    with :ok <-
           config.store.commit_outbound(
             config.store_ref,
             config.session_id,
             seq_num,
             wire,
             seq_num + 1
           ) do
      data = %{data | protocol: %{data.protocol | next_out: seq_num + 1}}

      case config.transport.send(data.socket, wire) do
        :ok -> {:ok, data}
        {:error, reason} -> {:error, reason, data}
      end
    else
      {:error, reason} -> {:error, {:store_write_failed, reason}, data}
    end
  end

  # Retransmissions carry their own MsgSeqNum and consume no new outbound
  # sequence number, so nothing is committed to the store.
  defp emit_replay(%Data{socket: nil} = data, _message), do: {:error, :not_connected, data}

  defp emit_replay(data, %FIX.Message{} = message) do
    config = data.config
    now = utc_timestamp()

    message = %{
      message
      | begin_string: config.begin_string,
        sender_comp_id: config.sender_comp_id,
        target_comp_id: config.target_comp_id,
        sending_time: now,
        orig_sending_time: message.orig_sending_time || now
    }

    case config.transport.send(data.socket, FIX.Message.to_fix(message)) do
      :ok -> {:ok, data}
      {:error, reason} -> {:error, reason, data}
    end
  end

  defp logon_message(config) do
    body =
      [{98, "0"}, {108, Integer.to_string(config.heartbeat_interval)}] ++
        if(config.default_appl_ver_id, do: [{1137, config.default_appl_ver_id}], else: [])

    %FIX.Message{msg_type: "A", body: body}
  end

  defp deliver(_message, %Config{app: nil}), do: :ok
  defp deliver(message, %Config{app: app} = config), do: app.handle_message(message, config)

  defp heartbeat_timers(data), do: outbound_timer(data) ++ inbound_timer(data)

  defp outbound_timer(%Data{config: %{heartbeat_interval: 0}}), do: []

  defp outbound_timer(%Data{config: %{heartbeat_interval: interval}}),
    do: [{{:timeout, :outbound_idle}, interval * 1_000, :send}]

  defp inbound_timer(%Data{config: %{heartbeat_interval: 0}}), do: []

  defp inbound_timer(%Data{config: %{heartbeat_interval: interval}}),
    do: [{{:timeout, :inbound_idle}, trunc(interval * 1_200), :probe}]

  defp disconnect(data, reason) do
    Logger.warning("FIX disconnecting: #{inspect(reason)}")
    {:next_state, :disconnected, close(data)}
  end

  defp reload_sequences(data) do
    config = data.config

    case config.store.load(config.store_ref, config.session_id) do
      {:ok, sequences} ->
        protocol = %{
          data.protocol
          | next_in: sequences.next_in,
            next_out: sequences.next_out,
            pending_inbound: %{},
            outstanding_resend: nil
        }

        {:ok, %{data | protocol: protocol}}

      {:error, reason} ->
        Logger.error("FIX failed to reload sequence state: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp close(%Data{socket: nil} = data), do: %{data | buffer: <<>>}

  defp close(data) do
    _ = data.config.transport.close(data.socket)
    protocol = %{data.protocol | pending_inbound: %{}, pending_test_request: nil}
    %{data | socket: nil, buffer: <<>>, protocol: protocol}
  end

  defp utc_timestamp do
    DateTime.utc_now()
    |> Calendar.strftime("%Y%m%d-%H:%M:%S.%f")
    |> String.slice(0..20)
  end
end
