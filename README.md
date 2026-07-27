# FIX.Session

**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `fix_session` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:fix_session, "~> 0.1.0"}
  ]
end
```

## Usage

A session does not start its own store — the store must already be running, and
must outlive the sessions that use it. Start it first and use `:rest_for_one` so
sessions restart if the store ever goes down:

```elixir
config =
  FIX.Session.Config.new!(
    session_id: :ibkr,
    host: "fix.example.com",
    port: 4001,
    sender_comp_id: "ME",
    target_comp_id: "THEM"
  )

children = [
  {FIX.Session.Store.ETS, file: "/var/lib/fix/ibkr.ets"},
  {FIX.Session, config}
]

Supervisor.start_link(children, strategy: :rest_for_one)
```

`FIX.Session.Store.ETS` is the default store. Its table is owned by the store
process, so sequence numbers survive a session crash and reconnect. It is not
crash durable — see its moduledoc for the exact boundary and for the snapshot
options. `FIX.Session.Store.Memory` is the reference implementation for tests.

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/fix_session>.

## License

Licensed under the Apache License 2.0. See [`LICENSE`](LICENSE).
