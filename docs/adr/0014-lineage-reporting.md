# ADR-0014: Lineage and Audit Reporting

## Status
Accepted

## Context

Organizations frequently need to answer:

- “Where did this data come from?”
- “What will be impacted if this source changes?”
- “What ran, when, and under which run_id?”

These questions require durable execution metadata and lineage edges.

## Decision

### 1. Persist Lineage as Edge Rows

FlowStone stores lineage as explicit consumption edges in `flowstone_lineage`:

- downstream: `{asset_name, partition, run_id}`
- upstream: `{upstream_asset, upstream_partition}`
- timestamp: `consumed_at`

Implementation: `lib/flowstone/lineage/entry.ex`, migration `priv/repo/migrations/0003_create_lineage.exs`.

### 2. Record Lineage on Successful Materialization

After an asset materializes successfully, FlowStone records lineage for all loaded dependencies.

Implementation: `lib/flowstone/executor.ex` calls `lib/flowstone/lineage_persistence.ex`.

### 3. Query Lineage via Recursive CTEs (Repo Mode) with In-Memory Fallback

FlowStone exposes:

- `FlowStone.LineagePersistence.upstream/3`
- `FlowStone.LineagePersistence.downstream/3`
- `FlowStone.LineagePersistence.impact/3`

When Repo mode is enabled, upstream/downstream use recursive CTE queries with a bounded depth (default cap 100 for `:infinity`).

When Repo mode is unavailable, the system can fall back to an in-memory `FlowStone.Lineage` server if it is running.

Implementation: `lib/flowstone/lineage_persistence.ex`, `lib/flowstone/lineage.ex`.

### 4. Identifier Safety

Lineage tables store asset names as strings. Query results may return `asset` as an atom only when the atom already exists; otherwise the asset name is returned as a string to avoid unbounded atom creation.

Implementation: `safe_to_atom/1` in `lib/flowstone/lineage_persistence.ex` and `lib/flowstone/lineage.ex`.

### 5. Audit Log

For deployments that require immutable audit trails, FlowStone writes audit events to `flowstone_audit_log` when Repo usage is enabled.

Implementation: `lib/flowstone/audit_log.ex`, `lib/flowstone/audit_log_context.ex`, migration `priv/repo/migrations/0004_create_audit_log.exs`.

## Consequences

### Positive

1. Lineage can be queried efficiently (including transitive closure) using SQL.
2. Supports impact analysis without bespoke graph stores.
3. Audit log provides an immutable record where required.

### Negative

1. In-memory fallback lineage is not durable and may return partitions in serialized form.
2. Depth-bounded recursion trades completeness for query safety in large graphs.

## References

- `lib/flowstone/lineage_persistence.ex`
- `lib/flowstone/lineage.ex`
- `lib/flowstone/lineage/entry.ex`
- `lib/flowstone/audit_log_context.ex`
