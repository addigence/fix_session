defmodule FIX.Session.Messages do
  @moduledoc "Constructors for FIX session-layer messages."

  @spec logon(pos_integer()) :: FIX.Message.t()
  def logon(heartbeat_interval) when is_integer(heartbeat_interval) and heartbeat_interval > 0 do
    %FIX.Message{
      msg_type: "A",
      body: [{98, "0"}, {108, Integer.to_string(heartbeat_interval)}]
    }
  end

  @spec heartbeat(binary() | nil) :: FIX.Message.t()
  def heartbeat(test_request_id \\ nil)

  def heartbeat(nil), do: %FIX.Message{msg_type: "0"}
  def heartbeat(test_request_id), do: %FIX.Message{msg_type: "0", body: [{112, test_request_id}]}

  @spec test_request(binary()) :: FIX.Message.t()
  def test_request(test_request_id) when is_binary(test_request_id) do
    %FIX.Message{msg_type: "1", body: [{112, test_request_id}]}
  end

  @spec resend_request(pos_integer(), pos_integer()) :: FIX.Message.t()
  def resend_request(begin_seq_no, end_seq_no)
      when is_integer(begin_seq_no) and begin_seq_no > 0 and is_integer(end_seq_no) and
             end_seq_no >= begin_seq_no do
    %FIX.Message{
      msg_type: "2",
      body: [{7, Integer.to_string(begin_seq_no)}, {16, Integer.to_string(end_seq_no)}]
    }
  end

  @spec logout(binary() | nil) :: FIX.Message.t()
  def logout(text \\ nil)
  def logout(nil), do: %FIX.Message{msg_type: "5"}
  def logout(text) when is_binary(text), do: %FIX.Message{msg_type: "5", body: [{58, text}]}
end
