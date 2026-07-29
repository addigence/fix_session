defmodule FIX.Session.PostgresTestRepo do
  @moduledoc "Repo used by the Postgres store tests."

  use Ecto.Repo, otp_app: :fix_session, adapter: Ecto.Adapters.Postgres

  @doc "Connection options, overridable with `FIX_SESSION_PG_URL`."
  def url do
    System.get_env(
      "FIX_SESSION_PG_URL",
      "postgres://postgres:postgres@localhost:5432/fix_session_test"
    )
  end
end

defmodule FIX.Session.PostgresNeverStartedRepo do
  @moduledoc """
  Deliberately never started: exercises the store's mapping of Ecto's
  repo-not-started error to `{:error, :store_unavailable}`.
  """

  use Ecto.Repo, otp_app: :fix_session, adapter: Ecto.Adapters.Postgres
end

defmodule FIX.Session.PostgresTestMigration do
  @moduledoc "Runs the real store migrations in the test database."

  use Ecto.Migration

  def up, do: FIX.Session.Store.Postgres.Migrations.up()
  def down, do: FIX.Session.Store.Postgres.Migrations.down()
end
