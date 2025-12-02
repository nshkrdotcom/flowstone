# ADR-0014: Lineage and Audit Reporting

## Status
Accepted

## Context

Organizations need to answer questions like:
- "Where did this data come from?"
- "What is affected if this source changes?"
- "Who approved this output?"
- "What was the state at a specific point in time?"

These requirements are common in:
- Regulatory environments (audit trails)
- Data quality investigations
- Impact analysis for changes
- Debugging production issues

## Decision

### 1. Lineage Data Model

```elixir
defmodule FlowStone.Lineage.Entry do
  use Ecto.Schema

  schema "flowstone_lineage" do
    field :asset_name, :string
    field :partition, :string
    field :run_id, Ecto.UUID

    # Upstream references
    field :upstream_asset, :string
    field :upstream_partition, :string
    field :upstream_materialization_id, Ecto.UUID

    # Timing
    field :consumed_at, :utc_datetime_usec

    timestamps()
  end
end
```

```sql
CREATE TABLE flowstone_lineage (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_name VARCHAR(255) NOT NULL,
  partition VARCHAR(255),
  run_id UUID NOT NULL,

  upstream_asset VARCHAR(255) NOT NULL,
  upstream_partition VARCHAR(255),
  upstream_materialization_id UUID,

  consumed_at TIMESTAMPTZ NOT NULL,

  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_lineage_asset_partition ON flowstone_lineage(asset_name, partition);
CREATE INDEX idx_lineage_upstream ON flowstone_lineage(upstream_asset, upstream_partition);
CREATE INDEX idx_lineage_run ON flowstone_lineage(run_id);
```

### 2. Lineage Recording

```elixir
defmodule FlowStone.Lineage.Recorder do
  def record_consumption(context, deps) do
    entries =
      Enum.map(deps, fn {dep_asset, dep_data} ->
        %FlowStone.Lineage.Entry{
          asset_name: Atom.to_string(context.asset),
          partition: serialize_partition(context.partition),
          run_id: context.run_id,
          upstream_asset: Atom.to_string(dep_asset),
          upstream_partition: serialize_partition(get_partition(dep_data)),
          upstream_materialization_id: get_materialization_id(dep_asset, dep_data),
          consumed_at: DateTime.utc_now()
        }
      end)

    Repo.insert_all(FlowStone.Lineage.Entry, entries)
  end
end
```

### 3. Lineage Query API

