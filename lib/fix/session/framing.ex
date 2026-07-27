defmodule FIX.Session.Framing do
  @moduledoc """
  Drains complete FIX messages from an accumulated byte buffer.

  Pure: repeatedly applies `FIX.Message.parse/2` to the front of the buffer
  until it hits an incomplete tail, which the caller keeps and prepends to
  the next socket read. Framing, BodyLength(9), and CheckSum(10) errors are
  returned as-is; the caller decides how to fail the session.
  """

  @spec drain(binary(), module()) ::
          {:ok, [FIX.Message.t()], rest :: binary()} | {:error, FIX.Parser.frame_error()}
  def drain(buffer, dictionary), do: drain(buffer, dictionary, [])

  defp drain(buffer, dictionary, acc) do
    case FIX.Message.parse(buffer, dictionary) do
      {:ok, message, rest} -> drain(rest, dictionary, [message | acc])
      :incomplete -> {:ok, Enum.reverse(acc), buffer}
      {:error, reason} -> {:error, reason}
    end
  end
end
