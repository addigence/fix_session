defmodule FIX.Session.State do
  @moduledoc """
  Runtime state for a single FIX session.

  `next_in` and `next_out` are the next expected inbound and next allocated
  outbound sequence numbers. They belong to the logical FIX session and must
  eventually be persisted across transport reconnects.
  """

  @type status ::
          :disconnected | :connecting | :awaiting_logon | :logged_on | :awaiting_logout

  @type t :: %__MODULE__{
          socket: term(),
          status: status(),
          begin_string: binary(),
          sender_comp_id: binary() | nil,
          target_comp_id: binary() | nil,
          next_in: pos_integer(),
          next_out: pos_integer(),
          heartbeat_interval: pos_integer(),
          last_received_at: term(),
          last_sent_at: term(),
          pending_test_request: binary() | nil,
          buffer: binary(),
          pending_inbound: %{optional(pos_integer()) => FIX.Message.t()},
          outstanding_resend: {pos_integer(), pos_integer()} | nil
        }

  defstruct [
    :socket,
    status: :disconnected,
    begin_string: "FIX.4.4",
    sender_comp_id: nil,
    target_comp_id: nil,
    next_in: 1,
    next_out: 1,
    heartbeat_interval: 30,
    last_received_at: nil,
    last_sent_at: nil,
    pending_test_request: nil,
    buffer: <<>>,
    pending_inbound: %{},
    outstanding_resend: nil
  ]
end
