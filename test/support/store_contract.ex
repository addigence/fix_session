defmodule FIX.Session.StoreContract do
  @moduledoc """
  Conformance tests every `FIX.Session.Store` implementation must pass.

      defmodule MyStoreTest do
        use ExUnit.Case, async: true
        use FIX.Session.StoreContract, store: MyStore
      end

  `use ExUnit.Case` must come first. Implementations whose `store_ref` is not the
  pid returned by `start_link/1` override `start_store/0` to return the right
  reference.
  """

  defmacro __using__(options) do
    quote do
      @store unquote(Keyword.fetch!(options, :store))

      def start_store, do: start_supervised!(@store)

      defoverridable start_store: 0

      setup do
        %{store: start_store()}
      end

      test "an unknown session starts at sequence 1", %{store: store} do
        assert {:ok, %{next_in: 1, next_out: 1}} = @store.load(store, :unknown)
      end

      test "restores persisted sequence numbers", %{store: store} do
        assert :ok = @store.save_inbound(store, :session, 4)
        assert :ok = @store.commit_outbound(store, :session, 6, "wire", 7)

        assert {:ok, %{next_in: 4, next_out: 7}} = @store.load(store, :session)
      end

      test "commits outbound bytes and next_out together", %{store: store} do
        assert :ok = @store.commit_outbound(store, :session, 1, "wire", 2)

        assert {:ok, "wire"} = @store.get_outbound(store, :session, 1)
        assert {:ok, %{next_out: 2}} = @store.load(store, :session)
      end

      test "retrieves each outbound message by its sequence number", %{store: store} do
        assert :ok = @store.commit_outbound(store, :session, 1, "one", 2)
        assert :ok = @store.commit_outbound(store, :session, 2, "two", 3)
        assert :ok = @store.commit_outbound(store, :session, 3, "three", 4)

        assert {:ok, "one"} = @store.get_outbound(store, :session, 1)
        assert {:ok, "two"} = @store.get_outbound(store, :session, 2)
        assert {:ok, "three"} = @store.get_outbound(store, :session, 3)
      end

      test "returns :error for a sequence number it never stored", %{store: store} do
        assert :error = @store.get_outbound(store, :unknown, 1)

        assert :ok = @store.commit_outbound(store, :session, 1, "wire", 2)
        assert :error = @store.get_outbound(store, :session, 2)
      end

      test "keeps inbound and outbound progress independent", %{store: store} do
        assert :ok = @store.save_inbound(store, :session, 7)
        assert {:ok, %{next_in: 7, next_out: 1}} = @store.load(store, :session)

        assert :ok = @store.commit_outbound(store, :session, 1, "wire", 2)
        assert {:ok, %{next_in: 7, next_out: 2}} = @store.load(store, :session)

        assert :ok = @store.save_inbound(store, :session, 8)
        assert {:ok, %{next_in: 8, next_out: 2}} = @store.load(store, :session)
      end

      test "isolates sessions sharing one store", %{store: store} do
        assert :ok = @store.commit_outbound(store, :one, 1, "one-wire", 2)
        assert :ok = @store.save_inbound(store, :one, 5)

        assert {:ok, %{next_in: 1, next_out: 1}} = @store.load(store, :two)
        assert :error = @store.get_outbound(store, :two, 1)

        assert :ok = @store.commit_outbound(store, :two, 1, "two-wire", 2)

        assert {:ok, "one-wire"} = @store.get_outbound(store, :one, 1)
        assert {:ok, "two-wire"} = @store.get_outbound(store, :two, 1)
        assert {:ok, %{next_in: 5, next_out: 2}} = @store.load(store, :one)
      end

      test "takes the last write for a sequence number", %{store: store} do
        assert :ok = @store.save_inbound(store, :session, 9)
        assert :ok = @store.save_inbound(store, :session, 3)
        assert {:ok, %{next_in: 3}} = @store.load(store, :session)

        assert :ok = @store.commit_outbound(store, :session, 1, "first", 2)
        assert :ok = @store.commit_outbound(store, :session, 1, "second", 2)
        assert {:ok, "second"} = @store.get_outbound(store, :session, 1)
      end
    end
  end
end
