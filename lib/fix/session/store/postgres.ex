if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule FIX.Session.Store.Postgres do
    @moduledoc """
    Durable session store backed by PostgreSQL through the host
    application's `Ecto.Repo`.

    Requires the optional `:ecto_sql` and `:postgrex` dependencies:

        {:ecto_sql, "~> 3.10"},
        {:postgrex, "~> 0.19"}

    Create the tables from a migration in the host application (see
    `FIX.Session.Store.Postgres.Migrations`):

        def up, do: FIX.Session.Store.Postgres.Migrations.up()
        def down, do: FIX.Session.Store.Postgres.Migrations.down()

    The store owns no processes: the `store_ref` is the repo module, and
    the repo must be supervised before any session that uses it:

        children = [
          MyApp.Repo,
          {FIX.Session,
           FIX.Session.Config.new!(
             store: FIX.Session.Store.Postgres,
             store_ref: MyApp.Repo,
             ...
           )}
        ]

    ## Durability

    `commit_outbound/5` writes the outbound wire bytes and the advanced
    `next_out` in a single database transaction, so the two can never be
    observed apart, even across a crash at any point. Durability is
    PostgreSQL's: state survives session, store, VM, and machine crashes
    subject to the server's own durability configuration.

    Session ids become part of durable rows via
    `:erlang.term_to_binary(session_id, [:deterministic])`, so a session
    id must have a stable external term format (atoms, binaries, numbers,
    and tuples/lists/maps thereof).

    ## Concurrency

    The upserts assume one session process is the sole writer for its
    `session_id` — which `FIX.Session` guarantees — and therefore take no
    row locks. Running two live sessions against the same `session_id`
    is a configuration error with any store.

    ## Error semantics

    `load/2`, `save_inbound/3`, and `commit_outbound/5` report an
    unreachable repo or database as `{:error, :store_unavailable}`.
    Misconfiguration is not unavailability: missing tables (the migration
    never ran) and invalid data raise. `get_outbound/3` never rescues:
    its `:error` return must mean "never stored" and nothing else,
    because the resend path answers it with a SequenceReset-GapFill.
    This store never deletes rows, so a missing row strictly means the
    sequence number was never committed.
    """

    @behaviour FIX.Session.Store

    import Ecto.Query

    @sessions "fix_session_sessions"
    @outbound "fix_session_outbound"

    @type store_ref :: module()

    @impl FIX.Session.Store
    def load(repo, session_id) do
      key = key(session_id)

      row =
        repo.one(
          from(s in @sessions,
            where: s.session_id == type(^key, :binary),
            select: %{next_in: s.next_in, next_out: s.next_out}
          )
        )

      {:ok, row || %{next_in: 1, next_out: 1}}
    rescue
      e -> unavailable(e, __STACKTRACE__)
    catch
      # A stopped repo exits :noproc from the connection pool.
      :exit, _reason -> {:error, :store_unavailable}
    end

    @impl FIX.Session.Store
    def save_inbound(repo, session_id, next_in) do
      upsert_sequence(repo, key(session_id), :next_in, next_in)
    rescue
      e -> unavailable(e, __STACKTRACE__)
    catch
      :exit, _reason -> {:error, :store_unavailable}
    end

    @impl FIX.Session.Store
    def commit_outbound(repo, session_id, seq_num, wire, next_out) do
      key = key(session_id)

      # One database transaction: the wire bytes and the advanced next_out
      # land atomically, before the socket write.
      case repo.transaction(fn ->
             :ok = upsert_wire(repo, key, seq_num, wire)
             :ok = upsert_sequence(repo, key, :next_out, next_out)
           end) do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    rescue
      e -> unavailable(e, __STACKTRACE__)
    catch
      :exit, _reason -> {:error, :store_unavailable}
    end

    @impl FIX.Session.Store
    def get_outbound(repo, session_id, seq_num) do
      # No rescue: an unreachable database must raise, not report a gap.
      key = key(session_id)

      wire =
        repo.one(
          from(o in @outbound,
            where: o.session_id == type(^key, :binary) and o.seq_num == ^seq_num,
            select: o.wire
          )
        )

      case wire do
        nil -> :error
        wire when is_binary(wire) -> {:ok, wire}
      end
    end

    # The insert defaults only apply the first time a session id is seen;
    # on conflict only the named field is replaced. No locks: one session
    # process is the sole writer for its session id.
    defp upsert_sequence(repo, key, field, value) do
      row = %{session_id: key, next_in: 1, next_out: 1} |> Map.put(field, value)

      {_count, nil} =
        repo.insert_all(@sessions, [row],
          on_conflict: {:replace, [field]},
          conflict_target: [:session_id]
        )

      :ok
    end

    defp upsert_wire(repo, key, seq_num, wire) do
      row = %{session_id: key, seq_num: seq_num, wire: wire}

      {_count, nil} =
        repo.insert_all(@outbound, [row],
          on_conflict: {:replace, [:wire]},
          conflict_target: [:session_id, :seq_num]
        )

      :ok
    end

    # The deterministic external term format is injective, so distinct
    # session ids can never share a row.
    defp key(session_id), do: :erlang.term_to_binary(session_id, [:deterministic])

    # Unreachable infrastructure maps to :store_unavailable; everything
    # else (missing tables, invalid data, bad queries) reraises.
    defp unavailable(%DBConnection.ConnectionError{}, _stacktrace),
      do: {:error, :store_unavailable}

    # A stopped repo's registry entry and query-cache table vanish
    # asynchronously, so a dead repo surfaces as either an ArgumentError
    # from an ETS lookup or a :noproc exit from the pool, depending on
    # timing. The :exit half is caught at the callback level.
    defp unavailable(%ArgumentError{}, _stacktrace),
      do: {:error, :store_unavailable}

    defp unavailable(%RuntimeError{message: message} = e, stacktrace) do
      if message =~ "could not lookup Ecto repo" do
        {:error, :store_unavailable}
      else
        reraise(e, stacktrace)
      end
    end

    defp unavailable(e, stacktrace), do: reraise(e, stacktrace)
  end
else
  defmodule FIX.Session.Store.Postgres do
    @moduledoc """
    Durable session store backed by PostgreSQL.

    The optional `:ecto_sql` dependency is missing, so this build only
    contains a stub whose callbacks raise. Add it (and the Postgres
    driver) to compile the real store:

        {:ecto_sql, "~> 3.10"},
        {:postgrex, "~> 0.19"}
    """

    @behaviour FIX.Session.Store

    @impl FIX.Session.Store
    def load(_store_ref, _session_id), do: missing_dependency!()

    @impl FIX.Session.Store
    def save_inbound(_store_ref, _session_id, _next_in), do: missing_dependency!()

    @impl FIX.Session.Store
    def commit_outbound(_store_ref, _session_id, _seq_num, _wire, _next_out),
      do: missing_dependency!()

    @impl FIX.Session.Store
    def get_outbound(_store_ref, _session_id, _seq_num), do: missing_dependency!()

    defp missing_dependency! do
      raise RuntimeError, """
      #{inspect(__MODULE__)} requires the optional :ecto_sql dependency.

      Add it (and the Postgres driver) to your deps to use this store:

          {:ecto_sql, "~> 3.10"},
          {:postgrex, "~> 0.19"}
      """
    end
  end
end
