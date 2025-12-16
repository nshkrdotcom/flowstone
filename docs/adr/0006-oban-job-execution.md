# ADR-0006: Oban-Based Job Execution

## Status
Accepted

## Context

Asset materialization needs reliable, distributed execution with:

- At-least-once delivery
- Automatic retries with backoff
- Durable persistence across process/node restarts
- Concurrency control
- Observability (telemetry + logs)

Oban persists job `args` as JSON. That imposes a hard constraint: job arguments must be JSON-safe and must round-trip through the database without losing type information required by the worker.

## Decision

### 1. Use Oban When Available, Otherwise Execute Synchronously

FlowStone uses Oban for asynchronous execution when Oban is running, and falls back to synchronous execution otherwise (useful for development, tests, and embedded use).

### 2. Constrain Oban Args to a Minimal, JSON-Safe Schema

FlowStone workers accept only JSON-safe values in `args`:

- `"asset_name"`: string
- `"partition"`: serialized partition string (`FlowStone.Partition.serialize/1`)
- `"run_id"`: UUID string
- `"use_repo"`: boolean

No runtime terms (pids, atoms requiring creation, modules, functions, keyword lists) are allowed in Oban args.

### 3. Store Non-JSON Runtime Configuration in `FlowStone.RunConfig`

Runtime configuration that cannot be safely serialized (servers, full IO keyword lists, etc.) is stored in `FlowStone.RunConfig` keyed by `run_id`.

At execution time the worker loads configuration in this order:

1. Explicit `run_config` passed for synchronous execution
2. `FlowStone.RunConfig.get(run_id)` (ETS cache)
3. Application config defaults

This keeps Oban args stable while allowing host applications to override servers and execution behavior.

### 4. Safe Asset Name Resolution (No Unbounded Atom Creation)

Assets are referenced by string names in persisted boundaries (Oban args, DB rows). The worker resolves names safely:

- Prefer `String.to_existing_atom/1` (fast path), and verify the asset exists in the registry
- Otherwise, search the registry by string name and return the existing atom from the registered asset struct

FlowStone never uses `String.to_atom/1` on external/persisted inputs.

### 5. Retry Semantics and Backoff

The worker returns:

- `:ok` on success
- `{:discard, ...}` for non-retryable failures
- retryable `FlowStone.Error` values for transient failures
- `{:snooze, seconds}` when dependencies are not ready

Backoff is exponential with an upper cap (see worker implementation).

### 6. Unique Job Keys

To prevent duplicates, jobs are configured as unique on stable identifiers:

- `asset_name`
- `partition`
- `run_id`

## Consequences

### Positive

1. Durable, restart-safe execution via PostgreSQL-backed job state.
2. Clear separation between persisted job intent (JSON args) and runtime wiring (RunConfig).
3. Eliminates a class of production failures caused by non-JSON job args.
4. Avoids atom table exhaustion by prohibiting `String.to_atom/1` on external inputs.

### Negative

1. RunConfig is a best-effort cache; long-lived jobs may fall back to application defaults if the original RunConfig entry has expired or is missing.
2. Debugging requires understanding both job args and the resolved RunConfig path.

## References

- `lib/flowstone.ex`
- `lib/flowstone/run_config.ex`
- `lib/flowstone/workers/asset_worker.ex`
- `config/config.exs` (Oban config)
