defmodule FIX.Session.Protocol do
  @moduledoc """
  Pure state transitions for the FIX session protocol.

  The caller must execute persistence actions before later send or delivery
  actions and must not install the returned state if persistence fails.
  """

  alias FIX.Session.Messages
  alias FIX.Session.State

  @type action ::
          {:persist_inbound, pos_integer()}
          | {:send_new, FIX.Message.t()}
          | {:send_replay, FIX.Message.t()}
          | {:deliver, FIX.Message.t()}
          | {:disconnect, term()}

  @spec handle_message(FIX.Message.t(), State.t()) :: {State.t(), [action()]}
  def handle_message(%FIX.Message{msg_type: msg_type}, %State{status: :awaiting_logon} = state)
      when msg_type != "A" do
    {state, [{:disconnect, :first_message_not_logon}]}
  end

  def handle_message(%FIX.Message{seq_num: seq_num} = message, %State{} = state)
      when is_integer(seq_num) and seq_num > 0 do
    # Any well-formed inbound message proves the peer is alive, whatever its
    # sequence number; an outstanding TestRequest is thereby answered.
    state = %{state | pending_test_request: nil}

    if message.msg_type == "4" and field(message.body, 123) != "Y" do
      handle_sequence_reset(message, state)
    else
      handle_sequenced(message, state)
    end
  end

  def handle_message(_message, %State{} = state) do
    {state, [{:disconnect, :invalid_sequence_number}]}
  end

  defp handle_sequenced(%FIX.Message{seq_num: seq_num} = message, state) do
    cond do
      seq_num > state.next_in -> handle_gap(message, state)
      seq_num < state.next_in -> handle_low_sequence(message, state)
      true -> process_in_order(message, state)
    end
  end

  # SequenceReset-Reset applies regardless of its own MsgSeqNum: the
  # counterparty is unilaterally moving the inbound sequence to NewSeqNo(36),
  # so it must not run through gap detection or be buffered.
  defp handle_sequence_reset(message, state) do
    with :ok <- validate_for_state(message, state),
         new_seq when is_integer(new_seq) <- int_field(message.body, 36) do
      if new_seq >= state.next_in do
        state = %{state | next_in: new_seq, pending_inbound: %{}, outstanding_resend: nil}
        {state, [{:persist_inbound, new_seq}]}
      else
        {state, [{:disconnect, :sequence_reset_below_expected}]}
      end
    else
      {:error, reason} -> {state, [{:disconnect, reason}]}
      nil -> {state, [{:disconnect, :invalid_sequence_reset}]}
    end
  end

  defp handle_gap(message, state) do
    state = accept_gapped_logon(message, state)
    pending = Map.put(state.pending_inbound, message.seq_num, message)
    state = %{state | pending_inbound: pending}
    requested = {state.next_in, message.seq_num - 1}

    if covers?(state.outstanding_resend, requested) do
      {state, []}
    else
      state = %{state | outstanding_resend: requested}
      {state, [{:send_new, Messages.resend_request(elem(requested, 0), elem(requested, 1))}]}
    end
  end

  # A Logon ack whose sequence number is ahead still establishes the session;
  # the gap is recovered afterwards, as FIX requires. Without this, the
  # replayed pre-logon messages would be rejected as :first_message_not_logon
  # and the session could never log on after a one-sided sequence reset.
  defp accept_gapped_logon(%FIX.Message{msg_type: "A"}, %State{status: :awaiting_logon} = state),
    do: %{state | status: :logged_on}

  defp accept_gapped_logon(_message, state), do: state

  defp handle_low_sequence(%FIX.Message{poss_dup_flag: true} = message, state) do
    if valid_duplicate_time?(message) do
      {state, []}
    else
      {state, [{:disconnect, :invalid_duplicate}]}
    end
  end

  defp handle_low_sequence(_message, state) do
    {state, [{:send_new, Messages.logout("MsgSeqNum too low")}, {:disconnect, :sequence_too_low}]}
  end

  defp process_in_order(message, state) do
    case validate_for_state(message, state) do
      :ok ->
        {state, message_actions} = dispatch(message, state)
        state = %{state | next_in: state.next_in + 1}
        actions = [{:persist_inbound, state.next_in} | message_actions]
        drain_pending(state, actions)

      {:error, reason} ->
        {state, [{:disconnect, reason}]}
    end
  end

  defp drain_pending(state, actions) do
    case Map.pop(state.pending_inbound, state.next_in) do
      {nil, _pending} ->
        outstanding =
          case state.outstanding_resend do
            {_from, to} when state.next_in > to -> nil
            range -> range
          end

        {%{state | outstanding_resend: outstanding}, actions}

      {message, pending} ->
        state = %{state | pending_inbound: pending}
        {state, next_actions} = process_in_order(message, state)
        {state, actions ++ next_actions}
    end
  end

  defp validate_for_state(%FIX.Message{msg_type: msg_type}, %State{status: :awaiting_logon})
       when msg_type != "A",
       do: {:error, :first_message_not_logon}

  defp validate_for_state(message, state) do
    cond do
      state.begin_string && message.begin_string && message.begin_string != state.begin_string ->
        {:error, :begin_string_mismatch}

      state.target_comp_id && message.sender_comp_id != state.target_comp_id ->
        {:error, :sender_comp_id_mismatch}

      state.sender_comp_id && message.target_comp_id != state.sender_comp_id ->
        {:error, :target_comp_id_mismatch}

      true ->
        :ok
    end
  end

  defp dispatch(%FIX.Message{msg_type: "A"}, %State{status: :awaiting_logon} = state),
    do: {%{state | status: :logged_on}, []}

  # A gapped Logon already logged the session on; consume it silently when
  # it drains from the pending buffer instead of delivering it as data.
  defp dispatch(%FIX.Message{msg_type: "A"}, %State{status: :logged_on} = state),
    do: {state, []}

  defp dispatch(%FIX.Message{msg_type: "0"}, state),
    do: {state, []}

  defp dispatch(%FIX.Message{msg_type: "1", body: body}, state),
    do: {state, [{:send_new, Messages.heartbeat(field(body, 112))}]}

  # Inbound ResendRequest: this session does not retransmit; the whole
  # requested range is answered with one SequenceReset-GapFill pointing at
  # the next outbound sequence number. EndSeqNo(16) of 0 means "and beyond".
  defp dispatch(%FIX.Message{msg_type: "2", body: body}, state) do
    from = int_field(body, 7)
    to = int_field(body, 16)

    if is_integer(from) and from >= 1 and from < state.next_out and
         is_integer(to) and (to == 0 or to >= from) do
      {state, [{:send_replay, Messages.sequence_reset_gap_fill(from, state.next_out)}]}
    else
      {state, [{:disconnect, :invalid_resend_request}]}
    end
  end

  # SequenceReset-GapFill consumed in order: NewSeqNo(36) becomes the next
  # expected inbound sequence. next_in is set one below the target because
  # process_in_order advances it by one after dispatch.
  defp dispatch(%FIX.Message{msg_type: "4", body: body}, state) do
    new_seq = int_field(body, 36)

    if is_integer(new_seq) and new_seq > state.next_in do
      pending = Map.reject(state.pending_inbound, fn {seq, _message} -> seq < new_seq end)
      {%{state | next_in: new_seq - 1, pending_inbound: pending}, []}
    else
      {state, [{:disconnect, :invalid_sequence_reset}]}
    end
  end

  defp dispatch(%FIX.Message{msg_type: "5"}, %State{status: :awaiting_logout} = state),
    do: {%{state | status: :disconnected}, [{:disconnect, :logout_complete}]}

  defp dispatch(%FIX.Message{msg_type: "5"}, state),
    do:
      {%{state | status: :awaiting_logout},
       [{:send_new, Messages.logout()}, {:disconnect, :peer_logout}]}

  defp dispatch(message, state), do: {state, [{:deliver, message}]}

  defp covers?(nil, _requested), do: false

  defp covers?({from, to}, {requested_from, requested_to}),
    do: from <= requested_from and to >= requested_to

  defp valid_duplicate_time?(%FIX.Message{orig_sending_time: nil}), do: false
  defp valid_duplicate_time?(%FIX.Message{sending_time: nil}), do: false

  defp valid_duplicate_time?(%FIX.Message{orig_sending_time: original, sending_time: sending}),
    do: original <= sending

  defp field(fields, tag) do
    case List.keyfind(fields, tag, 0) do
      {^tag, value} -> value
      nil -> nil
    end
  end

  defp int_field(fields, tag) do
    with value when is_binary(value) <- field(fields, tag),
         {int, ""} <- Integer.parse(value) do
      int
    else
      _other -> nil
    end
  end
end
