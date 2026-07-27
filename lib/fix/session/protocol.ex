defmodule FIX.Session.Protocol do
  @moduledoc """
  Pure state transitions for the FIX session protocol.

  The caller must execute persistence actions before later send or delivery
  actions and must not install the returned state if persistence fails.
  """

  alias FIX.Session.{Messages, State}

  @type action ::
          {:persist_inbound, pos_integer()}
          | {:send_new, FIX.Message.t()}
          | {:deliver, FIX.Message.t()}
          | {:disconnect, term()}

  @spec handle_message(FIX.Message.t(), State.t()) :: {State.t(), [action()]}
  def handle_message(%FIX.Message{seq_num: seq_num} = message, %State{} = state)
      when is_integer(seq_num) and seq_num > 0 do
    cond do
      seq_num > state.next_in -> handle_gap(message, state)
      seq_num < state.next_in -> handle_low_sequence(message, state)
      true -> process_in_order(message, state)
    end
  end

  def handle_message(_message, %State{} = state) do
    {state, [{:disconnect, :invalid_sequence_number}]}
  end

  defp handle_gap(message, state) do
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

  defp dispatch(%FIX.Message{msg_type: "0"}, state),
    do: {%{state | pending_test_request: nil}, []}

  defp dispatch(%FIX.Message{msg_type: "1", body: body}, state),
    do: {state, [{:send_new, Messages.heartbeat(field(body, 112))}]}

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
end
