defmodule FIX.Session.Store.ETS do
  @moduledoc """
  Default session store: an ETS table held by a supervised owner process.

  The table is owned by this process rather than by a session, so sequence
  state survives a session-process crash and reconnect, and a replacement
  session resumes where the dead one stopped instead of restarting at
  sequence 1. It is not crash durable: the table dies with its owner and
  with the VM.

  Store operations take the table itself as the `store_ref` and run in the
  calling session's process; the owner is only consulted for `table/1` and
  `dump/2`.

  ## Options

    * `:name` — the table name, `#{inspect(__MODULE__)}` by default, which
      also serves as the `store_ref`. Pass `nil` for an unnamed table
      (isolated, so safe for `async: true` tests) and use `table/1` as the
      `store_ref`.

    * `:file` — snapshot path. When set, a snapshot is restored at
      start-up if the file exists and dumped on graceful shutdown. This is
      best-effort only: after a hard crash the snapshot on disk is stale,
      and restoring it would resume at sequence numbers already sent. A
      file that exists but cannot be verified fails start-up rather than
      silently resetting sequences to 1.

  ## Error semantics

  `load/2`, `save_inbound/3`, and `commit_outbound/5` report a missing
  table as `{:error, :store_unavailable}`. `get_outbound/3` instead raises
  when the table is gone: its `:error` return must mean "never stored" and
  nothing else, because the resend path answers it with a
  SequenceReset-GapFill.
  """

  use GenServer

  @behaviour FIX.Session.Store

  @type store_ref :: :ets.table()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options)

  @doc "Returns the owner's table, for use as a session's `store_ref`."
  @spec table(GenServer.server()) :: store_ref()
  def table(owner), do: GenServer.call(owner, :table)

  @doc "Writes a snapshot of the current table contents to `path`."
  @spec dump(GenServer.server(), Path.t()) :: :ok | {:error, term()}
  def dump(owner, path), do: GenServer.call(owner, {:dump, path})

  # ----------------------------------------------------------------------------
  # Store contract
  # ----------------------------------------------------------------------------

  @impl FIX.Session.Store
  def load(table, session_id) do
    {:ok,
     %{
       next_in: sequence(table, {session_id, :next_in}),
       next_out: sequence(table, {session_id, :next_out})
     }}
  rescue
    ArgumentError -> {:error, :store_unavailable}
  end

  @impl FIX.Session.Store
  def save_inbound(table, session_id, next_in) do
    true = :ets.insert(table, {{session_id, :next_in}, next_in})
    :ok
  rescue
    ArgumentError -> {:error, :store_unavailable}
  end

  @impl FIX.Session.Store
  def commit_outbound(table, session_id, seq_num, wire, next_out) do
    # One insert call with both objects: ets guarantees other processes see
    # either none or all of them, so the wire bytes and the advanced
    # next_out land atomically.
    true =
      :ets.insert(table, [
        {{session_id, :outbound, seq_num}, wire},
        {{session_id, :next_out}, next_out}
      ])

    :ok
  rescue
    ArgumentError -> {:error, :store_unavailable}
  end

  @impl FIX.Session.Store
  def get_outbound(table, session_id, seq_num) do
    # No rescue: a vanished table must raise, not report a gap.
    case :ets.lookup(table, {session_id, :outbound, seq_num}) do
      [{_key, wire}] -> {:ok, wire}
      [] -> :error
    end
  end

  defp sequence(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> 1
    end
  end

  # ----------------------------------------------------------------------------
  # Owner process
  # ----------------------------------------------------------------------------

  @impl GenServer
  def init(options) do
    # Trapping exits makes terminate/2 run on supervisor shutdown, so the
    # graceful-shutdown snapshot gets written.
    Process.flag(:trap_exit, true)

    name = Keyword.get(options, :name, __MODULE__)
    file = Keyword.get(options, :file)

    table =
      case name do
        nil -> :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
        name -> :ets.new(name, [:set, :public, :named_table, read_concurrency: true])
      end

    case restore(table, file) do
      :ok -> {:ok, %{table: table, file: file}}
      {:error, reason} -> {:stop, {:restore_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:table, _from, state), do: {:reply, state.table, state}

  def handle_call({:dump, path}, _from, state),
    do: {:reply, write_dump(state.table, path), state}

  @impl GenServer
  def terminate(_reason, %{file: nil}), do: :ok
  def terminate(_reason, state), do: write_dump(state.table, state.file)

  defp restore(_table, nil), do: :ok

  defp restore(table, path) do
    if File.exists?(path) do
      case :ets.file2tab(String.to_charlist(path), verify: true) do
        {:ok, snapshot} ->
          true = :ets.insert(table, :ets.tab2list(snapshot))
          :ets.delete(snapshot)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp write_dump(table, path) do
    # Dump a private unnamed copy so the snapshot never carries the
    # :named_table option: file2tab of a named-table dump would collide
    # with the table the restoring owner has already created.
    copy = :ets.new(__MODULE__.Snapshot, [:set, :private])

    try do
      true = :ets.insert(copy, :ets.tab2list(table))

      :ets.tab2file(copy, String.to_charlist(path),
        extended_info: [:md5sum, :object_count],
        sync: true
      )
    after
      :ets.delete(copy)
    end
  end
end