```elixir
defmodule FlowStone.Lineage do
  @doc """
  Get all upstream assets for a given asset/partition.
  Returns the full dependency tree.
  """
  def upstream(asset, partition, opts \\ []) do
    depth = Keyword.get(opts, :depth, :infinity)

    query = """
    WITH RECURSIVE upstream_tree AS (
      -- Base case: direct dependencies
      SELECT
        l.upstream_asset,
        l.upstream_partition,
        l.upstream_materialization_id,
        1 as depth
      FROM flowstone_lineage l
      WHERE l.asset_name = $1 AND l.partition = $2

      UNION ALL

      -- Recursive case: dependencies of dependencies
      SELECT
        l.upstream_asset,
        l.upstream_partition,
        l.upstream_materialization_id,
        t.depth + 1
      FROM flowstone_lineage l
      INNER JOIN upstream_tree t
        ON l.asset_name = t.upstream_asset
        AND l.partition = t.upstream_partition
      WHERE t.depth < $3
    )
    SELECT DISTINCT
      upstream_asset,
      upstream_partition,
      upstream_materialization_id,
      MIN(depth) as depth
    FROM upstream_tree
    GROUP BY upstream_asset, upstream_partition, upstream_materialization_id
    ORDER BY depth, upstream_asset
    """

    max_depth = if depth == :infinity, do: 100, else: depth
    {:ok, result} = Repo.query(query, [to_string(asset), serialize_partition(partition), max_depth])

    Enum.map(result.rows, fn [asset, partition, mat_id, depth] ->
      %{
        asset: String.to_atom(asset),
        partition: deserialize_partition(partition),
        materialization_id: mat_id,
        depth: depth
      }
    end)
  end

  @doc """
  Get all downstream assets that depend on this asset/partition.
  """
  def downstream(asset, partition, opts \\ []) do
    depth = Keyword.get(opts, :depth, :infinity)

    query = """
    WITH RECURSIVE downstream_tree AS (
      SELECT
        l.asset_name,
        l.partition,
        l.run_id,
        1 as depth
      FROM flowstone_lineage l
      WHERE l.upstream_asset = $1 AND l.upstream_partition = $2

      UNION ALL

      SELECT
        l.asset_name,
        l.partition,
        l.run_id,
        t.depth + 1
      FROM flowstone_lineage l
      INNER JOIN downstream_tree t
        ON l.upstream_asset = t.asset_name
        AND l.upstream_partition = t.partition
      WHERE t.depth < $3
    )
    SELECT DISTINCT asset_name, partition, MIN(depth)
    FROM downstream_tree
    GROUP BY asset_name, partition
    ORDER BY MIN(depth), asset_name
    """

    max_depth = if depth == :infinity, do: 100, else: depth
    {:ok, result} = Repo.query(query, [to_string(asset), serialize_partition(partition), max_depth])

    Enum.map(result.rows, fn [asset, partition, depth] ->
      %{asset: String.to_atom(asset), partition: deserialize_partition(partition), depth: depth}
    end)
  end

  @doc """
  Calculate impact: what needs to be recomputed if this asset changes.
  """
  def impact(asset, partition) do
    downstream(asset, partition)
    |> Enum.map(fn entry ->
      mat = FlowStone.Materialization.get(entry.asset, entry.partition)
      Map.put(entry, :status, mat && mat.status)
    end)
  end

  @doc """
  Get the complete lineage graph for visualization.
  """
  def graph(asset, partition) do
    upstream_nodes = upstream(asset, partition)
    downstream_nodes = downstream(asset, partition)

    center = %{asset: asset, partition: partition, depth: 0}

    nodes =
      [center | upstream_nodes ++ downstream_nodes]
      |> Enum.uniq_by(&{&1.asset, &1.partition})

    edges =
      Repo.all(
        from l in FlowStone.Lineage.Entry,
        where: l.asset_name in ^Enum.map(nodes, &to_string(&1.asset)),
        select: %{from: l.upstream_asset, to: l.asset_name}
      )

    %{nodes: nodes, edges: edges}
  end
end
```

### 4. Materialization Metadata

```elixir
defmodule FlowStone.Materialization do
  schema "flowstone_materializations" do
    # ... existing fields ...

    # Rich metadata for audit
    field :metadata, :map, default: %{}
    # metadata may include:
    # - execution_node: which node ran this
    # - input_hashes: hash of each dependency's content
    # - output_hash: hash of produced content
    # - model_info: for ML assets, model version/params
    # - source_info: for source assets, API version/credentials used
  end
end

# Recording metadata during execution
defmodule FlowStone.Materializer do
  def record_success(asset, context, result, deps) do
    metadata = %{
      execution_node: node(),
      input_hashes: compute_dependency_hashes(deps),
      output_hash: compute_hash(result),
      duration_ms: DateTime.diff(DateTime.utc_now(), context.started_at, :millisecond)
    }

    # Merge with asset-specific metadata
    asset_metadata = FlowStone.Asset.metadata(asset)
    full_metadata = Map.merge(metadata, asset_metadata)

    Repo.insert!(%FlowStone.Materialization{
      asset_name: to_string(asset),
      partition: serialize_partition(context.partition),
      run_id: context.run_id,
      status: :success,
      completed_at: DateTime.utc_now(),
      metadata: full_metadata
    })
  end
end
```

### 5. Audit Report Generation

