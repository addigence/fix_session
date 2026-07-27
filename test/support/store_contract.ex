defmodule FIX.Session.StoreContract do
  @moduledoc """
  Shared conformance suite for `FIX.Session.Store` implementations.

  Use inside an ExUnit case module, naming the implementation under test:

      defmodule MyStoreTest do
        use ExUnit.Case, async: true
        use FIX.Session.StoreContract, store: MyStore
      end

  Every test receives a `store_ref` from `start_store/0` in its context as
  `:store`. The default `start_store/0` starts the store module under the
  test supervisor and uses the returned pid; override it when the
  `store_ref` is something else (for example, `FIX.Session.Store.ETS`
  hands sessions its table). `start_store/0` must return an isolated store
  so the suite can run `async: true`.

  "Restoration" here means values written are visible to a later `load/2`,
  not survival across a process restart — restart behavior is
  implementation-specific and tested per implementation.
  """

  defmacro __using__(options) do
    store = Keyword.fetch!(options, :store)

    quote location: :keep do
      @store unquote(store)

      def start_store, do: start_supervised!(@store)
      defoverridable start_store: 0

      setup do
        %{store: start_store()}
      end

      describe "store contract" do
        test "a new session loads next_in=1 and next_out=1", %{store: store} do
          assert {:ok, %{next_in: 1, next_out: 1}} = @store.load(store, :new_session)
        end

        test "restores persisted sequence numbers", %{store: store} do
          assert :ok = @store.save_inbound(store, :ibkr, 7)
          assert :ok = @store.commit_outbound(store, :ibkr, 3, "wire-3", 4)

          assert {:ok, %{next_in: 7, next_out: 4}} = @store.load(store, :ibkr)
        end

        test "save_inbound leaves next_out alone and vice versa", %{store: store} do
          assert :ok = @store.commit_outbound(store, :ibkr, 1, "wire-1", 2)
          assert :ok = @store.save_inbound(store, :ibkr, 5)

          assert {:ok, %{next_in: 5, next_out: 2}} = @store.load(store, :ibkr)
        end

        test "commit_outbound stores the wire bytes and advances next_out together",
             %{store: store} do
          assert :ok = @store.commit_outbound(store, :ibkr, 1, "wire-1", 2)

          assert {:ok, %{next_out: 2}} = @store.load(store, :ibkr)
          assert {:ok, "wire-1"} = @store.get_outbound(store, :ibkr, 1)
        end

        test "retrieves each committed sequence number independently", %{store: store} do
          assert :ok = @store.commit_outbound(store, :ibkr, 1, "wire-1", 2)
          assert :ok = @store.commit_outbound(store, :ibkr, 2, "wire-2", 3)

          assert {:ok, "wire-1"} = @store.get_outbound(store, :ibkr, 1)
          assert {:ok, "wire-2"} = @store.get_outbound(store, :ibkr, 2)
          assert {:ok, %{next_out: 3}} = @store.load(store, :ibkr)
        end

        test "get_outbound returns :error only for a never-stored sequence", %{store: store} do
          assert :error = @store.get_outbound(store, :ibkr, 1)

          assert :ok = @store.commit_outbound(store, :ibkr, 1, "wire-1", 2)
          assert :error = @store.get_outbound(store, :ibkr, 2)
        end

        test "sessions do not share sequence state", %{store: store} do
          assert :ok = @store.save_inbound(store, :ibkr, 9)
          assert :ok = @store.commit_outbound(store, :ibkr, 4, "wire-4", 5)

          assert {:ok, %{next_in: 1, next_out: 1}} = @store.load(store, :other)
          assert :error = @store.get_outbound(store, :other, 4)
        end
      end
    end
  end
end
