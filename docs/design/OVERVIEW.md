# FlowStone Design Overview

This document provides a high-level overview of FlowStone's architecture and design principles.

## Core Concepts

### 1. Assets

An **asset** is a persistent, versioned data artifact. Assets are the fundamental building block of FlowStone.

```elixir
asset :user_metrics do
  description "Daily user engagement metrics"
  depends_on [:raw_events, :user_profiles]
  io_manager :postgres
  table "analytics.user_metrics"
  partitioned_by :date

  execute fn context, %{raw_events: events, user_profiles: profiles} ->
    metrics = compute_metrics(events, profiles, context.partition)
    {:ok, metrics}
  end
end
```

Key properties:
- **Name**: Unique identifier (atom)
- **Dependencies**: Other assets this asset depends on
- **I/O Manager**: Where/how to store the asset's data
- **Partition**: How to slice the data (date, tenant, etc.)
- **Execute Function**: How to compute the asset's value

### 2. Materialization

**Materialization** is the act of computing and storing an asset's value for a specific partition.

```
Materialization = Asset + Partition → Stored Value
```

Each materialization is recorded with:
- Status (pending, running, success, failed, waiting_approval)
- Timing (started_at, completed_at, duration_ms)
- Lineage (upstream assets and their partitions)
- Metadata (hash, size, execution node, etc.)

### 3. DAG (Directed Acyclic Graph)

The **DAG** is automatically constructed from asset dependencies:

```
raw_events ─────┐
                ├──→ cleaned_events ──→ daily_report
user_profiles ──┘
```

FlowStone uses the Runic library for DAG operations:
- Topological sorting (execution order)
- Cycle detection (at compile time)
- Dependency traversal

### 4. Partitioning

**Partitions** divide an asset's data space:

```elixir
# Time-based partitioning
partitioned_by :date
# Each day is a separate partition: ~D[2025-01-15]

# Custom partitioning (tenant x region x date)
partitioned_by :custom
partition_fn fn config ->
  for tenant <- config.tenants,
      region <- tenant.regions,
      date <- config.date_range do
    {tenant.id, region.id, date}
  end
end
```

### 5. I/O Managers

**I/O Managers** abstract storage backends:

| Manager | Use Case |
|---------|----------|
| `:memory` | Testing |
| `:postgres` | Structured data |
| `:s3` | Object storage |
| `:parquet` | Analytics/Data science |
| Custom | Any storage system |

Each manager implements `load/3`, `store/4`, `delete/3`.

### 6. Checkpoints

**Checkpoints** pause workflow execution for approval:

```elixir
checkpoint :quality_review do
  depends_on [:generated_content]

  condition fn _context, %{generated_content: content} ->
    content.confidence_score < 0.9
  end

  on_approve fn _context, deps, _approval ->
    {:ok, deps.generated_content}
  end

  on_reject fn _context, _deps, approval ->
    {:error, {:rejected, approval.reason}}
  end
end
```

Checkpoints support:
- Conditional triggering
- Configurable timeouts
- Escalation
- Modification before approval

### 7. Resources

**Resources** are external dependencies injected into assets:

```elixir
# Define a resource
defmodule MyApp.Resources.Database do
  use FlowStone.Resource

  def setup(config) do
    {:ok, pool} = DBConnection.start_link(config)
    {:ok, pool}
  end

  def health_check(pool) do
    case DBConnection.execute(pool, "SELECT 1", []) do
      {:ok, _} -> :healthy
      {:error, _} -> {:unhealthy, :connection_failed}
    end
  end
end

# Use in asset
asset :db_data do
  requires [:database]

  execute fn context, _deps ->
    db = context.resources[:database]
    {:ok, query_data(db)}
  end
end
```

### 8. Lineage

**Lineage** tracks data provenance:

```elixir
# Upstream: What did this asset consume?
FlowStone.Lineage.upstream(:daily_report, ~D[2025-01-15])
# => [
#   %{asset: :cleaned_events, partition: ~D[2025-01-15], depth: 1},
#   %{asset: :raw_events, partition: ~D[2025-01-15], depth: 2}
# ]

# Downstream: What consumes this asset?
FlowStone.Lineage.downstream(:raw_events, ~D[2025-01-15])

# Impact: What needs recomputation if this changes?
FlowStone.Lineage.impact(:raw_events, ~D[2025-01-15])
```

## Architecture Layers

```
┌─────────────────────────────────────────────────────────┐
│                    User Application                      │
│  (Asset definitions, business logic, custom I/O managers)│
└────────────────────────────┬────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────┐
│                   FlowStone Core API                     │
│  materialize/2, schedule/2, lineage/2, checkpoint/1      │
└────────────────────────────┬────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────┐
│                   Component Layer                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐ │
│  │  Asset   │  │   DAG    │  │ Executor │  │   I/O    │ │
│  │  Engine  │  │ (Runic)  │  │  (Oban)  │  │ Managers │ │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘ │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐ │
│  │ Lineage  │  │ Scheduler│  │ Sensors  │  │Checkpoint│ │
│  │ Tracker  │  │          │  │          │  │ Manager  │ │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘ │
└────────────────────────────┬────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────┐
│                  Persistence Layer                       │
│     PostgreSQL (Ecto) + S3 + Custom I/O Managers         │
└────────────────────────────┬────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────┐
│                      UI Layer                            │
│              Phoenix LiveView Dashboard                  │
└─────────────────────────────────────────────────────────┘
```

## Execution Flow

```
1. User calls FlowStone.materialize(:my_asset, partition: ~D[2025-01-15])

2. FlowStone builds execution plan from DAG
   - Resolve all dependencies
   - Topologically sort for execution order

3. For each asset in order:
   a. Check if already materialized (skip if not force)
   b. Load dependencies from I/O managers
   c. Build context (partition, resources, run_id)
   d. Execute asset function
   e. Store result via I/O manager
   f. Record materialization metadata
   g. Record lineage entries
   h. If checkpoint, pause and wait for approval

4. Return result to user
```

## Design Principles

### 1. Elixir DSL, Not YAML

```elixir
# YES: Compile-time validated Elixir
asset :my_asset do
  depends_on [:other_asset]
  execute fn context, deps -> ... end
end

# NO: Runtime-parsed YAML with string keys
# steps:
#   - name: my_step
#     type: transform
```

### 2. Dependency Injection, Not Global State

```elixir
# YES: Resources injected via context
execute fn context, deps ->
  db = context.resources[:database]
  db.query(...)
end

# NO: Global lookup
execute fn _context, _deps ->
  db = Application.get_env(:my_app, :database)
  db.query(...)
end
```

### 3. Structured Errors, Not Blanket Rescue

```elixir
# YES: Typed errors with retry intelligence
{:error, %FlowStone.Error{type: :io_error, retryable: true}}

# NO: Generic catch-all
rescue
  error -> {:error, inspect(error)}
```

### 4. Explicit Over Implicit

```elixir
# YES: Explicit dependencies and resources
asset :report do
  depends_on [:data]
  requires [:api_client]
  ...
end

# NO: Hidden dependencies discovered at runtime
```

## Technology Stack

| Component | Library | Purpose |
|-----------|---------|---------|
| DAG Engine | Runic | Dependency resolution |
| Job Queue | Oban | Reliable job execution |
| Persistence | Ecto | Database access |
| Web UI | Phoenix LiveView | Real-time dashboard |
| PubSub | Phoenix.PubSub | Event broadcasting |
| Telemetry | :telemetry | Observability |

## Next Steps

See the [ADR index](../adr/README.md) for detailed documentation of each design decision.
