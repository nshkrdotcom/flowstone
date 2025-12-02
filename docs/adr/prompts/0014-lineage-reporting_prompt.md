# Implementation Prompt: ADR-0014 Lineage and Audit Reporting

## Objective

Implement comprehensive data lineage tracking, audit reporting, and point-in-time queries using PostgreSQL recursive CTEs with TDD using Supertester.

## Required Reading

1. **ADR-0014**: `docs/adr/0014-lineage-reporting.md`
2. **ADR-0011**: `docs/adr/0011-observability-telemetry.md` (audit log dependency)
3. **PostgreSQL Recursive CTEs**: https://www.postgresql.org/docs/current/queries-with.html
4. **Supertester Manual**: https://hexdocs.pm/supertester

## Context

Organizations need to answer critical questions:
- "Where did this data come from?" (upstream lineage)
- "What is affected if this source changes?" (downstream impact)
- "Who approved this output?" (audit trail)
- "What was the state at a specific point in time?" (time travel)

Requirements:
- Full upstream/downstream lineage traversal
- Impact analysis for changes
- Audit reports for compliance
- Point-in-time queries for debugging
- Invalidation and rematerialization

## Implementation Tasks

### 1. Lineage Entry Schema

```elixir
# lib/flowstone/lineage/entry.ex
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

### 2. Lineage Recorder

```elixir
# lib/flowstone/lineage/recorder.ex
defmodule FlowStone.Lineage.Recorder do
  def record_consumption(context, deps)
  defp serialize_partition(partition)
  defp get_partition(dep_data)
  defp get_materialization_id(dep_asset, dep_data)
end
```

### 3. Lineage Query API

```elixir
# lib/flowstone/lineage.ex
defmodule FlowStone.Lineage do
  @doc "Get all upstream assets (recursive)"
  def upstream(asset, partition, opts \\ [])

  @doc "Get all downstream assets (recursive)"
  def downstream(asset, partition, opts \\ [])

  @doc "Calculate impact: what needs recomputation"
  def impact(asset, partition)

  @doc "Get complete lineage graph for visualization"
  def graph(asset, partition)

  @doc "Point-in-time lineage query"
  def at(asset, partition, timestamp)
end
```

### 4. Audit Report Generator

```elixir
# lib/flowstone/reports/audit_report.ex
defmodule FlowStone.Reports.AuditReport do
  @doc "Generate complete audit report"
  def generate(asset, partition)

  @doc "Export audit report to JSON"
  def to_json(report)

  @doc "Export audit report to PDF"
  def to_pdf(report, output_path)

  defp list_checkpoints_for_run(run_id)
end
```

### 5. Invalidation API

```elixir
# lib/flowstone/lineage/invalidation.ex
defmodule FlowStone.Lineage.Invalidation do
  @doc "Invalidate all downstream assets"
  def invalidate_downstream(asset, partition)

  @doc "Rematerialize all stale downstream assets"
  def rematerialize_stale(asset, partition)
end
```

### 6. Time Machine

```elixir
# lib/flowstone/lineage/time_machine.ex
defmodule FlowStone.Lineage.TimeMachine do
  @doc "Reconstruct lineage at specific point in time"
  def at(asset, partition, timestamp)
