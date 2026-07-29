defmodule FIX.Session.Store.PostgresTest do
  use ExUnit.Case, async: true

  @moduletag :postgres
  @moduletag :capture_log

  use FIX.Session.StoreContract, store: FIX.Session.Store.Postgres

  alias FIX.Session.PostgresNeverStartedRepo
  alias FIX.Session.PostgresTestRepo
  alias FIX.Session.Store

  # Each test checks out its own sandboxed connection; everything written
  # through the repo rolls back when the test exits, so the shared repo is
  # async-safe.
  def start_store do
    # The contract's setup already checked this process's connection out.
    case Ecto.Adapters.SQL.Sandbox.checkout(PostgresTestRepo) do
      :ok -> :ok
      {:already, :owner} -> :ok
    end

    PostgresTestRepo
  end

  # A private, non-sandboxed repo instance for tests that need committed
  # rows or a repo they can kill without disturbing the shared one.
  defp start_dynamic_repo do
    {:ok, pid} =
      PostgresTestRepo.start_link(
        name: nil,
        url: PostgresTestRepo.url(),
        pool_size: 1,
        log: false
      )

    PostgresTestRepo.put_dynamic_repo(pid)
    pid
  end

  defp stop_dynamic_repo(pid) do
    PostgresTestRepo.put_dynamic_repo(PostgresTestRepo)
    Supervisor.stop(pid)
  end

  describe "durability" do
    test "committed state survives a repo restart" do
      session_id = {:durability, System.unique_integer([:positive])}
      pid = start_dynamic_repo()

      on_exit(fn ->
        cleanup = start_dynamic_repo()
        key = :erlang.term_to_binary(session_id, [:deterministic])

        for table <- ["fix_session_outbound", "fix_session_sessions"] do
          PostgresTestRepo.query!("DELETE FROM #{table} WHERE session_id = $1", [key])
        end

        stop_dynamic_repo(cleanup)
      end)

      assert :ok = Store.Postgres.save_inbound(PostgresTestRepo, session_id, 7)
      assert :ok = Store.Postgres.commit_outbound(PostgresTestRepo, session_id, 3, "wire-3", 4)

      stop_dynamic_repo(pid)
      pid = start_dynamic_repo()

      assert {:ok, %{next_in: 7, next_out: 4}} = Store.Postgres.load(PostgresTestRepo, session_id)
      assert {:ok, "wire-3"} = Store.Postgres.get_outbound(PostgresTestRepo, session_id, 3)

      stop_dynamic_repo(pid)
    end

    test "recommitting a sequence number overwrites the orphan wire" do
      # The crash-window replay path: a commit whose transaction never
      # completed is reissued the same seq_num after reload.
      store = start_store()

      assert :ok = Store.Postgres.commit_outbound(store, :ibkr, 5, "old", 6)
      assert :ok = Store.Postgres.commit_outbound(store, :ibkr, 5, "new", 6)

      assert {:ok, "new"} = Store.Postgres.get_outbound(store, :ibkr, 5)
    end
  end

  describe "error semantics" do
    test "writes and load report a never-started repo as unavailable" do
      repo = PostgresNeverStartedRepo

      assert {:error, :store_unavailable} = Store.Postgres.load(repo, :ibkr)
      assert {:error, :store_unavailable} = Store.Postgres.save_inbound(repo, :ibkr, 2)
      assert {:error, :store_unavailable} = Store.Postgres.commit_outbound(repo, :ibkr, 1, "w", 2)
    end

    test "writes and load report a stopped repo as unavailable" do
      pid = start_dynamic_repo()
      Supervisor.stop(pid)

      assert {:error, :store_unavailable} = Store.Postgres.load(PostgresTestRepo, :ibkr)

      assert {:error, :store_unavailable} =
               Store.Postgres.save_inbound(PostgresTestRepo, :ibkr, 2)

      assert {:error, :store_unavailable} =
               Store.Postgres.commit_outbound(PostgresTestRepo, :ibkr, 1, "w", 2)

      PostgresTestRepo.put_dynamic_repo(PostgresTestRepo)
    end

    test "get_outbound raises rather than reporting a gap" do
      assert_raise RuntimeError, ~r/could not lookup Ecto repo/, fn ->
        Store.Postgres.get_outbound(PostgresNeverStartedRepo, :ibkr, 1)
      end

      pid = start_dynamic_repo()
      Supervisor.stop(pid)

      # A stopped repo crashes the caller with an ArgumentError (registry
      # or query-cache table gone) or a :noproc exit (pool dead) depending
      # on cleanup timing — never a gap-fillable :error return.
      crashed =
        try do
          Store.Postgres.get_outbound(PostgresTestRepo, :ibkr, 1)
          false
        rescue
          ArgumentError -> true
        catch
          :exit, _reason -> true
        after
          PostgresTestRepo.put_dynamic_repo(PostgresTestRepo)
        end

      assert crashed, "expected get_outbound on a stopped repo to crash"
    end

    test "an unreachable server reports unavailable" do
      config =
        PostgresTestRepo.url()
        |> Ecto.Repo.Supervisor.parse_url()
        |> Keyword.merge(
          name: nil,
          port: 1,
          pool_size: 1,
          queue_target: 50,
          queue_interval: 100,
          log: false
        )

      {:ok, pid} = PostgresTestRepo.start_link(config)
      PostgresTestRepo.put_dynamic_repo(pid)

      try do
        assert {:error, :store_unavailable} =
                 Store.Postgres.save_inbound(PostgresTestRepo, :ibkr, 2)
      after
        PostgresTestRepo.put_dynamic_repo(PostgresTestRepo)
        Supervisor.stop(pid)
      end
    end

    test "invalid data raises rather than reporting unavailability" do
      # Misconfiguration and bad data are not :store_unavailable; a seq_num
      # outside bigint range must surface as the encoding error it is.
      store = start_store()

      assert_raise DBConnection.EncodeError, fn ->
        Store.Postgres.commit_outbound(store, :ibkr, Integer.pow(2, 63), "wire", 2)
      end
    end
  end

  describe "key encoding" do
    test "structurally similar session ids do not collide" do
      store = start_store()

      assert :ok = Store.Postgres.save_inbound(store, :a, 3)
      assert :ok = Store.Postgres.commit_outbound(store, :a, 1, "atom", 2)
      assert :ok = Store.Postgres.save_inbound(store, "a", 5)
      assert :ok = Store.Postgres.commit_outbound(store, "a", 1, "string", 2)
      assert :ok = Store.Postgres.save_inbound(store, {:acct, 1}, 7)

      assert {:ok, %{next_in: 3, next_out: 2}} = Store.Postgres.load(store, :a)
      assert {:ok, %{next_in: 5, next_out: 2}} = Store.Postgres.load(store, "a")
      assert {:ok, %{next_in: 7, next_out: 1}} = Store.Postgres.load(store, {:acct, 1})

      assert {:ok, "atom"} = Store.Postgres.get_outbound(store, :a, 1)
      assert {:ok, "string"} = Store.Postgres.get_outbound(store, "a", 1)
      assert :error = Store.Postgres.get_outbound(store, {:acct, 1}, 1)
    end

    test "small and very large sequence numbers round-trip independently" do
      store = start_store()
      big = Integer.pow(2, 62)

      assert :ok = Store.Postgres.commit_outbound(store, :ibkr, 1, "wire-small", 2)
      assert :ok = Store.Postgres.commit_outbound(store, :ibkr, big, "wire-big", big + 1)

      assert {:ok, "wire-small"} = Store.Postgres.get_outbound(store, :ibkr, 1)
      assert {:ok, "wire-big"} = Store.Postgres.get_outbound(store, :ibkr, big)
    end
  end
end
