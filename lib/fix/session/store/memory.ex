defmodule FIX.Session.Store.Memory do
  @moduledoc "In-memory store for tests and development. It is not crash durable."
  use Agent

  @behaviour FIX.Session.Store

  def start_link(options \\ []) do
    {initial, options} = Keyword.pop(options, :initial, %{})
    Agent.start_link(fn -> initial end, options)
  end

  @impl true
  def load(store, session_id) do
    Agent.get(store, fn sessions ->
      case Map.get(sessions, session_id) do
        nil -> {:ok, %{next_in: 1, next_out: 1}}
        session -> {:ok, Map.take(session, [:next_in, :next_out])}
      end
    end)
  end

  @impl true
  def save_inbound(store, session_id, next_in) do
    Agent.update(store, fn sessions ->
      update_session(sessions, session_id, &Map.put(&1, :next_in, next_in))
    end)
  end

  @impl true
  def commit_outbound(store, session_id, seq_num, wire, next_out) do
    Agent.update(store, fn sessions ->
      update_session(sessions, session_id, fn session ->
        session
        |> Map.put(:next_out, next_out)
        |> put_in([:outbound, seq_num], wire)
      end)
    end)
  end

  @impl true
  def get_outbound(store, session_id, seq_num) do
    Agent.get(store, fn sessions ->
      with %{outbound: outbound} <- Map.get(sessions, session_id),
           {:ok, wire} <- Map.fetch(outbound, seq_num) do
        {:ok, wire}
      else
        _ -> :error
      end
    end)
  end

  defp update_session(sessions, session_id, update) do
    session =
      Map.get(sessions, session_id, %{next_in: 1, next_out: 1, outbound: %{}})

    Map.put(sessions, session_id, update.(session))
  end
end
