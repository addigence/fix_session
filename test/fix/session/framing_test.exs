defmodule FIX.Session.FramingTest do
  use ExUnit.Case, async: true

  alias FIX.Session.Framing

  @dictionary FIX.Dictionary.FIX44

  defp wire(seq_num) do
    FIX.Message.to_fix(%FIX.Message{
      begin_string: "FIX.4.4",
      msg_type: "0",
      seq_num: seq_num,
      sender_comp_id: "IBKR",
      target_comp_id: "ADDIGENCE",
      sending_time: "20260727-10:00:00.000"
    })
  end

  test "drains nothing from an empty buffer" do
    assert {:ok, [], <<>>} = Framing.drain(<<>>, @dictionary)
  end

  test "retains a fragmented message until the rest arrives" do
    wire = wire(1)
    {head, tail} = String.split_at(wire, 20)

    assert {:ok, [], ^head} = Framing.drain(head, @dictionary)
    assert {:ok, [message], <<>>} = Framing.drain(head <> tail, @dictionary)
    assert message.seq_num == 1
  end

  test "drains multiple messages from one packet" do
    assert {:ok, [first, second], <<>>} = Framing.drain(wire(1) <> wire(2), @dictionary)
    assert first.seq_num == 1
    assert second.seq_num == 2
  end

  test "keeps the unconsumed tail after draining complete messages" do
    {head, _tail} = String.split_at(wire(2), 20)

    assert {:ok, [message], ^head} = Framing.drain(wire(1) <> head, @dictionary)
    assert message.seq_num == 1
  end

  test "reports garbled bytes instead of draining past them" do
    assert {:error, :garbled} = Framing.drain("garbage", @dictionary)
  end

  test "reports a checksum mismatch" do
    corrupted = String.replace(wire(1), "IBKR", "IBKX")

    assert {:error, :checksum_mismatch} = Framing.drain(corrupted, @dictionary)
  end
end
