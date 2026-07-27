defmodule FIX.Session.Store do
  @moduledoc "Durable sequence-number and outbound-message storage contract."

  @type sequences :: %{next_in: pos_integer(), next_out: pos_integer()}

  @callback load(store_ref :: term(), session_id :: term()) ::
              {:ok, sequences()} | {:error, term()}

  @callback save_inbound(
              store_ref :: term(),
              session_id :: term(),
              next_in :: pos_integer()
            ) :: :ok | {:error, term()}

  @callback commit_outbound(
              store_ref :: term(),
              session_id :: term(),
              seq_num :: pos_integer(),
              wire :: binary(),
              next_out :: pos_integer()
            ) :: :ok | {:error, term()}

  @doc """
  Fetches the wire bytes stored for `seq_num`.

  `:error` must mean the message was never stored, and nothing else: the resend
  path answers it with a SequenceReset-GapFill, telling the counterparty that
  sequence number carried no business message. An implementation that cannot
  reach its storage must therefore raise rather than report a gap.
  """
  @callback get_outbound(store_ref :: term(), session_id :: term(), seq_num :: pos_integer()) ::
              {:ok, binary()} | :error
end