end
```

## Test Design with Supertester

### Lineage Recording Tests

```elixir
defmodule FlowStone.Lineage.RecorderTest do
  use FlowStone.DataCase, async: true

  alias FlowStone.Lineage.Recorder

  describe "record_consumption/2" do
    test "records dependency consumption" do
      context = %FlowStone.Context{
        asset: :downstream,
        partition: ~D[2025-01-15],
        run_id: Ecto.UUID.generate()
      }

      deps = %{
        upstream1: %{data: [1, 2, 3], partition: ~D[2025-01-15]},
        upstream2: %{data: [4, 5, 6], partition: ~D[2025-01-14]}
      }

      Recorder.record_consumption(context, deps)

      entries = Repo.all(FlowStone.Lineage.Entry)
      assert length(entries) == 2

      entry1 = Enum.find(entries, &(&1.upstream_asset == "upstream1"))
      assert entry1.asset_name == "downstream"
      assert entry1.partition == "2025-01-15"
      assert entry1.upstream_partition == "2025-01-15"

      entry2 = Enum.find(entries, &(&1.upstream_asset == "upstream2"))
      assert entry2.upstream_partition == "2025-01-14"
    end

    test "includes materialization IDs" do
      mat1 = create_materialization(%{
        asset_name: "upstream",
        partition: "2025-01-15",
        status: :success
      })

      context = %FlowStone.Context{
        asset: :downstream,
        partition: ~D[2025-01-15],
        run_id: Ecto.UUID.generate()
      }

      deps = %{
        upstream: %{
          data: :test_data,
          partition: ~D[2025-01-15],
          materialization_id: mat1.id
        }
      }

      Recorder.record_consumption(context, deps)

      entry = Repo.one!(FlowStone.Lineage.Entry)
      assert entry.upstream_materialization_id == mat1.id
    end

    test "records consumption timestamp" do
      before = DateTime.utc_now()

      Recorder.record_consumption(
        %FlowStone.Context{
          asset: :test,
          partition: ~D[2025-01-15],
          run_id: Ecto.UUID.generate()
        },
        %{dep: %{data: :data, partition: ~D[2025-01-15]}}
      )

      after_time = DateTime.utc_now()

      entry = Repo.one!(FlowStone.Lineage.Entry)
      assert DateTime.compare(entry.consumed_at, before) in [:gt, :eq]
      assert DateTime.compare(entry.consumed_at, after_time) in [:lt, :eq]
    end
  end
end
```

### Upstream Lineage Tests

```elixir
defmodule FlowStone.Lineage.UpstreamTest do
  use FlowStone.DataCase, async: true

  alias FlowStone.Lineage

  describe "upstream/3" do
    test "returns direct dependencies" do
      # Create lineage: source -> transform -> report
      create_lineage_entry(%{
        asset_name: "transform",
        partition: "p1",
        upstream_asset: "source",
        upstream_partition: "p1"
      })

      create_lineage_entry(%{
        asset_name: "report",
        partition: "p1",
        upstream_asset: "transform",
        upstream_partition: "p1"
      })

      upstream = Lineage.upstream(:report, "p1", depth: 1)

      assert length(upstream) == 1
      assert hd(upstream).asset == :transform
    end

    test "recursively traverses dependencies" do
      # Create chain: a -> b -> c -> d
      create_lineage_entry(%{
        asset_name: "b",
        upstream_asset: "a",
        partition: "p1",
        upstream_partition: "p1"
      })

      create_lineage_entry(%{
        asset_name: "c",
        upstream_asset: "b",
        partition: "p1",
        upstream_partition: "p1"
      })

      create_lineage_entry(%{
        asset_name: "d",
        upstream_asset: "c",
        partition: "p1",
        upstream_partition: "p1"
      })

      upstream = Lineage.upstream(:d, "p1")

      assert length(upstream) == 3
      assert Enum.any?(upstream, &(&1.asset == :a))
      assert Enum.any?(upstream, &(&1.asset == :b))
      assert Enum.any?(upstream, &(&1.asset == :c))
    end

    test "handles diamond dependencies" do
      # Create diamond: source -> left -> sink
      #                  source -> right -> sink
      create_lineage_entry(%{
        asset_name: "left",
        upstream_asset: "source",
        partition: "p1",
        upstream_partition: "p1"
      })

      create_lineage_entry(%{
        asset_name: "right",
        upstream_asset: "source",
        partition: "p1",
        upstream_partition: "p1"
      })

      create_lineage_entry(%{
        asset_name: "sink",
        upstream_asset: "left",
        partition: "p1",
        upstream_partition: "p1"
      })

      create_lineage_entry(%{
        asset_name: "sink",
        upstream_asset: "right",
        partition: "p1",
        upstream_partition: "p1"
      })

      upstream = Lineage.upstream(:sink, "p1")

      assert length(upstream) == 3  # source, left, right (no duplicates)
      assets = Enum.map(upstream, & &1.asset)
      assert :source in assets
      assert :left in assets
      assert :right in assets
    end

    test "respects depth limit" do
      # Chain: a -> b -> c -> d
      create_lineage_chain(["a", "b", "c", "d"], "p1")

      upstream = Lineage.upstream(:d, "p1", depth: 2)

      assert length(upstream) == 2
      assets = Enum.map(upstream, & &1.asset)
      assert :c in assets
      assert :b in assets
      refute :a in assets
    end

    test "includes depth in results" do
      create_lineage_chain(["a", "b", "c"], "p1")

      upstream = Lineage.upstream(:c, "p1")

      entry_b = Enum.find(upstream, &(&1.asset == :b))
      entry_a = Enum.find(upstream, &(&1.asset == :a))

      assert entry_b.depth == 1
      assert entry_a.depth == 2
    end
  end

  defp create_lineage_chain(assets, partition) do
    assets
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [upstream, downstream] ->
      create_lineage_entry(%{
        asset_name: downstream,
        upstream_asset: upstream,
        partition: partition,
        upstream_partition: partition
      })
    end)
  end
