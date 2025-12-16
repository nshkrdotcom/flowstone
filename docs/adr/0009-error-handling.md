# ADR-0009: Structured Error Handling

## Status
Accepted

## Context

Error handling in orchestration systems must:

1. Distinguish between retryable and fatal errors
2. Provide actionable messages
3. Preserve debugging context without relying on ad-hoc exception formatting
4. Integrate with observability (logging, telemetry, persistence)

## Decision

### 1. Use a Structured Error Exception (`FlowStone.Error`)

FlowStone uses a dedicated error type that is also a proper exception (`defexception`) so it can be raised directly when needed.

Each error includes:
- `type` (categorization)
- `message` (human-readable)
- `context` (structured metadata)
- `retryable` (whether the error is transient)
- `original` (wrapped exception, optional)

Implementation: `lib/flowstone/error.ex`.

### 2. Standardize Result Tuples (`FlowStone.Result`)

FlowStone standardizes result shapes:
- `{:ok, value}`
- `{:error, %FlowStone.Error{...}}`

`FlowStone.Result.unwrap!/1` raises `FlowStone.Error` on error.

Implementation: `lib/flowstone/result.ex`.

### 3. Establish a Single Exception Boundary for Asset Execution

Asset `execute` functions run inside a controlled exception boundary so that:
- unexpected exceptions become `FlowStone.Error` values
- stacktraces can be captured and recorded consistently

Implementation: `lib/flowstone/materializer.ex`.

### 4. Record Errors via Logging + Telemetry (+ Materialization Status When Available)

FlowStone records errors by:
- structured logging (`Logger.error/2`)
- emitting `[:flowstone, :error]` telemetry events
- optionally recording failure status on the materialization record

Implementation: `lib/flowstone/error_recorder.ex`, `lib/flowstone/materializations.ex`.

### 5. Retry Decisions are Data-Driven

Workers use the `retryable` flag to choose Oban behavior:
- retryable errors are returned to Oban for retry/backoff
- non-retryable errors are discarded
- “dependency not ready” yields `{:snooze, seconds}`

Implementation: `lib/flowstone/workers/asset_worker.ex`.

## Consequences

### Positive

1. Consistent error shapes across synchronous and asynchronous execution.
2. Centralized retry policy (`retryable`) rather than scattered heuristics.
3. Better observability through structured telemetry and logs.

### Negative

1. Requires discipline: asset `execute` functions must return structured results.
2. Some failures are “best effort” to persist depending on Repo availability and configuration.

## References

- `lib/flowstone/error.ex`
- `lib/flowstone/result.ex`
- `lib/flowstone/materializer.ex`
- `lib/flowstone/error_recorder.ex`
- `lib/flowstone/workers/asset_worker.ex`
