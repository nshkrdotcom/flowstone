# ADR-0002: DAG Engine and Persistent Metadata

## Status
Accepted

## Context

Asset-first orchestration requires:
1. **Dependency Resolution**: Determine execution order from asset dependencies.
2. **Execution Tracking**: Record what was computed, when, and with what inputs.
3. **Resumability**: Recover from failures without recomputing completed work.
4. **Lineage Queries**: Answer "where did this data come from?" efficiently.

We need a persistence layer that supports these requirements while integrating with BEAM's execution model.

## Decision

### 1. DAG Construction

FlowStone constructs a DAG from declared assets. The execution graph is derived from each asset's explicit
`depends_on` list.

```elixir
# Build a DAG from assets (simplified)
{:ok, graph} = FlowStone.DAG.from_assets(assets)
execution_order = FlowStone.DAG.topological_names(graph)
```

The core DAG representation is:
- `nodes`: `%{asset_name => %FlowStone.Asset{...}}`
- `edges`: `%{asset_name => [dependency_asset_name, ...]}`

This is implemented in `lib/flowstone/dag.ex`.

### 2. Persistence with Ecto/PostgreSQL

FlowStone persists execution metadata and auditability primitives via Ecto/PostgreSQL:

```elixir
defmodule FlowStone.Materialization do
  use Ecto.Schema

  schema "flowstone_materializations" do
    field :asset_name, :string
    field :partition, :string
    field :run_id, Ecto.UUID
    field :status, Ecto.Enum, values: [:pending, :running, :success, :failed, :waiting_approval]
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :upstream_assets, {:array, :string}
    field :upstream_partitions, {:array, :string}
    field :dependency_hash, :string  # Hash of upstream content for invalidation
    field :metadata, :map  # Flexible storage for asset-specific data
    field :error_message, :string
    field :executor_node, :string

    timestamps()
  end
end
```

The key tables are:
- `flowstone_materializations` (execution metadata)
- `flowstone_lineage` (consumption edges between materializations)
- `flowstone_approvals` (checkpoint approval requests/decisions)
- `flowstone_audit_log` (immutable audit events)
- Oban tables (job execution)

Materializations are identified by `{asset_name, partition, run_id}` and enforced via a unique index
(see `priv/repo/migrations/0005_add_materialization_unique_index.exs`).

Partition values are stored as strings using `FlowStone.Partition.serialize/1` (see ADR-0003).

### 3. Lineage as First-Class Rows (Not Arrays)

FlowStone stores lineage edges in `flowstone_lineage` rows and queries transitive lineage using recursive CTEs.
This is implemented in `lib/flowstone/lineage_persistence.ex`.

### 4. Run Correlation

Each workflow execution gets a unique `run_id` (UUID v4) that:
- Links all materializations in a single execution
- Enables "show me everything that ran together"
- Supports audit and compliance queries

## Consequences

### Positive

1. **Durable State**: Materializations survive process/node restarts.
2. **Rich Queries**: SQL enables complex lineage analysis without custom data structures.
3. **Audit Trail**: Complete history of what was computed when.
4. **Resume Support**: Query failed/pending materializations to retry.
5. **Standard Tooling**: Ecto migrations, PostgreSQL ecosystem, backup/restore.

### Negative

1. **Database Dependency**: Requires PostgreSQL for production.
2. **Write Overhead**: Every materialization creates a database record.
3. **Migration Maintenance**: Schema changes require versioned migrations.

### Trade-offs vs. pipeline_ex

| pipeline_ex | FlowStone |
|-------------|-----------|
| File-based checkpoints | PostgreSQL with indexes |
| Manual JSON serialization | Ecto schemas with validation |
| No lineage tracking | First-class lineage queries |
| Per-pipeline checkpoint files | Unified materialization table |

## References

- `lib/flowstone/dag.ex`
- `lib/flowstone/materializations.ex`
- `lib/flowstone/lineage_persistence.ex`
- `priv/repo/migrations/0001_create_materializations.exs`
- `priv/repo/migrations/0003_create_lineage.exs`
- `priv/repo/migrations/0005_add_materialization_unique_index.exs`
