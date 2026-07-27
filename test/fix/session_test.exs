defmodule FIX.Session.TestTransport do
  import Kernel, except: [send: 2]

  @behaviour FIX.Session.Transport

  @impl true
  def connect(_host, _port, options, _timeout) do
    {:ok, {Keyword.fetch!(options, :owner), make_ref()}}
  end

  @impl true
  def send({owner, _ref}, bytes) do
    Kernel.send(owner, {:transport_sent, bytes})
    :ok
  end

  @impl true
  def set_active_once({owner, _ref}) do
    Kernel.send(owner, :transport_active_once)
    :ok
  end

  @impl true
  def close({owner, _ref}) do
    Kernel.send(owner, :transport_closed)
    :ok
  end
end

defmodule FIX.Session.ProtocolTest do
  use ExUnit.Case, async: true

  alias FIX.Session.{Messages, Protocol, State}

  test "accepts an in-sequence Logon" do
    state = %State{status: :awaiting_logon, next_in: 1, next_out: 2}
    logon = %FIX.Message{msg_type: "A", seq_num: 1}

    {state, actions} = Protocol.handle_message(logon, state)

    assert state.status == :logged_on
    assert state.next_in == 2
    assert actions == [{:persist_inbound, 2}]
  end

  test "rejects a non-Logon as the first inbound message" do
    state = %State{status: :awaiting_logon}

    {state, actions} = Protocol.handle_message(%FIX.Message{msg_type: "0", seq_num: 1}, state)

    assert state.next_in == 1
    assert actions == [{:disconnect, :first_message_not_logon}]
  end

  test "delivers an in-sequence application message and advances next_in" do
    state = %State{status: :logged_on, next_in: 5, next_out: 3}
    message = %FIX.Message{msg_type: "8", seq_num: 5}

    {state, actions} = Protocol.handle_message(message, state)

    assert state.next_in == 6
    assert actions == [{:persist_inbound, 6}, {:deliver, message}]
  end

  test "buffers a high-sequence message and requests the missing range once" do
    state = %State{status: :logged_on, next_in: 5}
    message = %FIX.Message{msg_type: "8", seq_num: 8}

    {state, actions} = Protocol.handle_message(message, state)
    {state, repeated_actions} = Protocol.handle_message(message, state)

    assert state.next_in == 5
    assert state.pending_inbound == %{8 => message}
    assert actions == [{:send_new, Messages.resend_request(5, 7)}]
    assert repeated_actions == []
  end

  test "releases buffered messages in sequence order when a gap closes" do
    five = %FIX.Message{msg_type: "8", seq_num: 5}
    six = %FIX.Message{msg_type: "8", seq_num: 6}

    state = %State{
      status: :logged_on,
      next_in: 5,
      pending_inbound: %{6 => six},
      outstanding_resend: {5, 5}
    }

    {state, actions} = Protocol.handle_message(five, state)

    assert state.next_in == 7
    assert state.pending_inbound == %{}
    assert state.outstanding_resend == nil

    assert actions == [
             {:persist_inbound, 6},
             {:deliver, five},
             {:persist_inbound, 7},
             {:deliver, six}
           ]
  end

  test "responds to TestRequest with a Heartbeat echoing TestReqID" do
    state = %State{status: :logged_on, next_in: 10, next_out: 4}
    request = %FIX.Message{msg_type: "1", seq_num: 10, body: [{112, "probe-1"}]}

    {state, actions} = Protocol.handle_message(request, state)

    assert state.next_in == 11

    assert actions == [
             {:persist_inbound, 11},
             {:send_new, Messages.heartbeat("probe-1")}
           ]
  end

  test "silently ignores a valid lower-sequence duplicate" do
    state = %State{status: :logged_on, next_in: 10}

    duplicate = %FIX.Message{
      msg_type: "8",
      seq_num: 9,
      poss_dup_flag: true,
      orig_sending_time: "20260727-10:00:00.000",
      sending_time: "20260727-10:00:01.000"
    }

    assert {^state, []} = Protocol.handle_message(duplicate, state)
  end

  test "logs out on a lower sequence without PossDupFlag" do
    state = %State{status: :logged_on, next_in: 10}

    {_state, actions} = Protocol.handle_message(%FIX.Message{msg_type: "8", seq_num: 9}, state)

    assert actions == [
             {:send_new, Messages.logout("MsgSeqNum too low")},
             {:disconnect, :sequence_too_low}
           ]
  end