end
```

### Downstream Lineage Tests

```elixir
defmodule FlowStone.Lineage.DownstreamTest do
  use FlowStone.DataCase, async: true

  alias FlowStone.Lineage

  describe "downstream/3" do
    test "returns direct dependents" do
      create_lineage_entry(%{
        asset_name: "dependent",
        upstream_asset: "source",
        partition: "p1",
        upstream_partition: "p1"
      })

      downstream = Lineage.downstream(:source, "p1", depth: 1)

      assert length(downstream) == 1
      assert hd(downstream).asset == :dependent
    end

    test "recursively traverses dependents" do
      # Chain: a -> b -> c -> d
      create_lineage_chain(["a", "b", "c", "d"], "p1")

      downstream = Lineage.downstream(:a, "p1")

      assert length(downstream) == 3
      assets = Enum.map(downstream, & &1.asset)
      assert :b in assets
      assert :c in assets
      assert :d in assets
    end

    test "handles multiple dependents" do
      # Fan-out: source -> dep1
      #          source -> dep2
      #          source -> dep3
      create_lineage_entry(%{
        asset_name: "dep1",
        upstream_asset: "source",
        partition: "p1",
        upstream_partition: "p1"
      })

      create_lineage_entry(%{
        asset_name: "dep2",
        upstream_asset: "source",
        partition: "p1",
        upstream_partition: "p1"
      })

      create_lineage_entry(%{
        asset_name: "dep3",
        upstream_asset: "source",
        partition: "p1",
        upstream_partition: "p1"
      })

      downstream = Lineage.downstream(:source, "p1")

      assert length(downstream) == 3
      assets = Enum.map(downstream, & &1.asset)
      assert :dep1 in assets
      assert :dep2 in assets
      assert :dep3 in assets
    end
  end

  defp create_lineage_chain(assets, partition) do
    assets
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [upstream, downstream] ->
      create_lineage_entry(%{
        asset_name: downstream,
        upstream_asset: upstream,
        partition: partition,
        upstream_partition: partition
      })
    end)
  end
end
```

### Impact Analysis Tests

```elixir
defmodule FlowStone.Lineage.ImpactTest do
  use FlowStone.DataCase, async: true

  alias FlowStone.Lineage

  describe "impact/2" do
    test "returns all affected assets with status" do
      # Create chain with materializations
      create_lineage_chain(["source", "transform", "report"], "p1")

      create_materialization(%{
        asset_name: "transform",
        partition: "p1",
        status: :success
      })

      create_materialization(%{
        asset_name: "report",
        partition: "p1",
        status: :success
      })

      impact = Lineage.impact(:source, "p1")

      assert length(impact) == 2
      transform = Enum.find(impact, &(&1.asset == :transform))
      report = Enum.find(impact, &(&1.asset == :report))

      assert transform.status == :success
      assert report.status == :success
    end

    test "identifies assets that need rematerialization" do
      create_lineage_chain(["source", "stale_asset"], "p1")

      create_materialization(%{
        asset_name: "stale_asset",
        partition: "p1",
        status: :stale
      })

      impact = Lineage.impact(:source, "p1")

      stale = Enum.find(impact, &(&1.asset == :stale_asset))
      assert stale.status == :stale
    end
  end

  defp create_lineage_chain(assets, partition) do
    assets
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [upstream, downstream] ->
      create_lineage_entry(%{
        asset_name: downstream,
        upstream_asset: upstream,
        partition: partition,
        upstream_partition: partition
      })
    end)
  end
