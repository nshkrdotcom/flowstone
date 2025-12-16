# ADR-0005: Checkpoint and Approval Gates

## Status
Accepted

## Context

Some workflows require human (or policy) approval before continuing:

- quality review (generated content, ML outputs)
- sensitive or regulated actions
- operational change management

The approval flow must be auditable and observable, and it must work both with and without database-backed persistence.

## Decision

### 1. Approval is an Explicit Execution Outcome

Assets may return `{:wait_for_approval, attrs}` from their `execute` function to request an approval gate.

The runtime:

- records an approval request
- marks the materialization as `:waiting_approval`
- returns an error to halt the current execution path

Implementation: `lib/flowstone/materializer.ex`, `lib/flowstone/materializations.ex`.

### 2. Approvals are Persisted via Repo When Available, Otherwise In-Memory

FlowStone provides a persistence wrapper:

- Repo-backed approvals via `flowstone_approvals` (Ecto schema `FlowStone.Approval`)
- in-memory fallback via `FlowStone.Checkpoint` (GenServer) when Repo usage is disabled

Implementation: `lib/flowstone/approvals.ex`, `lib/flowstone/approval.ex`, `lib/flowstone/checkpoint.ex`.

### 3. Timeout Handling

When Repo-backed approvals are enabled and Oban is running, approval timeouts are scheduled via an Oban worker.

Implementation: `lib/flowstone/workers/checkpoint_timeout.ex`.

### 4. Notifications and Telemetry

Approval lifecycle events emit:

- telemetry events: `[:flowstone, :checkpoint, :requested|:approved|:rejected|:timeout]`
- optional notifications via `FlowStone.Checkpoint.Notifier` (default no-op)

Implementation: `lib/flowstone/approvals.ex`, `lib/flowstone/checkpoint/notifier.ex`.

### 5. Resume Semantics (Current Scope)

The current core implementation records approvals and timeout decisions, but does not yet provide a built-in “resume execution after approval” mechanism. Host applications can resume by re-materializing the gated asset or by implementing a continuation job model.

This limitation is tracked as follow-up design/implementation work (see ADRs added after v0.2.0 as needed).

## Consequences

### Positive

1. Approvals are auditable and observable, even in minimal deployments.
2. The approval request mechanism is explicit and testable (simple return value contract).
3. Timeout processing can be offloaded to Oban when available.

### Negative

1. Without first-class continuation, “pause and resume” requires host orchestration or manual re-run.
2. In-memory approvals cannot enforce timeouts across restarts.

## References

- `lib/flowstone/materializer.ex`
- `lib/flowstone/approvals.ex`
- `lib/flowstone/checkpoint.ex`
- `lib/flowstone/workers/checkpoint_timeout.ex`
