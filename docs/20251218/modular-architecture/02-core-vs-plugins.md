# Core vs. Plugins: Module Placement Guide

**Status:** Design Proposal
**Date:** 2025-12-18

## 1. Decision Framework

### 1.1 Core Inclusion Criteria

A module belongs in **core** if it meets ALL of these criteria:

| Criterion | Question | Example |
|-----------|----------|---------|
| Essential | Can FlowStone function without it? | `Executor` - No |
| Abstract | Does it define interfaces, not implementations? | `IO.Manager` behavior |
| Zero-External | Does it avoid external service calls? | `DAG` - pure graph logic |
| Framework-Agnostic | Is it independent of specific frameworks? | `Asset` struct |

### 1.2 Plugin Extraction Criteria

A module belongs in a **plugin** if it meets ANY of these criteria:

| Criterion | Question | Example |
|-----------|----------|---------|
| External Service | Does it call AWS, databases, etc.? | `IO.S3` |
| Optional Feature | Can users opt out entirely? | `Scatter` |
| Provider-Specific | Is it one of many possible implementations? | `ItemReaders.DynamoDB` |
| Heavy Dependencies | Does it pull in large transitive deps? | ExAws |

### 1.3 Integration Layer Criteria

A module belongs in an **integration layer** if:

- It bridges FlowStone with another framework
- It depends on both FlowStone AND that framework
- It translates concepts between the two systems

## 2. Current Module Categorization

### 2.1 Core (78 modules today → ~25 in modular future)

```elixir
# DEFINITELY CORE - Essential execution
FlowStone                      # API facade
FlowStone.Pipeline             # DSL macros
FlowStone.Asset                # Asset struct
FlowStone.DAG                  # Graph construction
FlowStone.Executor             # Orchestration
FlowStone.Materializer         # Function execution
FlowStone.Context              # Runtime context
FlowStone.Registry             # Asset lookup
FlowStone.Partition            # Serialization
FlowStone.Error                # Error types
FlowStone.Application          # Supervision tree
FlowStone.RunConfig            # Runtime config

# CORE BEHAVIORS - Interface definitions
FlowStone.IO.Manager           # I/O abstraction
FlowStone.Scatter.ItemReader   # Reader abstraction
FlowStone.Scatter.Coordinator  # Scatter abstraction
FlowStone.Parallel.Coordinator # Parallel abstraction

# CORE REGISTRIES - Runtime resolution
FlowStone.IO.Registry
FlowStone.Scatter.ReaderRegistry
FlowStone.Plugin.Registry

# CORE FALLBACK - Built-in default
FlowStone.IO.Memory            # No-dependency I/O
```

### 2.2 Plugin: flowstone_scatter

```elixir
# EXTRACT TO flowstone_scatter
FlowStone.Scatter              # Orchestration (1159 lines)
FlowStone.Scatter.Barrier      # Ecto schema
FlowStone.Scatter.Result       # Ecto schema
FlowStone.Scatter.Key          # Key normalization
FlowStone.Scatter.Options      # Options struct
FlowStone.Scatter.BatchOptions # Batching config
FlowStone.Scatter.Batcher      # Grouping logic
FlowStone.Workers.ScatterWorker
FlowStone.Workers.ScatterBatchWorker
FlowStone.Workers.ItemReaderWorker
```

**Why Plugin:**
- Requires Ecto (database)
- Requires Oban (job queue)
- Optional feature (not all assets use scatter)
- Heavy - 1159 lines of orchestration logic

### 2.3 Plugin: flowstone_parallel

```elixir
# EXTRACT TO flowstone_parallel
FlowStone.Parallel             # Orchestration
FlowStone.Parallel.Execution   # Ecto schema
FlowStone.Parallel.Branch      # Ecto schema
FlowStone.ParallelBranch       # DSL struct
FlowStone.Workers.ParallelJoinWorker
```

**Why Plugin:**
- Requires Ecto (database)
- Requires Oban (job queue)
- Optional feature

### 2.4 Plugin: flowstone_routing

```elixir
# EXTRACT TO flowstone_routing
FlowStone.RouteDecision        # Ecto schema
FlowStone.RouteDecisions       # Lifecycle helpers
```

**Why Plugin:**
- Requires Ecto
- Can be stubbed for non-routing pipelines

### 2.5 Plugin: flowstone_io_postgres

