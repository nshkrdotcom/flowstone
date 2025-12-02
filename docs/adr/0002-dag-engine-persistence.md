# ADR-0002: DAG Engine with Persistent Metadata

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

### 1. Runic for DAG Construction

Use the **Runic** library (~> 0.1) for DAG operations:

```elixir
# Build workflow from asset definitions
defp build_dag(assets) do
  Runic.DAG.new()
  |> add_assets(assets)
  |> Runic.DAG.topological_sort()
end
```

Runic provides:
- Topological sorting with cycle detection
- Efficient dependency traversal
- Lightweight (no external dependencies)

### 2. Ecto for Persistence

Use **Ecto** with PostgreSQL for materialization tracking:

```elixir
defmodule FlowStone.Materialization do
  use Ecto.Schema

  schema "flowstone_materializations" do
    field :asset_name, :string
    field :partition, :string
    field :run_id, Ecto.UUID
    field :status, Ecto.Enum, values: [:pending, :running, :success, :failed, :waiting_approval]

    # Timing
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :duration_ms, :integer

    # Lineage
    field :upstream_assets, {:array, :string}
    field :upstream_partitions, {:array, :string}
    field :dependency_hash, :string  # Hash of upstream content for invalidation

    # Metadata
    field :metadata, :map  # Flexible storage for asset-specific data
    field :error_message, :string
    field :executor_node, :string

    timestamps()
  end
end
```

### 3. Schema Design

```sql
CREATE TABLE flowstone_materializations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_name VARCHAR(255) NOT NULL,
  partition VARCHAR(255),
  run_id UUID NOT NULL,
  status VARCHAR(50) NOT NULL DEFAULT 'pending',

  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  duration_ms INTEGER,

  upstream_assets TEXT[],
  upstream_partitions TEXT[],
  dependency_hash VARCHAR(64),

  metadata JSONB DEFAULT '{}',
  error_message TEXT,
  executor_node VARCHAR(255),

  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Performance indexes
CREATE INDEX idx_materializations_asset_partition
  ON flowstone_materializations(asset_name, partition);
CREATE INDEX idx_materializations_run_id
  ON flowstone_materializations(run_id);
CREATE INDEX idx_materializations_status
  ON flowstone_materializations(status);
CREATE INDEX idx_materializations_inserted_at
  ON flowstone_materializations(inserted_at DESC);

-- Lineage query support (GIN for array containment)
CREATE INDEX idx_materializations_upstream_assets
  ON flowstone_materializations USING GIN(upstream_assets);
```

### 4. Lineage Query Implementation

```elixir
defmodule FlowStone.Lineage do
  @doc "Get all upstream assets for a materialization"
  def upstream(asset_name, partition) do
    query = from m in Materialization,
      where: m.asset_name == ^asset_name and m.partition == ^partition,
      order_by: [desc: m.completed_at],
      limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      mat -> {:ok, expand_upstream(mat.upstream_assets, mat.upstream_partitions)}
    end
  end

  @doc "Get all downstream assets that depend on this asset"
  def downstream(asset_name, partition) do
    query = from m in Materialization,
      where: ^asset_name in m.upstream_assets,
      select: %{asset: m.asset_name, partition: m.partition}

    {:ok, Repo.all(query)}
  end

  @doc "Calculate impact: what needs recomputation if this asset changes"
  def impact(asset_name, partition) do
    # Recursive CTE for transitive closure
    query = """
    WITH RECURSIVE downstream AS (
      SELECT DISTINCT asset_name, partition
      FROM flowstone_materializations
      WHERE $1 = ANY(upstream_assets)

      UNION

      SELECT DISTINCT m.asset_name, m.partition
      FROM flowstone_materializations m
      INNER JOIN downstream d ON d.asset_name = ANY(m.upstream_assets)
    )
    SELECT * FROM downstream
    """

    {:ok, Repo.query!(query, [asset_name])}
  end
end
```

### 5. Run Correlation

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

- Runic library: hex.pm/packages/runic
- Dagster's run storage: https://docs.dagster.io/concepts/dagit/graphql
