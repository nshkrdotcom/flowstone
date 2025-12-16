# ADR-0012: Phoenix LiveView UI Integration

## Status
Proposed

## Context

FlowStone benefits from a user interface for:

- viewing materialization history and status
- browsing the asset graph and lineage
- reviewing and deciding approvals

Phoenix LiveView is a strong fit for BEAM-native, real-time UI without a separate frontend stack.

## Decision

### 1. UI as an Optional Component (Separate App/Package)

FlowStone core is a library and does not ship a LiveView UI today. A UI should be implemented as an optional component (e.g., a separate OTP app/package) that integrates by:

- querying FlowStone’s persistence tables (materializations, lineage, approvals, audit log)
- subscribing to PubSub topics emitted by FlowStone where available
- attaching to FlowStone telemetry events for live metrics

This keeps core dependencies lightweight while enabling richer deployments.

### 2. Stable Integration Surfaces

The UI should treat these as integration surfaces:

- Ecto schemas/tables:
  - `flowstone_materializations`
  - `flowstone_lineage`
  - `flowstone_approvals`
  - `flowstone_audit_log`
- telemetry events listed in `FlowStone.Telemetry.events/0`
- PubSub topics emitted by FlowStone (currently `"sensors"` and approval events via notifier/telemetry)

## Consequences

### Positive

1. Core stays usable in non-Phoenix applications.
2. UI can evolve independently and target production operational needs.

### Negative

1. UI requires additional design and a separate release/artifact.

## References

- `lib/flowstone/telemetry.ex`
- `lib/flowstone/pub_sub.ex`
- `priv/repo/migrations/0001_create_materializations.exs`
- `priv/repo/migrations/0002_create_approvals.exs`
- `priv/repo/migrations/0003_create_lineage.exs`
- `priv/repo/migrations/0004_create_audit_log.exs`