```elixir
# EXTRACT TO flowstone_io_postgres
FlowStone.IO.Postgres          # IO.Manager implementation
```

### 2.6 Plugin: flowstone_io_s3

```elixir
# EXTRACT TO flowstone_io_s3
FlowStone.IO.S3                # IO.Manager implementation
```

### 2.7 Plugin: flowstone_io_parquet

```elixir
# EXTRACT TO flowstone_io_parquet
FlowStone.IO.Parquet           # IO.Manager implementation
```

### 2.8 Plugin: flowstone_readers_aws

```elixir
# EXTRACT TO flowstone_readers_aws
FlowStone.Scatter.ItemReaders.S3
FlowStone.Scatter.ItemReaders.DynamoDB
```

### 2.9 Plugin: flowstone_readers_postgres

```elixir
# EXTRACT TO flowstone_readers_postgres
FlowStone.Scatter.ItemReaders.Postgres
```

### 2.10 Plugin: flowstone_signal_gate

```elixir
# EXTRACT TO flowstone_signal_gate
FlowStone.SignalGate           # Durable suspension
FlowStone.SignalGate.Gate      # Ecto schema
FlowStone.SignalGate.Token     # Token generation
FlowStone.Workers.SignalGateTimeoutWorker
```

**Why Plugin:**
- Requires Ecto
- Specialized feature for webhook flows
- Self-contained with minimal Materializer hooks (~10 lines)

### 2.11 Plugin: flowstone_scheduling

```elixir
# EXTRACT TO flowstone_scheduling
FlowStone.Schedule             # Schedule struct
FlowStone.ScheduleStore        # Agent-based storage
FlowStone.Schedules.Scheduler  # Cron scheduler
FlowStone.Sensors.*            # Sensor implementations
```

**Why Plugin:**
- Requires Crontab library
- Optional feature
- Self-contained scheduling logic

### 2.12 Plugin: flowstone_observability

```elixir
# EXTRACT TO flowstone_observability
FlowStone.Telemetry            # Event emission
FlowStone.TelemetryMetrics     # Prometheus metrics
FlowStone.Logger               # Structured logging
FlowStone.AuditLog             # Ecto schema
FlowStone.AuditLogContext      # Audit helpers
FlowStone.ErrorRecorder        # Error persistence
```

**Why Plugin:**
- Optional observability stack
- Requires telemetry_metrics_prometheus
- Users may want different observability

### 2.13 Plugin: flowstone_lineage

```elixir
# EXTRACT TO flowstone_lineage
FlowStone.Lineage              # GenServer lineage tracker
FlowStone.Lineage.Entry        # Ecto schema
FlowStone.Lineage.Invalidation # Cascade logic
FlowStone.LineagePersistence   # Persistence helpers
```

**Why Plugin:**
- Requires Ecto
- Optional feature
- Users may use external lineage systems

### 2.14 Plugin: flowstone_checkpoints

```elixir
# EXTRACT TO flowstone_checkpoints
FlowStone.Checkpoint           # Ecto schema
FlowStone.Checkpoint.Notifier  # Notifications
FlowStone.Approval             # Ecto schema
FlowStone.Approvals            # Approval lifecycle
FlowStone.Workers.CheckpointTimeout
```

**Why Plugin:**
- Requires Ecto
- Human-in-the-loop features are optional
- Self-contained approval flow

### 2.15 Remaining Core Infrastructure

```elixir
# STAYS IN CORE (support modules)
FlowStone.Materialization      # Ecto schema - Core execution tracking
FlowStone.Materializations     # Lifecycle helpers
FlowStone.MaterializationStore # Optional cache
FlowStone.MaterializationContext
FlowStone.Result               # Compression helpers
FlowStone.RateLimiter          # Hammer wrapper
FlowStone.PubSub               # Phoenix.PubSub wrapper
FlowStone.Health               # Health check
FlowStone.ObanHelpers          # Oban utilities
FlowStone.Backfill             # Partition generation
FlowStone.Resources            # Resource injection
FlowStone.Resource             # Resource behavior
```

## 3. Materializer Refactoring

The `Materializer` currently handles 4 execution paths:

```elixir
# Current: One function, many branches
def execute(asset, context, deps) do
  cond do
    parallel_asset?(asset) -> execute_parallel(...)
    router_asset?(asset) -> execute_router(...)
    routed_asset?(asset) -> execute_routed(...)
    true -> execute_normal(...)
  end
end
```

