# FIX.Session

An initiator-side [FIX](https://www.fixtrading.org/standards/) session engine for Elixir.

`FIX.Session` uses `:gen_statem` to manage connection lifecycle, FIX sequence numbers, logon/logout, heartbeats, gap recovery, persistence, and delivery of validated application messages. FIX 4.4 over TCP is the default configuration.

> **Status:** Early development (`0.1.0`). The API and storage format may change. See [Current limitations](#current-limitations) before using this library in production.

## Features

- Initiator-side TCP sessions with automatic reconnects
- Logon, Logout, Heartbeat, TestRequest, ResendRequest, and SequenceReset handling
- Independent inbound and outbound liveness timers
- Inbound sequence validation, gap buffering, and duplicate suppression
- Atomic persistence of outbound wire data and the next outbound sequence number
- Pluggable transport and session-store behaviours
- Application delivery only after session and sequence validation
- Pure protocol transitions that can be tested without sockets or processes

## Installation

Add [`fix_session`](https://hex.pm/packages/fix_session) to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:fix_session, "~> 0.1.0"}
  ]
end
```

Then fetch the dependency with `mix deps.get`.

The project requires Elixir `~> 1.19`.

## Getting started

A session does not start or own its store. The store must start first and outlive every session that uses it. Supervise the store and session with `:rest_for_one` so a store failure also restarts dependent sessions:

```elixir
defmodule MyApp.FIXSupervisor do
  use Supervisor

  @impl true
  def start_link(options) do
    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options) do
    config =
      FIX.Session.Config.new!(
        session_id: :primary,
        name: MyApp.FIXSession,
        host: "fix.example.com",
        port: 4001,
        sender_comp_id: "SENDER",
        target_comp_id: "TARGET",
        app: MyApp.FIXHandler
      )

    children = [
      {FIX.Session.Store.ETS, file: "/var/lib/my_app/fix_session.ets"},
      {FIX.Session, config}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
```

With its default options, `FIX.Session.Store.ETS` creates the named table used by the default `store_ref`, so no additional store configuration is necessary.

The session connects immediately, sends Logon, and reconnects every five seconds after an ordinary connection failure. A session is available for application messages only after the counterparty's Logon has been accepted.

### Receiving application messages

Set `:app` to a module that exports `handle_message/2`. The callback runs synchronously in the session process and receives the validated `FIX.Message` and session config:

```elixir
defmodule MyApp.FIXHandler do
  def handle_message(%FIX.Message{} = message, %FIX.Session.Config{} = config) do
    send(MyApp.OrderManager, {:fix_message, config.session_id, message})
    :ok
  end
end
```

Keep this callback fast and non-blocking. If no `:app` module is configured, validated application messages are discarded.

### Sending application messages

Pass a `FIX.Message` to the running session:

```elixir
message = %FIX.Message{
  msg_type: "D",
  body: [
    # Application fields for NewOrderSingle
  ]
}

:ok = FIX.Session.send_message(MyApp.FIXSession, message)
```

The session assigns and overwrites session-controlled fields, including `BeginString(8)`, `MsgSeqNum(34)`, `SenderCompID(49)`, `SendingTime(52)`, and `TargetCompID(56)`. It persists the encoded message and advances `next_out` before writing to the socket.

Calling `send_message/2` before Logon completes returns:

```elixir
{:error, {:not_logged_on, current_state}}
```

### Logging out

```elixir
:ok = FIX.Session.logout(MyApp.FIXSession, "Application shutdown")
```

An operator-requested logout is terminal for that process: after the Logout exchange or timeout, it remains disconnected rather than reconnecting automatically. Restart the supervised session to establish a new connection.

## Configuration

Create a validated `%FIX.Session.Config{}` with `FIX.Session.Config.new!/1`.

### Required options

| Option            | Description                                      |
| ----------------- | ------------------------------------------------ |
| `:session_id`     | Logical session identifier used as the store key |
| `:host`           | Counterparty hostname, charlist, or IP tuple     |
| `:port`           | Counterparty TCP port                            |
| `:sender_comp_id` | Local `SenderCompID(49)`                         |
| `:target_comp_id` | Counterparty `TargetCompID(56)`                  |

### Common optional settings

| Option                 | Default                | Description                                                |
| ---------------------- | ---------------------- | ---------------------------------------------------------- |
| `:name`                | `nil`                  | Local or registry name passed to `:gen_statem`             |
| `:begin_string`        | `"FIX.4.4"`            | FIX BeginString                                            |
| `:heartbeat_interval`  | `30`                   | `HeartBtInt(108)` in seconds; `0` disables liveness timers |
| `:connect_timeout`     | `10_000`               | Connection timeout in milliseconds                         |
| `:logon_timeout`       | `10_000`               | Time to wait for the peer's Logon, in milliseconds         |
| `:logout_timeout`      | `10_000`               | Time to wait for Logout completion, in milliseconds        |
| `:reconnect_interval`  | `5_000`                | Delay between connection attempts, in milliseconds         |
| `:transport_options`   | `[]`                   | Options for the configured transport (`:gen_tcp` or `:ssl`) |
| `:dictionary`          | `FIX.Dictionary.FIX44` | Dictionary used to parse inbound messages                  |
| `:app`                 | `nil`                  | Application message callback module                        |
| `:default_appl_ver_id` | `nil`                  | Optional `DefaultApplVerID(1137)` included in Logon        |

Advanced integrations can replace `:transport`, `:store`, and `:store_ref` with modules and references implementing `FIX.Session.Transport` and `FIX.Session.Store`.

### TLS

`FIX.Session.Transport.TLS` connects over `:ssl` with peer verification against the OS trust store by default:

```elixir
config =
  FIX.Session.Config.new!(
    # ...
    transport: FIX.Session.Transport.TLS,
    transport_options: [cacertfile: "/etc/fix/counterparty_ca.pem"]
  )
```

Pass `:cacertfile` or `:cacerts` to pin a counterparty CA (common with self-signed FIX endpoints), or `verify: :verify_none` to disable verification entirely. See the `FIX.Session.Transport.TLS` docs for the full list of defaults and how to override them.

## Persistence

`FIX.Session.Store.ETS` is the default store. Its table is owned by a dedicated supervised process, so sequence numbers and outbound messages survive a session-process crash or reconnect.

The ETS store is **not fully crash durable**:

- Without `:file`, state is lost when the store process or VM exits.
- With `:file`, state is restored at startup and snapshotted during graceful store shutdown.
- A hard crash can leave the snapshot stale. Restoring stale outbound sequence state can reuse sequence numbers that were already sent.

Use the ETS snapshot only when those guarantees are acceptable. Production deployments requiring crash durability should use `FIX.Session.Store.EKV` or `FIX.Session.Store.Postgres` (below), or implement `FIX.Session.Store` with transactional durable storage. `FIX.Session.Store.Memory` is intended for tests and development.

For isolated ETS stores, start the owner with `name: nil`, retrieve its table with `FIX.Session.Store.ETS.table/1`, and pass that table as `:store_ref` in the session config.

### Durable storage with EKV

`FIX.Session.Store.EKV` persists sequence numbers and outbound messages to SQLite through [EKV](https://hex.pm/packages/ekv), so state survives store and VM crashes. It requires the optional `:ekv` dependency (which ships a vendored, precompiled SQLite NIF):

```elixir
{:ekv, "~> 0.4"}
```

Supervise it in place of the ETS store and select it in the session config:

```elixir
children = [
  {FIX.Session.Store.EKV, data_dir: "/var/lib/my_app/fix_session"},
  {FIX.Session, FIX.Session.Config.new!(store: FIX.Session.Store.EKV, ...)}
]
```

Reusing the same `:data_dir` across restarts resumes the persisted session state. See the `FIX.Session.Store.EKV` docs for options and durability details.

### Durable storage with Postgres

`FIX.Session.Store.Postgres` persists sequence numbers and outbound messages through the host application's `Ecto.Repo`, committing each outbound message and its advanced sequence number in a single database transaction. It requires the optional `:ecto_sql` and `:postgrex` dependencies:

```elixir
{:ecto_sql, "~> 3.10"},
{:postgrex, "~> 0.19"}
```

Create the tables from a migration in your application:

```elixir
defmodule MyApp.Repo.Migrations.AddFixSessionTables do
  use Ecto.Migration

  def up, do: FIX.Session.Store.Postgres.Migrations.up()
  def down, do: FIX.Session.Store.Postgres.Migrations.down()
end
```

The store owns no processes — pass your repo as the `store_ref` and supervise it before the session:

```elixir
children = [
  MyApp.Repo,
  {FIX.Session,
   FIX.Session.Config.new!(
     store: FIX.Session.Store.Postgres,
     store_ref: MyApp.Repo,
     # ...
   )}
]
```

## Current limitations

- Initiator sessions only; there is no acceptor/listener implementation.
- FIX 4.4 is the tested/default dictionary and protocol target.
- Inbound ResendRequests are currently answered with a SequenceReset-GapFill rather than replaying stored business messages.
- ETS snapshots do not provide hard-crash durability; use `FIX.Session.Store.EKV` or `FIX.Session.Store.Postgres` when you need a durable store.
- Session schedules, bounded outbound retention, telemetry, and formal FIX conformance testing are not yet implemented.
- `reset_on_logon: true` is explicitly unsupported.

## Development

Fetch dependencies and run the test suite:

```sh
mix deps.get
mix test
```

The `FIX.Session.Store.Postgres` tests need a reachable Postgres server (`FIX_SESSION_PG_URL`, defaulting to `postgres://postgres:postgres@localhost:5432/fix_session_test`); without one they are skipped with a warning.

Format and compile with warnings treated as errors:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
```

## License

Licensed under the Apache License 2.0. See [`LICENSE`](LICENSE).
