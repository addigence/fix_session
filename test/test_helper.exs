# The Postgres store suite (tagged :postgres) runs against a real server,
# configured by FIX_SESSION_PG_URL (default
# postgres://postgres:postgres@localhost:5432/fix_session_test). When no
# server is reachable the tag is excluded so the rest of the suite still
# runs.
postgres_bootstrap = fn ->
  url = FIX.Session.PostgresTestRepo.url()

  case FIX.Session.PostgresTestRepo.__adapter__().storage_up(Ecto.Repo.Supervisor.parse_url(url)) do
    up when up in [:ok, {:error, :already_up}] ->
      {:ok, _pid} =
        FIX.Session.PostgresTestRepo.start_link(
          url: url,
          pool: Ecto.Adapters.SQL.Sandbox,
          log: false
        )

      Ecto.Migrator.up(
        FIX.Session.PostgresTestRepo,
        20_260_728_120_000,
        FIX.Session.PostgresTestMigration,
        log: false
      )

      Ecto.Adapters.SQL.Sandbox.mode(FIX.Session.PostgresTestRepo, :manual)
      :ok

    error ->
      {:error, error}
  end
end

bootstrap_result =
  try do
    postgres_bootstrap.()
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

postgres_exclusions =
  case bootstrap_result do
    :ok ->
      []

    {:error, error} ->
      IO.warn(
        "Postgres unavailable (#{inspect(error)}) — skipping FIX.Session.Store.Postgres " <>
          "tests. Set FIX_SESSION_PG_URL to point at a reachable server.",
        []
      )

      [:postgres]
  end

ExUnit.start(exclude: postgres_exclusions)