```elixir
defmodule FlowStone.Reports.AuditReport do
  @doc """
  Generate a complete audit report for an asset/partition.
  Includes full lineage, all approvals, and execution metadata.
  """
  def generate(asset, partition) do
    materialization = FlowStone.Materialization.get(asset, partition)
    upstream = FlowStone.Lineage.upstream(asset, partition)
    checkpoints = list_checkpoints_for_run(materialization.run_id)

    %{
      asset: asset,
      partition: partition,
      generated_at: DateTime.utc_now(),

      execution: %{
        run_id: materialization.run_id,
        status: materialization.status,
        started_at: materialization.started_at,
        completed_at: materialization.completed_at,
        duration_ms: materialization.metadata["duration_ms"],
        execution_node: materialization.metadata["execution_node"]
      },

      lineage: %{
        upstream_count: length(upstream),
        upstream_assets: Enum.map(upstream, fn u ->
          mat = FlowStone.Materialization.get(u.asset, u.partition)
          %{
            asset: u.asset,
            partition: u.partition,
            depth: u.depth,
            materialized_at: mat && mat.completed_at,
            hash: mat && mat.metadata["output_hash"]
          }
        end)
      },

      approvals: Enum.map(checkpoints, fn cp ->
        %{
          checkpoint: cp.checkpoint_name,
          status: cp.status,
          decided_by: cp.decision_by,
          decided_at: cp.decision_at,
          reason: cp.reason
        }
      end),

      data_quality: %{
        input_hashes: materialization.metadata["input_hashes"],
        output_hash: materialization.metadata["output_hash"]
      }
    }
  end

  @doc "Export audit report to JSON"
  def to_json(report) do
    Jason.encode!(report, pretty: true)
  end

  @doc "Export audit report to PDF (via typst or similar)"
  def to_pdf(report, output_path) do
    template = render_template(report)
    System.cmd("typst", ["compile", "-", output_path], input: template)
  end
end
```

### 6. Point-in-Time Queries

```elixir
defmodule FlowStone.Lineage.TimeMachine do
  @doc """
  Reconstruct the lineage as it existed at a specific point in time.
  Useful for auditing historical decisions.
  """
  def at(asset, partition, timestamp) do
    # Get the materialization that was active at that time
    mat = Repo.one(
      from m in Materialization,
      where: m.asset_name == ^to_string(asset),
      where: m.partition == ^serialize_partition(partition),
      where: m.completed_at <= ^timestamp,
      order_by: [desc: m.completed_at],
      limit: 1
    )

    case mat do
      nil ->
        {:error, :not_found}

      mat ->
        # Get lineage entries from that specific run
        lineage = Repo.all(
          from l in FlowStone.Lineage.Entry,
          where: l.run_id == ^mat.run_id
        )

        {:ok, %{materialization: mat, lineage: lineage}}
    end
  end
end
```

### 7. Invalidation API

```elixir
defmodule FlowStone.Lineage.Invalidation do
  @doc """
  Invalidate all downstream assets when a source changes.
  Returns list of assets that need rematerialization.
  """
  def invalidate_downstream(asset, partition) do
    downstream = FlowStone.Lineage.downstream(asset, partition)

    # Mark all downstream materializations as stale
    Enum.each(downstream, fn entry ->
      Repo.update_all(
        from(m in Materialization,
          where: m.asset_name == ^to_string(entry.asset),
          where: m.partition == ^serialize_partition(entry.partition),
          where: m.status == :success
        ),
        set: [status: :stale]
      )
    end)

    downstream
  end

  @doc """
  Rematerialize all stale downstream assets.
  """
  def rematerialize_stale(asset, partition) do
    stale = invalidate_downstream(asset, partition)

    Enum.map(stale, fn entry ->
      FlowStone.materialize(entry.asset, partition: entry.partition, force: true)
    end)
  end
end
```

## Consequences

### Positive

1. **Complete Traceability**: Every output can be traced to its sources.
2. **Impact Analysis**: Know what breaks before making changes.
3. **Audit Compliance**: Detailed records for regulatory requirements.
4. **Debugging**: Understand data flow when investigating issues.
5. **Reproducibility**: Reconstruct exact inputs that produced an output.

### Negative

1. **Storage Growth**: Lineage records accumulate over time.
2. **Query Complexity**: Recursive CTEs can be slow for deep graphs.
3. **Maintenance**: Need retention policies for old lineage data.

## References

- Dagster Asset Lineage: https://docs.dagster.io/concepts/assets/asset-graph
- Apache Atlas: https://atlas.apache.org/
- Data Lineage Best Practices: https://www.dataversity.net/data-lineage-best-practices/