end
```

### Lineage Graph Tests

```elixir
defmodule FlowStone.Lineage.GraphTest do
  use FlowStone.DataCase, async: true

  alias FlowStone.Lineage

  describe "graph/2" do
    test "returns nodes and edges for visualization" do
      # Create diamond graph
      create_lineage_entry(%{
        asset_name: "left",
        upstream_asset: "source",
        partition: "p1",
        upstream_partition: "p1"
      })

      create_lineage_entry(%{
        asset_name: "right",
        upstream_asset: "source",
        partition: "p1",
        upstream_partition: "p1"
      })

      create_lineage_entry(%{
        asset_name: "sink",
        upstream_asset: "left",
        partition: "p1",
        upstream_partition: "p1"
      })

      create_lineage_entry(%{
        asset_name: "sink",
        upstream_asset: "right",
        partition: "p1",
        upstream_partition: "p1"
      })

      graph = Lineage.graph(:sink, "p1")

      # Check nodes
      assert length(graph.nodes) == 4
      node_assets = Enum.map(graph.nodes, & &1.asset)
      assert :source in node_assets
      assert :left in node_assets
      assert :right in node_assets
      assert :sink in node_assets

      # Check edges
      assert length(graph.edges) >= 4
      assert %{from: "source", to: "left"} in graph.edges
      assert %{from: "source", to: "right"} in graph.edges
      assert %{from: "left", to: "sink"} in graph.edges
      assert %{from: "right", to: "sink"} in graph.edges
    end
  end
end
```

### Audit Report Tests

```elixir
defmodule FlowStone.Reports.AuditReportTest do
  use FlowStone.DataCase, async: true

  alias FlowStone.Reports.AuditReport

  describe "generate/2" do
    test "generates comprehensive audit report" do
      # Setup: materialization with lineage and approvals
      run_id = Ecto.UUID.generate()

      mat = create_materialization(%{
        asset_name: "audited_asset",
        partition: "p1",
        run_id: run_id,
        status: :success,
        started_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        completed_at: DateTime.utc_now(),
        metadata: %{
          duration_ms: 3600,
          execution_node: "node1",
          output_hash: "abc123"
        }
      })

      create_lineage_entry(%{
        asset_name: "audited_asset",
        upstream_asset: "source",
        partition: "p1",
        upstream_partition: "p1",
        run_id: run_id
      })

      create_approval(%{
        run_id: run_id,
        checkpoint_name: "quality_review",
        status: :approved,
        decision_by: "user123"
      })

      report = AuditReport.generate(:audited_asset, "p1")

      # Verify report structure
      assert report.asset == :audited_asset
      assert report.partition == "p1"
      assert report.execution.run_id == run_id
      assert report.execution.status == :success
      assert report.execution.duration_ms == 3600

      # Verify lineage section
      assert report.lineage.upstream_count == 1
      assert length(report.lineage.upstream_assets) == 1

      upstream = hd(report.lineage.upstream_assets)
      assert upstream.asset == :source

      # Verify approvals section
      assert length(report.approvals) == 1
      approval = hd(report.approvals)
      assert approval.checkpoint == "quality_review"
      assert approval.status == :approved
      assert approval.decided_by == "user123"

      # Verify data quality section
      assert report.data_quality.output_hash == "abc123"
    end
  end

  describe "to_json/1" do
    test "exports report to JSON" do
      report = %{
        asset: :test_asset,
        partition: "p1",
        generated_at: DateTime.utc_now(),
        execution: %{run_id: Ecto.UUID.generate()}
      }

      json = AuditReport.to_json(report)

      assert is_binary(json)
      decoded = Jason.decode!(json)
      assert decoded["asset"] == "test_asset"
      assert decoded["partition"] == "p1"
    end
  end
end
```

### Time Machine Tests

```elixir
defmodule FlowStone.Lineage.TimeMachineTest do
  use FlowStone.DataCase, async: true

  alias FlowStone.Lineage.TimeMachine

  describe "at/3" do
    test "reconstructs lineage at specific point in time" do
      # First materialization at t1
      t1 = DateTime.add(DateTime.utc_now(), -7200, :second)

      mat1 = create_materialization(%{
        asset_name: "asset",
        partition: "p1",
        run_id: Ecto.UUID.generate(),
        completed_at: t1
      })

      create_lineage_entry(%{
        asset_name: "asset",
        upstream_asset: "source_v1",
        partition: "p1",
        upstream_partition: "p1",
        run_id: mat1.run_id
      })

      # Second materialization at t2
      t2 = DateTime.add(DateTime.utc_now(), -3600, :second)

      mat2 = create_materialization(%{
        asset_name: "asset",
        partition: "p1",
        run_id: Ecto.UUID.generate(),
        completed_at: t2
      })

      create_lineage_entry(%{
        asset_name: "asset",
        upstream_asset: "source_v2",
        partition: "p1",
        upstream_partition: "p1",
        run_id: mat2.run_id
      })

      # Query at time between t1 and t2
      query_time = DateTime.add(t1, 1800, :second)

      {:ok, result} = TimeMachine.at(:asset, "p1", query_time)

      # Should return mat1 (active at query time)
      assert result.materialization.id == mat1.id
      assert length(result.lineage) == 1
      assert hd(result.lineage).upstream_asset == "source_v1"
    end

    test "returns error when asset didn't exist at timestamp" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert {:error, :not_found} = TimeMachine.at(:nonexistent, "p1", future)
    end
  end
