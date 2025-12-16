# ADR-0004: I/O Manager Abstraction

## Status
Accepted

## Context

Assets need to store and retrieve materialized values from different backends (memory for tests, Postgres, object storage, etc.). Storage concerns must be decoupled from asset business logic and must be testable.

## Decision

### 1. I/O Manager Behaviour

FlowStone defines a storage behaviour that backends implement:

```elixir
defmodule FlowStone.IO.Manager do
  @callback load(asset :: atom(), partition :: term(), config :: map()) ::
              {:ok, term()} | {:error, :not_found} | {:error, term()}

  @callback store(asset :: atom(), data :: term(), partition :: term(), config :: map()) ::
              :ok | {:error, term()}

  @callback delete(asset :: atom(), partition :: term(), config :: map()) ::
              :ok | {:error, term()}

  @callback metadata(asset :: atom(), partition :: term(), config :: map()) ::
              {:ok, map()} | {:error, term()}

  @callback exists?(asset :: atom(), partition :: term(), config :: map()) :: boolean()

  @optional_callbacks metadata: 3, exists?: 3
end
```

Implementation: `lib/flowstone/io/manager.ex`.

### 2. I/O Dispatch via Application Configuration

FlowStone dispatches to configured managers using a symbolic key:

```elixir
# config/config.exs
config :flowstone,
  io_managers: %{
    memory: FlowStone.IO.Memory,
    postgres: FlowStone.IO.Postgres,
    s3: FlowStone.IO.S3,
    parquet: FlowStone.IO.Parquet
  },
  default_io_manager: :memory
```

At call-time, the IO manager can be overridden via `io:` options:

```elixir
FlowStone.materialize(:asset_name,
  partition: ~D[2025-01-15],
  io: [io_manager: :postgres, config: %{table: "my_table"}]
)
```

Implementation: `lib/flowstone/io.ex`.

> Note: per-asset IO configuration in the DSL is not implemented in the current `FlowStone.Pipeline` macros. IO configuration is provided at execution time via `io:` options.

### 3. Security Requirements for SQL-Backed Managers

The Postgres IO manager must be safe when using dynamic table/column identifiers:

- Validate table/column identifiers before interpolating into SQL.
- Use parameterized queries for values.
- Use `:erlang.binary_to_term/2` with `[:safe]` when decoding binary terms.

Implementation: `lib/flowstone/io/postgres.ex`.

### 4. Built-In Managers

- `FlowStone.IO.Memory`: in-memory store intended for tests/dev.
- `FlowStone.IO.Postgres`: simple SQL-backed store (assumes a table exists with `{partition, data, updated_at}` columns).
- `FlowStone.IO.S3` / `FlowStone.IO.Parquet`: designed for injectable client functions and integration layering; host applications provide real clients/config.

## Consequences

### Positive

1. Storage is pluggable and testable.
2. Assets remain focused on compute logic; persistence is delegated.
3. Security-sensitive IO managers can enforce invariants centrally.

### Negative

1. Without per-asset IO config in the DSL, callers must pass IO options explicitly.
2. Postgres IO manager depends on host application schema management for asset data tables.

## References

- `lib/flowstone/io.ex`
- `lib/flowstone/io/manager.ex`
- `lib/flowstone/io/memory.ex`
- `lib/flowstone/io/postgres.ex`
- `lib/flowstone/io/s3.ex`
- `lib/flowstone/io/parquet.ex`
