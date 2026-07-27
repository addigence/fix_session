defmodule FIX.Session.Framing do
  @moduledoc "Purely drains complete FIX messages from a transport buffer."

  @spec drain(binary(), module()) ::
          {:ok, [FIX.Message.t()], binary()} | {:error, term()}
  def drain(buffer, dictionary \\ FIX.Dictionary.FIX44), do: drain(buffer, dictionary, [])

  defp drain(buffer, dictionary, messages) do
    case FIX.Message.parse(buffer, dictionary) do
      {:ok, message, rest} -> drain(rest, dictionary, [message | messages])
      :incomplete -> {:ok, Enum.reverse(messages), buffer}
      {:error, reason} -> {:error, reason}
    end
  end
end
