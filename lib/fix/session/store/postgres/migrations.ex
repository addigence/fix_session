if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule FIX.Session.Store.Postgres.Migrations do
    @moduledoc """
    Creates the tables used by `FIX.Session.Store.Postgres`.

    Call `up/1` and `down/1` from a migration in the host application:

        defmodule MyApp.Repo.Migrations.AddFixSessionTables do
          use Ecto.Migration

          def up, do: FIX.Session.Store.Postgres.Migrations.up()
          def down, do: FIX.Session.Store.Postgres.Migrations.down()
        end
    """

    use Ecto.Migration

    @doc "Creates the `fix_session_sessions` and `fix_session_outbound` tables."
    @spec up(keyword()) :: :ok
    def up(_opts \\ []) do
      create table(:fix_session_sessions, primary_key: false) do
        add :session_id, :binary, primary_key: true, null: false
        add :next_in, :bigint, null: false
        add :next_out, :bigint, null: false
      end

      create table(:fix_session_outbound, primary_key: false) do
        add :session_id, :binary, primary_key: true, null: false
        add :seq_num, :bigint, primary_key: true, null: false
        add :wire, :binary, null: false
      end

      :ok
    end

    @doc "Drops the store tables."
    @spec down(keyword()) :: :ok
    def down(_opts \\ []) do
      drop table(:fix_session_outbound)
      drop table(:fix_session_sessions)
      :ok
    end
  end
else
  defmodule FIX.Session.Store.Postgres.Migrations do
    @moduledoc """
    Migrations for the Postgres session store.

    The optional `:ecto_sql` dependency is missing, so this build only
    contains a stub whose functions raise. Add it to compile the real
    module:

        {:ecto_sql, "~> 3.10"},
        {:postgrex, "~> 0.19"}
    """

    @spec up(keyword()) :: no_return()
    def up(_opts \\ []), do: missing_dependency!()

    @spec down(keyword()) :: no_return()
    def down(_opts \\ []), do: missing_dependency!()

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
