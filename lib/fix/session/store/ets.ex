defmodule FIX.Session.Store.ETS do
  @moduledoc """
  ETS-backed store.

  The table is owned by this process rather than by a session, so sequence
  state survives session crashes and transport reconnects. It is not durable
  across a VM restart on its own: pass `:file` to restore at start-up and dump
  on graceful shutdown, or call `dump/2` to checkpoint explicitly. A hard crash
  loses everything written since the last dump.

  A snapshot is only trustworthy after a graceful shutdown. After a hard crash
  the last snapshot is still on disk but is stale, and restoring it resumes at
  sequence numbers that were already sent — which the counterparty rejects as
  too low. Use a genuinely durable store where that matters.

  Sessions read and write the table directly, so this process is not in the
  path of any message. `store_ref` is therefore the table, not the pid. Start
  the store before any session that uses it: the table dies with this process,
  so a restart would hand sessions an empty table and reset them to sequence 1.

      children = [
        {FIX.Session.Store.ETS, file: "/var/lib/fix/ibkr.ets"},
        {FIX.Session, config}
      ]

      Supervisor.start_link(children, strategy: :rest_for_one)

  `load/2`, `save_inbound/3` and `commit_outbound/5` report a missing table as
  `{:error, :store_unavailable}`, so a wrong `store_ref` stops the session with a
  legible reason instead of a bare `badarg`. `get_outbound/3` raises instead: its
  `:error` means the message was never stored, which the resend path answers with
  a gap fill, so it must not also be able to mean "the store is gone".

  Outbound records are kept for the life of the table and are never pruned.
  """

  # A longer shutdown than the 5s default so a large dump is not truncated.
  use GenServer, shutdown: 10_000

  @behaviour FIX.Session.Store

  require Logger

  @default_name __MODULE__

  @type option :: {:name, atom() | nil} | {:file, Path.t() | nil}

  @doc """
  Starts the table owner.

  ## Options

    * `:name` - registered process name, also the table name. Defaults to
      `#{inspect(@default_name)}`. Pass `nil` for an anonymous process owning an
      unnamed table, reachable with `table/1`.
    * `:file` - restore from this path at start-up when it exists, and dump back
      to it on graceful shutdown.

  Restoring fails the start rather than falling back to an empty table: quietly
  resetting a live session to sequence 1 would provoke a sequence-mismatch
  logout from the counterparty. A missing file means a first run and starts
  empty.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(options \\ []) do
    {name, options} = Keyword.pop(options, :name, @default_name)
    GenServer.start_link(__MODULE__, {name, options}, if(name, do: [name: name], else: []))
  end

  @doc "Returns the table owned by `server`, for use as a `store_ref`."
  @spec table(GenServer.server()) :: :ets.table()
  def table(server \\ @default_name), do: GenServer.call(server, :table)

  @doc "Writes the table to `path`, or to the configured `:file` when omitted."
  @spec dump(GenServer.server(), Path.t() | nil) :: :ok | {:error, term()}
  def dump(server \\ @default_name, path \\ nil), do: GenServer.call(server, {:dump, path})

  @impl FIX.Session.Store
  def load(table, session_id) do
    {:ok,
     %{
       next_in: lookup_seq(table, {session_id, :next_in}),
       next_out: lookup_seq(table, {session_id, :next_out})
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
    # A single insert of both objects is atomic and isolated, so a reader never
    # sees the bytes without the matching next_out, or the reverse.
    true =
      :ets.insert(table, [
        {{session_id, :next_out}, next_out},
        {{session_id, :out, seq_num}, wire}
      ])

    :ok
  rescue
    ArgumentError -> {:error, :store_unavailable}
  end

  # Deliberately no ArgumentError rescue, unlike the callbacks above. `:error`
  # here means "never stored", which the resend path answers with a
  # SequenceReset-GapFill. Rescuing a missing table into `:error` would make the
  # session tell the counterparty a message never existed when in fact the store
  # had vanished, so a dead table must raise rather than be reported as a gap.
  @impl FIX.Session.Store
  def get_outbound(table, session_id, seq_num) do
    case :ets.lookup(table, {session_id, :out, seq_num}) do
      [{_key, wire}] -> {:ok, wire}
      [] -> :error
    end
  end

  @impl GenServer
  def init({name, options}) do
    Process.flag(:trap_exit, true)
    file = Keyword.get(options, :file)

    case open(name || @default_name, name, file) do
      {:ok, table} -> {:ok, %{table: table, file: file}}
      {:error, reason} -> {:stop, {:restore_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:table, _from, state), do: {:reply, state.table, state}

  def handle_call({:dump, path}, _from, state), do: {:reply, write(state, path), state}

  @impl GenServer
  def terminate(_reason, %{file: nil}), do: :ok

  def terminate(_reason, state) do
    case write(state, nil) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("FIX store failed to dump to #{state.file}: #{inspect(reason)}")
        :ok
    end
  end

  defp open(label, name, file) do
    if file && File.exists?(file) do
      restore(label, file)
    else
      {:ok, :ets.new(label, table_options(name))}
    end
  end

  defp table_options(nil), do: [:set, :public, write_concurrency: :auto]
  defp table_options(_name), do: [:set, :public, :named_table, write_concurrency: :auto]

  # file2tab creates the table itself, restoring the name and options it was
  # dumped with, so a name change between dump and restore would leave the
  # configured store_ref pointing at nothing.
  defp restore(label, file) do
    with {:ok, table} <- :ets.file2tab(String.to_charlist(file), verify: true) do
      case :ets.info(table, :name) do
        ^label ->
          {:ok, table}

        other ->
          :ets.delete(table)
          {:error, {:name_mismatch, expected: label, found: other}}
      end
    end
  end

  defp write(%{file: nil}, nil), do: {:error, :no_dump_path}

  defp write(state, path) do
    path = path || state.file
    temp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         # object_count records what was actually written. Without it, verify
         # compares against the size sampled when the dump started, which can
         # differ on a public table sessions are still writing to and would fail
         # verification on restore. md5sum is what makes that check meaningful.
         :ok <-
           :ets.tab2file(state.table, String.to_charlist(temp),
             extended_info: [:object_count, :md5sum]
           ),
         # tab2file is not an atomic replace, so it writes beside the real path
         # and renames. A crash mid-dump would otherwise leave a truncated file
         # that the next boot has to reject.
         :ok <- File.rename(temp, path) do
      :ok
    end
  end

  defp lookup_seq(table, key) do
    case :ets.lookup(table, key) do
      [{^key, seq_num}] -> seq_num
      [] -> 1
    end
  end
end
