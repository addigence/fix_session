defmodule FIX.Session.Messages do
  @moduledoc """
  Constructors for session-level messages.

  Constructors set only the message type and body. The session-controlled
  header fields — BeginString(8), MsgSeqNum(34), SenderCompID(49),
  TargetCompID(56), SendingTime(52) — are stamped by the session when the
  message is committed and sent.
  """

  @doc """
  Heartbeat(0). When answering a TestRequest, `test_req_id` echoes the
  request's TestReqID(112).
  """
  @spec heartbeat(binary() | nil) :: FIX.Message.t()
  def heartbeat(test_req_id \\ nil)
  def heartbeat(nil), do: %FIX.Message{msg_type: "0"}

  def heartbeat(test_req_id) when is_binary(test_req_id),
    do: %FIX.Message{msg_type: "0", body: [{112, test_req_id}]}

  @doc "TestRequest(1) carrying `test_req_id` as TestReqID(112)."
  @spec test_request(binary()) :: FIX.Message.t()
  def test_request(test_req_id) when is_binary(test_req_id),
    do: %FIX.Message{msg_type: "1", body: [{112, test_req_id}]}

  @doc "ResendRequest(2) for the inclusive range BeginSeqNo(7)..EndSeqNo(16)."
  @spec resend_request(pos_integer(), pos_integer()) :: FIX.Message.t()
  def resend_request(from, to)
      when is_integer(from) and from >= 1 and is_integer(to) and to >= from do
    %FIX.Message{
      msg_type: "2",
      body: [{7, Integer.to_string(from)}, {16, Integer.to_string(to)}]
    }
  end

  @doc """
  SequenceReset-GapFill(4) occupying `seq_num` and pointing the counterparty
  at `new_seq_no` as the next expected sequence number.

  Sent in answer to a ResendRequest, so unlike the other constructors it is
  a retransmission: it carries its own MsgSeqNum(34) and PossDupFlag(43),
  and must not be allocated a fresh outbound sequence number.
  """
  @spec sequence_reset_gap_fill(pos_integer(), pos_integer()) :: FIX.Message.t()
  def sequence_reset_gap_fill(seq_num, new_seq_no)
      when is_integer(seq_num) and seq_num >= 1 and is_integer(new_seq_no) and
             new_seq_no > seq_num do
    %FIX.Message{
      msg_type: "4",
      seq_num: seq_num,
      poss_dup_flag: true,
      body: [{123, "Y"}, {36, Integer.to_string(new_seq_no)}]
    }
  end

  @doc "Logout(5) with an optional explanatory Text(58)."
  @spec logout(binary() | nil) :: FIX.Message.t()
  def logout(text \\ nil)
  def logout(nil), do: %FIX.Message{msg_type: "5"}
  def logout(text) when is_binary(text), do: %FIX.Message{msg_type: "5", body: [{58, text}]}
end