end

defmodule FIX.Session.StateMachineTest do
  use ExUnit.Case

  alias FIX.Session.{Config, Store.ETS}

  # store defaults to Store.ETS, so only store_ref is passed here.
  defp config(store) do
    Config.new!(
      session_id: :ibkr,
      host: "localhost",
      port: 5001,
      sender_comp_id: "ADDIGENCE",
      target_comp_id: "IBKR",
      heartbeat_interval: 0,
      transport: FIX.Session.TestTransport,
      transport_options: [owner: self()],
      store_ref: store
    )
  end

  defp logon_ack do
    FIX.Message.to_fix(%FIX.Message{
      begin_string: "FIX.4.4",
      msg_type: "A",
      seq_num: 1,
      sender_comp_id: "IBKR",
      target_comp_id: "ADDIGENCE",
      sending_time: "20260727-10:00:00.000",
      body: [{98, "0"}, {108, "0"}]
    })
  end

  setup do
    %{store: ETS.table(start_supervised!({ETS, name: nil}))}
  end

  test "connects, logs on, and allocates the next outbound sequence", %{store: store} do
    session = start_supervised!({FIX.Session, config(store)})

    assert_receive {:transport_sent, logon_wire}
    assert {:ok, logon, <<>>} = FIX.Message.parse(logon_wire)
    assert logon.msg_type == "A"
    assert logon.seq_num == 1
    assert_receive :transport_active_once

    {_, data} = :sys.get_state(session)
    send(session, {:tcp, data.socket, logon_ack()})

    assert_receive :transport_active_once
    assert :ok = FIX.Session.send_message(session, %FIX.Message{msg_type: "D"})
    assert_receive {:transport_sent, application_wire}
    assert {:ok, application, <<>>} = FIX.Message.parse(application_wire)
    assert application.msg_type == "D"
    assert application.seq_num == 2
    assert {:ok, %{next_in: 2, next_out: 3}} = ETS.load(store, :ibkr)
    assert {:ok, ^application_wire} = ETS.get_outbound(store, :ibkr, 2)
  end

  # Not async, so claiming the default global table name here is safe. Every
  # other store test uses name: nil precisely to stay out of its way.
  test "runs against the default named table with no store options" do
    # A distinct child id: this module's setup already holds ETS for its
    # unnamed store, and this test needs the default named one alongside it.
    start_supervised!(Supervisor.child_spec(ETS, id: :default_named_store))

    config =
      Config.new!(
        session_id: :ibkr,
        host: "localhost",
        port: 5001,
        sender_comp_id: "ADDIGENCE",
        target_comp_id: "IBKR",
        heartbeat_interval: 0,
        transport: FIX.Session.TestTransport,
        transport_options: [owner: self()]
      )

    assert config.store == ETS
    assert config.store_ref == ETS

    session = start_supervised!({FIX.Session, config})

    assert_receive {:transport_sent, _logon_wire}
    assert_receive :transport_active_once

    {_, data} = :sys.get_state(session)
    send(session, {:tcp, data.socket, logon_ack()})

    assert_receive :transport_active_once
    assert :ok = FIX.Session.send_message(session, %FIX.Message{msg_type: "D"})
    assert_receive {:transport_sent, _application_wire}

    assert {:ok, %{next_in: 2, next_out: 3}} = ETS.load(ETS, :ibkr)
  end

  test "a new session resumes the sequence numbers a killed session left behind", %{store: store} do
    config = config(store)

    Process.flag(:trap_exit, true)
    {:ok, session} = FIX.Session.start_link(config)

    assert_receive {:transport_sent, _logon_wire}
    assert_receive :transport_active_once

    {_, data} = :sys.get_state(session)
    send(session, {:tcp, data.socket, logon_ack()})

    assert_receive :transport_active_once
    assert :ok = FIX.Session.send_message(session, %FIX.Message{msg_type: "D"})
    assert_receive {:transport_sent, _application_wire}
    assert {:ok, %{next_in: 2, next_out: 3}} = ETS.load(store, :ibkr)

    # The table outlives the session, so a replacement must not restart at 1.
    Process.exit(session, :kill)
    assert_receive {:EXIT, ^session, :killed}

    {:ok, _resumed} = FIX.Session.start_link(config)

    assert_receive {:transport_sent, resumed_logon_wire}
    assert {:ok, resumed_logon, <<>>} = FIX.Message.parse(resumed_logon_wire)
    assert resumed_logon.msg_type == "A"
    assert resumed_logon.seq_num == 3
  end