**Proposed: Dispatch to plugin coordinators**

```elixir
# New: Core Materializer with hooks
def execute(asset, context, deps) do
  case asset_type(asset) do
    :normal -> execute_normal(asset, context, deps)

    :parallel ->
      coord = get_coordinator(:parallel)
      coord.execute(asset, context, deps)

    :scatter ->
      coord = get_coordinator(:scatter)
      coord.execute(asset, context, deps)

    :router ->
      coord = get_coordinator(:routing)
      coord.execute_router(asset, context, deps)

    :routed ->
      coord = get_coordinator(:routing)
      coord.execute_routed(asset, context, deps)
  end
end

defp get_coordinator(type) do
  Application.get_env(:flowstone, :"#{type}_coordinator")
end
```

## 4. Scatter Module Decomposition

The 1159-line `Scatter` module should be split:

### 4.1 Core Behavior (in flowstone)

```elixir
defmodule FlowStone.Scatter.Coordinator do
  @callback create_barrier(run_id, asset, opts) :: {:ok, barrier_id} | error
  @callback insert_results(barrier_id, keys) :: :ok | error
  @callback complete(barrier_id, key, result) :: {:ok, status} | error
  @callback fail(barrier_id, key, error) :: {:ok, status} | error
  @callback gather(barrier_id) :: {:ok, results} | error
  @callback cancel(barrier_id) :: :ok | error
end
```

### 4.2 Plugin Implementation (in flowstone_scatter)

```elixir
defmodule FlowStone.Scatter.Impl do
  @behaviour FlowStone.Scatter.Coordinator

  # Full 1159-line implementation here
  # Uses Ecto, Oban, etc.
end
```

### 4.3 Registry Resolution (in flowstone)

```elixir
defmodule FlowStone.Scatter do
  @moduledoc "Delegates to configured coordinator"

  def create_barrier(run_id, asset, opts) do
    coordinator().create_barrier(run_id, asset, opts)
  end

  defp coordinator do
    Application.get_env(:flowstone, :scatter_coordinator, FlowStone.Scatter.Impl)
  end
end
```

## 5. Benefits of This Structure

### 5.1 For Core Users

- **Minimal dependencies**: Core FlowStone has no Ecto requirement
- **Fast compilation**: Less code to compile
- **Testable**: Can test core logic without database

### 5.2 For Plugin Users

- **Opt-in complexity**: Only add features you use
- **Clear boundaries**: Each plugin has single responsibility
- **Upgradable**: Plugins can version independently

### 5.3 For Contributors

- **Clear ownership**: Each plugin has clear scope
- **Easier PRs**: Changes localized to one plugin
- **Testing isolation**: Plugin tests don't need full stack

## 6. What Stays Coupled (By Design)

Some coupling is intentional and acceptable:

| Coupled Modules | Reason | Mitigation |
|-----------------|--------|------------|
| Executor ↔ Materializer | Core execution flow | Keep in same package |
| Materializer ↔ Coordinators | Dispatch point | Use behavior + registry |
| Context ↔ Resources | Runtime context | Resources is optional |
| Workers ↔ RunConfig | Oban serialization | Workers in plugin packages |

## 7. DSL Macro Locations

### 7.1 Core DSL (in flowstone)

```elixir
# Always available
asset :name do
  depends_on [...]
  execute fn ctx, deps -> ... end
end
```

### 7.2 Plugin DSL Extensions

Each plugin can extend the DSL by defining macros:

```elixir
# In flowstone_scatter
defmodule FlowStone.Scatter.DSL do
  defmacro scatter(do: block) do
    # Compiles scatter configuration
  end

  defmacro gather(fun) do
    # Sets gather function
  end
end

# In flowstone_parallel
defmodule FlowStone.Parallel.DSL do
  defmacro parallel(do: block) do
    # Compiles parallel configuration
  end

  defmacro branch(name, opts) do
    # Defines a branch
  end
end
```

### 7.3 User Pipeline with Plugins

```elixir
defmodule MyPipeline do
  use FlowStone.Pipeline

  # Optional: import plugin DSLs
  import FlowStone.Scatter.DSL
  import FlowStone.Parallel.DSL

  asset :process_items do
    scatter do
      keys fn deps -> deps.items end
      max_concurrent 50
    end

    execute fn ctx, deps -> process(ctx.scatter_key) end

    gather fn results -> summarize(results) end
  end
end
```
