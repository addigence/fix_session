defmodule FIX.Session.Store.EKVTest do
  use ExUnit.Case, async: true

  # EKV logs instance start-up/shutdown at :info.
  @moduletag :capture_log

  use FIX.Session.StoreContract, store: FIX.Session.Store.EKV

  alias FIX.Session.Store

  # A unique instance name and data_dir per test keeps stores isolated,
  # so the shared contract suite can run async.
  def start_store do
    {name, data_dir} = fresh_instance()
    start_supervised!({Store.EKV, name: name, data_dir: data_dir})
    name
  end

  defp fresh_instance do
    id = System.unique_integer([:positive])
    data_dir = Path.join(System.tmp_dir!(), "fix_session_ekv_test_#{id}")
    on_exit(fn -> File.rm_rf(data_dir) end)
    {:"fix_session_ekv_test_#{id}", data_dir}
  end

  describe "durability" do
    test "state survives a store restart on the same data_dir" do
      {name, data_dir} = fresh_instance()
      start_supervised!({Store.EKV, name: name, data_dir: data_dir})

      assert :ok = Store.EKV.save_inbound(name, :ibkr, 7)
      assert :ok = Store.EKV.commit_outbound(name, :ibkr, 3, "wire-3", 4)

      :ok = stop_supervised!({EKV, name})
      start_supervised!({Store.EKV, name: name, data_dir: data_dir})

      assert {:ok, %{next_in: 7, next_out: 4}} = Store.EKV.load(name, :ibkr)
      assert {:ok, "wire-3"} = Store.EKV.get_outbound(name, :ibkr, 3)
    end

    test "recommitting a sequence number overwrites the orphan wire" do
      # The crash-window replay path: a commit that stored its wire but not
      # the advanced next_out is reissued the same seq_num after reload.
      store = start_store()

      assert :ok = Store.EKV.commit_outbound(store, :ibkr, 5, "old", 6)
      assert :ok = Store.EKV.commit_outbound(store, :ibkr, 5, "new", 6)

      assert {:ok, "new"} = Store.EKV.get_outbound(store, :ibkr, 5)
    end
  end

  describe "error semantics" do
    test "writes and load report a never-started instance as unavailable" do
      name = :fix_session_ekv_test_never_started

      assert {:error, :store_unavailable} = Store.EKV.load(name, :ibkr)
      assert {:error, :store_unavailable} = Store.EKV.save_inbound(name, :ibkr, 2)
      assert {:error, :store_unavailable} = Store.EKV.commit_outbound(name, :ibkr, 1, "wire", 2)
    end

    test "writes and load report a stopped instance as unavailable" do
      store = start_store()
      :ok = stop_supervised!({EKV, store})

      assert {:error, :store_unavailable} = Store.EKV.load(store, :ibkr)
      assert {:error, :store_unavailable} = Store.EKV.save_inbound(store, :ibkr, 2)
      assert {:error, :store_unavailable} = Store.EKV.commit_outbound(store, :ibkr, 1, "wire", 2)
    end

    test "get_outbound raises on a stopped instance rather than reporting a gap" do
      store = start_store()
      assert :ok = Store.EKV.commit_outbound(store, :ibkr, 1, "wire-1", 2)

      :ok = stop_supervised!({EKV, store})

      assert_raise ArgumentError, fn -> Store.EKV.get_outbound(store, :ibkr, 1) end
    end
  end

  describe "key encoding" do
    test "structurally similar session ids do not collide" do
      store = start_store()

      assert :ok = Store.EKV.save_inbound(store, :a, 3)
      assert :ok = Store.EKV.commit_outbound(store, :a, 1, "atom", 2)
      assert :ok = Store.EKV.save_inbound(store, "a", 5)
      assert :ok = Store.EKV.commit_outbound(store, "a", 1, "string", 2)
      assert :ok = Store.EKV.save_inbound(store, {:acct, 1}, 7)

      assert {:ok, %{next_in: 3, next_out: 2}} = Store.EKV.load(store, :a)
      assert {:ok, %{next_in: 5, next_out: 2}} = Store.EKV.load(store, "a")
      assert {:ok, %{next_in: 7, next_out: 1}} = Store.EKV.load(store, {:acct, 1})

      assert {:ok, "atom"} = Store.EKV.get_outbound(store, :a, 1)
      assert {:ok, "string"} = Store.EKV.get_outbound(store, "a", 1)
      assert :error = Store.EKV.get_outbound(store, {:acct, 1}, 1)
    end

    test "small and very large sequence numbers round-trip independently" do
      store = start_store()
      big = 1_000_000_000_000

      assert :ok = Store.EKV.commit_outbound(store, :ibkr, 1, "wire-small", 2)
      assert :ok = Store.EKV.commit_outbound(store, :ibkr, big, "wire-big", big + 1)

      assert {:ok, "wire-small"} = Store.EKV.get_outbound(store, :ibkr, 1)
      assert {:ok, "wire-big"} = Store.EKV.get_outbound(store, :ibkr, big)
    end
  end
end