end

defmodule FIX.Session.Store.MemoryTest do
  use ExUnit.Case, async: true
  use FIX.Session.StoreContract, store: FIX.Session.Store.Memory
end

defmodule FIX.Session.Store.ETSTest do
  use ExUnit.Case, async: true
  use FIX.Session.StoreContract, store: FIX.Session.Store.ETS

  alias FIX.Session.Store.ETS

  # An unnamed table keeps this suite async-safe: a named table is a global name.
  def start_store, do: ETS.table(start_supervised!({ETS, name: nil}))

  test "reports an unavailable store rather than raising on a missing table" do
    assert {:error, :store_unavailable} = ETS.load(:no_such_table, :ibkr)
    assert {:error, :store_unavailable} = ETS.save_inbound(:no_such_table, :ibkr, 2)
    assert {:error, :store_unavailable} = ETS.commit_outbound(:no_such_table, :ibkr, 1, "w", 2)
  end

  test "raises on a missing table rather than reporting a gap", %{store: store} do
    # :error must mean "never stored" and nothing else, because the resend path
    # answers it with a SequenceReset-GapFill. A vanished store reported as a gap
    # would tell the counterparty a message it was sent never existed.
    assert :error = ETS.get_outbound(store, :ibkr, 1)
    assert_raise ArgumentError, fn -> ETS.get_outbound(:no_such_table, :ibkr, 1) end
  end
end

defmodule FIX.Session.Store.ETSDumpTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FIX.Session.Store.ETS

  @tag :tmp_dir
  test "dumps on graceful shutdown and restores on restart", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "store.ets")

    store = ETS.table(start_supervised!({ETS, name: nil, file: path}))
    assert :ok = ETS.commit_outbound(store, :ibkr, 4, "wire", 5)
    assert :ok = ETS.save_inbound(store, :ibkr, 9)
    assert :ok = stop_supervised(ETS)

    assert File.exists?(path)

    restored = ETS.table(start_supervised!({ETS, name: nil, file: path}))

    assert {:ok, %{next_in: 9, next_out: 5}} = ETS.load(restored, :ibkr)
    assert {:ok, "wire"} = ETS.get_outbound(restored, :ibkr, 4)
  end

  @tag :tmp_dir
  test "checkpoints to an explicit path without shutting down", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "checkpoint.ets")

    owner = start_supervised!({ETS, name: nil})
    assert :ok = ETS.save_inbound(ETS.table(owner), :ibkr, 12)
    assert :ok = ETS.dump(owner, path)
    assert :ok = stop_supervised(ETS)

    restored = ETS.table(start_supervised!({ETS, name: nil, file: path}))

    assert {:ok, %{next_in: 12}} = ETS.load(restored, :ibkr)
  end

  @tag :tmp_dir
  test "starts empty when the dump file does not exist yet", %{tmp_dir: tmp_dir} do
    store = ETS.table(start_supervised!({ETS, name: nil, file: Path.join(tmp_dir, "absent.ets")}))

    assert {:ok, %{next_in: 1, next_out: 1}} = ETS.load(store, :ibkr)
  end

  @tag :tmp_dir
  test "refuses to start from a corrupt dump instead of resetting to 1", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "corrupt.ets")
    File.write!(path, "not an ets dump")

    capture_log(fn ->
      assert {:error, {{:restore_failed, _reason}, _spec}} =
               start_supervised({ETS, name: nil, file: path})
    end)
  end

  @tag :tmp_dir
  test "refuses to start from a truncated dump", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "truncated.ets")

    owner = start_supervised!({ETS, name: nil})
    store = ETS.table(owner)
    for seq <- 1..50, do: :ok = ETS.commit_outbound(store, :ibkr, seq, "wire-#{seq}", seq + 1)
    assert :ok = ETS.dump(owner, path)
    assert :ok = stop_supervised(ETS)

    dumped = File.read!(path)
    File.write!(path, binary_part(dumped, 0, byte_size(dumped) - 32))

    capture_log(fn ->
      assert {:error, {{:restore_failed, _reason}, _spec}} =
               start_supervised({ETS, name: nil, file: path})
    end)
  end
end
