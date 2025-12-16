# ADR-0013: Testing Strategies

## Status
Accepted

## Context

Orchestration systems are difficult to test due to:

- external dependencies (DB, storage, APIs)
- time-based behavior (schedules, timeouts)
- distributed execution (job queues)

Tests must be fast, deterministic, and must not depend on global mutable state.

## Decision

### 1. Use ExUnit + Ecto Sandbox + Isolation Harness

FlowStone tests use:

- `ExUnit`
- `Ecto.Adapters.SQL.Sandbox` for DB isolation
- `Supertester` for process isolation patterns

Implementation: `test/support/test_case.ex`, `test/test_helper.exs`.

### 2. Prefer Dependency Injection Over Global Test Modes

Tests pass explicit servers and IO configuration into the APIs under test:

- start per-test registries (`FlowStone.Registry`) and IO agents (`FlowStone.IO.Memory`)
- pass `registry:` and `io:` opts into `FlowStone.materialize/2`
- pass `resource_server:` / `lineage_server:` / `materialization_store:` when needed

This keeps tests isolated and avoids environment-variable “test modes”.

### 3. Oban Testing Strategy

In test environment, Oban is configured with `testing: :inline` so that enqueued jobs execute immediately. For cases where queue draining is needed, tests use `FlowStone.ObanHelpers.drain/1`.

Implementation: `config/test.exs`, `lib/flowstone/oban_helpers.ex`.

### 4. Test the Persisted Boundary (JSON Round-Trip)

Because Oban args persist as JSON, FlowStone includes tests that ensure:

- args survive JSON encode/decode
- runtime configuration is carried via `FlowStone.RunConfig` rather than job args
- workers resolve asset names safely (no unbounded atom creation)

Implementation: `test/flowstone/workers/asset_worker_test.exs`.

## Consequences

### Positive

1. Tests remain deterministic and fast.
2. Production behaviors that depend on persistence boundaries are explicitly tested.
3. Isolation reduces flakiness from global shared processes.

### Negative

1. Some production behaviors (multi-node scheduling, external IO managers) require integration tests outside the core test suite.

## References

- `test/support/test_case.ex`
- `config/test.exs`
- `test/flowstone/workers/asset_worker_test.exs`