end
```

### Invalidation Tests

```elixir
defmodule FlowStone.Lineage.InvalidationTest do
  use FlowStone.DataCase, async: true

  alias FlowStone.Lineage.Invalidation

  describe "invalidate_downstream/2" do
    test "marks downstream materializations as stale" do
      create_lineage_chain(["source", "transform", "report"], "p1")

      create_materialization(%{
        asset_name: "transform",
        partition: "p1",
        status: :success
      })

      create_materialization(%{
        asset_name: "report",
        partition: "p1",
        status: :success
      })

      invalidated = Invalidation.invalidate_downstream(:source, "p1")

      assert length(invalidated) == 2

      # Verify status changed to stale
      {:ok, transform} = FlowStone.Materialization.Store.get("transform", "p1")
      {:ok, report} = FlowStone.Materialization.Store.get("report", "p1")

      assert transform.status == :stale
      assert report.status == :stale
    end
  end

  describe "rematerialize_stale/2" do
    test "triggers rematerialization of stale assets" do
      create_lineage_chain(["source", "stale_asset"], "p1")

      create_materialization(%{
        asset_name: "stale_asset",
        partition: "p1",
        status: :stale
      })

      jobs = Invalidation.rematerialize_stale(:source, "p1")

      assert length(jobs) == 1
      # Verify Oban job was created (if using Oban)
    end
  end

  defp create_lineage_chain(assets, partition) do
    assets
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [upstream, downstream] ->
      create_lineage_entry(%{
        asset_name: downstream,
        upstream_asset: upstream,
        partition: partition,
        upstream_partition: partition
      })
    end)
  end
end
```

## Implementation Order

1. **Lineage schema + migration** - Data model for lineage tracking
2. **Lineage recorder** - Record dependency consumption
3. **Upstream query** - Recursive CTE for upstream traversal
4. **Downstream query** - Recursive CTE for downstream traversal
5. **Impact analysis** - Identify affected assets
6. **Lineage graph** - Complete graph for visualization
7. **Audit report generator** - Comprehensive audit reports
8. **Time machine** - Point-in-time queries
9. **Invalidation API** - Mark and rematerialize stale assets

## Success Criteria

- [ ] Lineage entries recorded during materialization
- [ ] Upstream query handles diamond dependencies
- [ ] Downstream query supports depth limits
- [ ] Impact analysis includes materialization status
- [ ] Audit reports include all required sections
- [ ] Time machine reconstructs historical lineage
- [ ] Invalidation marks all downstream as stale
- [ ] PostgreSQL recursive CTEs perform efficiently
- [ ] Lineage graph suitable for visualization

## Commands

```bash
# Run lineage tests
mix test test/flowstone/lineage/

# Run recorder tests
mix test test/flowstone/lineage/recorder_test.exs

# Run upstream/downstream tests
mix test test/flowstone/lineage/upstream_test.exs
mix test test/flowstone/lineage/downstream_test.exs

# Run audit report tests
mix test test/flowstone/reports/audit_report_test.exs

# Run time machine tests
mix test test/flowstone/lineage/time_machine_test.exs

# Run invalidation tests
mix test test/flowstone/lineage/invalidation_test.exs

# Check coverage
mix coveralls.html
```

## Spawn Subagents

1. **Lineage schema** - Database model and migration
2. **Lineage recorder** - Dependency consumption tracking
3. **Upstream/downstream queries** - Recursive CTE implementation
4. **Impact analysis** - Affected asset identification
5. **Audit report generator** - Compliance reporting
6. **Time machine** - Point-in-time queries
7. **Invalidation API** - Stale asset management
