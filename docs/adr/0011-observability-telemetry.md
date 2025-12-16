# ADR-0011: Observability and Telemetry

## Status
Accepted

## Context

Orchestration systems require visibility into:

- materialization performance and failure rates
- storage performance (load/store latency)
- approval events and timeouts
- error volume and retry behavior
- audit trails for compliance

FlowStone should integrate with standard BEAM observability tooling.

## Decision

### 1. Use `:telemetry` for Instrumentation

FlowStone emits telemetry events for key lifecycle transitions:

- materialization: `[:flowstone, :materialization, :start|:stop|:exception]`
- IO: `[:flowstone, :io, :load|:store, :start|:stop]`
- approvals: `[:flowstone, :checkpoint, :requested|:approved|:rejected|:timeout]`
- errors: `[:flowstone, :error]`

Event names are centralized in `lib/flowstone/telemetry.ex`.

### 2. Provide Metrics Definitions

FlowStone defines a default set of `Telemetry.Metrics` that can be exported to Prometheus when an exporter is available.

Implementation: `lib/flowstone/telemetry_metrics.ex` and `lib/flowstone/application.ex`.

### 3. Structured Logging for Errors

Errors are logged with structured metadata (type, asset, partition, run_id, retryable) and mirrored via telemetry.

Implementation: `lib/flowstone/error_recorder.ex`.

### 4. Optional Audit Log Persistence

For deployments that require immutable audit trails, FlowStone can write audit events to `flowstone_audit_log` when Repo usage is enabled.

Implementation: `lib/flowstone/audit_log.ex`, `lib/flowstone/audit_log_context.ex`.

## Consequences

### Positive

1. Integrates with standard telemetry pipelines and exporters.
2. Provides consistent event naming for dashboards and alerts.
3. Supports audit-trail persistence when needed.

### Negative

1. Observability fidelity depends on which subsystems are enabled (Repo, Oban, exporters).
2. Some higher-level UI concerns (live dashboards) require additional, separate components.

## References

- `lib/flowstone/telemetry.ex`
- `lib/flowstone/telemetry_metrics.ex`
- `lib/flowstone/executor.ex`
- `lib/flowstone/io.ex`
- `lib/flowstone/approvals.ex`
- `lib/flowstone/error_recorder.ex`
- `lib/flowstone/audit_log_context.ex`
