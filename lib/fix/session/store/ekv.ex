if Code.ensure_loaded?(EKV) do
  defmodule FIX.Session.Store.EKV do
    @moduledoc """
    Durable session store backed by [EKV](https://hex.pm/packages/ekv)
    (SQLite in WAL mode, via a vendored NIF).

    Requires the optional `:ekv` dependency:

        {:ekv, "~> 0.4"}

    Start the store in a supervision tree and point sessions at it:

        children = [
          {FIX.Session.Store.EKV, data_dir: "/var/lib/my_app/fix_session"},
          {FIX.Session, FIX.Session.Config.new!(store: FIX.Session.Store.EKV, ...)}
        ]

    Store operations take the EKV instance name as the `store_ref`.

    ## Options

      * `:name` — the EKV instance name, `#{inspect(__MODULE__)}` by
        default, which also serves as the `store_ref`. Pass a distinct
        atom per instance to run several stores side by side.

      * `:data_dir` — required. Directory holding the SQLite files;
        created if absent. Reusing a `data_dir` resumes its persisted
        state, which is what makes this store durable.

    All other options are passed through to `EKV.start_link/1`.

    ## Durability

    Writes are committed to SQLite before the store call returns, so state
    survives session, store, and VM crashes. SQLite runs in WAL mode with
    `synchronous=NORMAL`: the most recent commits can still be lost to an
    OS crash or power failure.

    `commit_outbound/5` writes the wire record and then the advanced
    `next_out` pointer as two single-key EKV writes (EKV has no multi-key
    transactions). A crash between the two leaves a wire record that was
    never sent — commits happen before the socket write — so on reload the
    stale pointer hands out that sequence number again and the next commit
    overwrites the orphan. No sequence number is reused on the wire or
    skipped.

    Session ids become part of durable keys via
    `:erlang.term_to_binary(session_id, [:deterministic])`, so a session
    id must have a stable external term format (atoms, binaries, numbers,
    and tuples/lists/maps thereof).

    ## Error semantics

    `load/2`, `save_inbound/3`, and `commit_outbound/5` report an
    unreachable EKV instance as `{:error, :store_unavailable}`.
    `get_outbound/3` instead raises when the instance is gone: its
    `:error` return must mean "never stored" and nothing else, because the
    resend path answers it with a SequenceReset-GapFill. This store never
    deletes entries or sets TTLs, so a `nil` read strictly means the
    sequence number was never committed.
    """

    @behaviour FIX.Session.Store

    @type store_ref :: atom()

    @spec child_spec(keyword()) :: Supervisor.child_spec()
    def child_spec(options), do: options |> with_name() |> EKV.child_spec()

    @spec start_link(keyword()) :: Supervisor.on_start()
    def start_link(options \\ []), do: options |> with_name() |> EKV.start_link()

    defp with_name(options), do: Keyword.put_new(options, :name, __MODULE__)

    # --------------------------------------------------------------------------
    # Store contract
    # --------------------------------------------------------------------------

    @impl FIX.Session.Store
    def load(name, session_id) do
      {:ok,
       %{
         next_in: sequence(name, session_key(session_id, "next_in")),
         next_out: sequence(name, session_key(session_id, "next_out"))
       }}
    rescue
      ArgumentError -> {:error, :store_unavailable}
    end

    @impl FIX.Session.Store
    def save_inbound(name, session_id, next_in) do
      EKV.put(name, session_key(session_id, "next_in"), next_in)
    rescue
      ArgumentError -> {:error, :store_unavailable}
    catch
      # A stopped instance exits :noproc from the shard call; a
      # never-started one raises ArgumentError instead.
      :exit, _reason -> {:error, :store_unavailable}
    end

    @impl FIX.Session.Store
    def commit_outbound(name, session_id, seq_num, wire, next_out) do
      # Two single-key writes: EKV has no multi-key transactions. Wire
      # first, pointer second — a crash between them leaves an orphan wire
      # that was never sent (commit precedes the socket write), so the
      # reloaded stale pointer safely reissues seq_num and the next commit
      # overwrites the orphan.
      with :ok <- EKV.put(name, outbound_key(session_id, seq_num), wire) do
        EKV.put(name, session_key(session_id, "next_out"), next_out)
      end
    rescue
      ArgumentError -> {:error, :store_unavailable}
    catch
      :exit, _reason -> {:error, :store_unavailable}
    end

    @impl FIX.Session.Store
    def get_outbound(name, session_id, seq_num) do
      # No rescue: an unreachable instance must raise, not report a gap.
      case EKV.get(name, outbound_key(session_id, seq_num)) do
        nil -> :error
        wire when is_binary(wire) -> {:ok, wire}
      end
    end

    defp sequence(name, key) do
      case EKV.get(name, key) do
        nil -> 1
        value when is_integer(value) -> value
      end
    end

    # --------------------------------------------------------------------------
    # Keys
    # --------------------------------------------------------------------------

    # base64url over the deterministic external term format is injective,
    # and its alphabet excludes "/", so distinct session ids can never
    # produce colliding or prefix-overlapping keys.
    defp session_key(session_id, suffix) do
      binary = :erlang.term_to_binary(session_id, [:deterministic])
      Base.url_encode64(binary, padding: false) <> "/" <> suffix
    end

    # Sequence numbers are zero-padded so byte-lexicographic key order
    # matches numeric order for prefix scans; 20 digits covers the full
    # 64-bit range.
    defp outbound_key(session_id, seq_num) do
      padded = String.pad_leading(Integer.to_string(seq_num), 20, "0")
      session_key(session_id, "out/" <> padded)
    end
  end
else
  defmodule FIX.Session.Store.EKV do
    @moduledoc """
    Durable session store backed by EKV.

    The optional `:ekv` dependency is missing, so this build only contains
    a stub whose callbacks raise. Add it to compile the real store:

        {:ekv, "~> 0.4"}
    """

    @behaviour FIX.Session.Store

    @spec child_spec(keyword()) :: no_return()
    def child_spec(_options), do: missing_dependency!()

    @spec start_link(keyword()) :: no_return()
    def start_link(_options \\ []), do: missing_dependency!()

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
      #{inspect(__MODULE__)} requires the optional :ekv dependency.

      Add it to your deps to use this store:

          {:ekv, "~> 0.4"}
      """
    end
  end
end
