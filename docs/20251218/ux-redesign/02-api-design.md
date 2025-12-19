# New API Design

**Status:** Design Proposal
**Date:** 2025-12-18

## Design Goals

1. **Minimal surface area** - Few functions to learn
2. **Consistent patterns** - Same conventions everywhere
3. **Progressive options** - Simple cases need no options
4. **Pipeline-centric** - Pipeline module is the primary handle
5. **Explicit behavior** - No hidden mode switching

---

## Core API

### FlowStone.run/2-3

**The primary entry point for executing assets.**

```elixir
@spec run(module(), atom()) :: {:ok, result} | {:error, reason}
@spec run(module(), atom(), keyword()) :: {:ok, result} | {:ok, Job.t()} | {:error, reason}

# Basic - synchronous, in-memory
{:ok, result} = FlowStone.run(MyPipeline, :asset)

# With partition
{:ok, result} = FlowStone.run(MyPipeline, :asset, partition: ~D[2025-01-15])

# Async (requires repo config)
{:ok, %Oban.Job{}} = FlowStone.run(MyPipeline, :asset, async: true)

# Force re-run (ignore cache)
{:ok, result} = FlowStone.run(MyPipeline, :asset, force: true)

# Custom storage
{:ok, result} = FlowStone.run(MyPipeline, :asset, storage: :s3)
```

**Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `partition` | `term()` | `:default` | Partition key for the run |
| `async` | `boolean()` | `false` | Run via Oban job queue |
| `force` | `boolean()` | `false` | Ignore cached results |
| `storage` | `atom()` | from config | Override storage backend |
| `with_deps` | `boolean()` | `true` | Also run missing dependencies |
| `timeout` | `pos_integer()` | `300_000` | Execution timeout (ms) |
| `priority` | `0..3` | `0` | Oban job priority (async only) |
| `scheduled_at` | `DateTime.t()` | `nil` | Schedule for later (async only) |

**Behavior:**

1. If `async: false` (default):
   - Executes synchronously in calling process
   - Returns `{:ok, result}` or `{:error, reason}`
   - Storage determined by config or option

2. If `async: true`:
   - Requires `repo` in config
   - Enqueues Oban job
   - Returns `{:ok, %Oban.Job{}}`
   - Result available via `FlowStone.get/3`

3. Dependencies:
   - By default (`with_deps: true`), runs all missing dependencies first
   - With `with_deps: false`, fails if dependencies not already materialized

---

### FlowStone.get/2-3

**Retrieve the result of a previously run asset.**

```elixir
@spec get(module(), atom()) :: {:ok, result} | {:error, :not_found}
@spec get(module(), atom(), keyword()) :: {:ok, result} | {:error, :not_found}

# Basic
{:ok, result} = FlowStone.get(MyPipeline, :asset)

# With partition
{:ok, result} = FlowStone.get(MyPipeline, :asset, partition: ~D[2025-01-15])

# Check if exists without loading
true = FlowStone.exists?(MyPipeline, :asset, partition: ~D[2025-01-15])
```

**Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `partition` | `term()` | `:default` | Partition key |
| `storage` | `atom()` | from config | Storage backend to check |

---

### FlowStone.backfill/3

**Run an asset across multiple partitions.**

```elixir
@spec backfill(module(), atom(), keyword()) ::
  {:ok, %{succeeded: integer(), failed: integer()}} | {:error, reason}

# Date range
{:ok, stats} = FlowStone.backfill(MyPipeline, :asset,
  partitions: Date.range(~D[2025-01-01], ~D[2025-01-31])
)

# Custom partitions
{:ok, stats} = FlowStone.backfill(MyPipeline, :asset,
  partitions: [:us, :eu, :asia]
)

# Parallel execution
{:ok, stats} = FlowStone.backfill(MyPipeline, :asset,
  partitions: Date.range(...),
  parallel: 4
)
```

**Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `partitions` | `Enum.t()` | required | Partitions to process |
| `parallel` | `pos_integer()` | `1` | Concurrent executions |
| `force` | `boolean()` | `false` | Re-run even if cached |
| `on_error` | `:continue \| :halt` | `:continue` | Error handling |
| `async` | `boolean()` | `false` | Enqueue all as Oban jobs |

---

### FlowStone.status/2-3

**Check the status of an asset run.**

```elixir
@spec status(module(), atom()) :: status_map()
@spec status(module(), atom(), keyword()) :: status_map()

status = FlowStone.status(MyPipeline, :asset)
# => %{
#   state: :completed | :running | :pending | :failed | :not_found,
#   partition: :default,
#   completed_at: ~U[2025-01-15 10:30:00Z],
#   duration_ms: 1234,
#   storage: :postgres
# }

# For scatter assets
status = FlowStone.status(MyPipeline, :scattered_asset)
# => %{
#   state: :running,
#   scatter: %{
#     total: 100,
#     completed: 45,
#     failed: 2,
#     pending: 53
#   }
# }
```

---

### FlowStone.cancel/2-3

**Cancel a running or scheduled asset execution.**

```elixir
@spec cancel(module(), atom()) :: :ok | {:error, reason}
@spec cancel(module(), atom(), keyword()) :: :ok | {:error, reason}

:ok = FlowStone.cancel(MyPipeline, :asset)
:ok = FlowStone.cancel(MyPipeline, :asset, partition: ~D[2025-01-15])
```

---

### FlowStone.invalidate/2-3

**Delete cached results and downstream dependents.**

```elixir
@spec invalidate(module(), atom()) :: {:ok, invalidated_count}
@spec invalidate(module(), atom(), keyword()) :: {:ok, invalidated_count}

# Invalidate single asset
{:ok, 1} = FlowStone.invalidate(MyPipeline, :asset)

# Invalidate with cascade
{:ok, 5} = FlowStone.invalidate(MyPipeline, :asset, cascade: true)

# Invalidate specific partition
{:ok, 1} = FlowStone.invalidate(MyPipeline, :asset, partition: ~D[2025-01-15])
```

---

## Inspection API

### FlowStone.graph/1-2

**Visualize the pipeline DAG.**

```elixir
@spec graph(module()) :: String.t()
@spec graph(module(), keyword()) :: String.t()

# ASCII representation
FlowStone.graph(MyPipeline)
# => """
# raw
# ├── cleaned
# │   ├── validated
# │   └── enriched
# │       └── output
# └── metrics
# """

# Mermaid format
FlowStone.graph(MyPipeline, format: :mermaid)
# => """
# graph TD
#   raw --> cleaned
#   cleaned --> validated
#   ...
# """

# DOT format for Graphviz
FlowStone.graph(MyPipeline, format: :dot)
```

---

### FlowStone.assets/1

**List all assets in a pipeline.**

```elixir
@spec assets(module()) :: [atom()]

FlowStone.assets(MyPipeline)
# => [:raw, :cleaned, :validated, :enriched, :output, :metrics]
```

---

### FlowStone.asset_info/2

**Get detailed information about an asset.**

```elixir
@spec asset_info(module(), atom()) :: asset_info()

FlowStone.asset_info(MyPipeline, :enriched)
# => %{
#   name: :enriched,
#   depends_on: [:cleaned],
#   description: "Enriches data with external API",
#   partitioned_by: :date,
#   scatter: false,
#   parallel: false,
#   has_approval: false
# }
```

---

## Pipeline Module API

When you `use FlowStone.Pipeline`, the following functions are injected:

```elixir
defmodule MyPipeline do
  use FlowStone.Pipeline

  asset :foo, do: {:ok, "bar"}
end

# Injected functions:
MyPipeline.run(:foo)                    # Delegates to FlowStone.run(MyPipeline, :foo)
MyPipeline.run(:foo, opts)              # Delegates to FlowStone.run(MyPipeline, :foo, opts)
MyPipeline.get(:foo)                    # Delegates to FlowStone.get(MyPipeline, :foo)
MyPipeline.get(:foo, opts)              # Delegates to FlowStone.get(MyPipeline, :foo, opts)
MyPipeline.assets()                     # Returns list of asset names
MyPipeline.graph()                      # Returns DAG visualization
MyPipeline.__flowstone_assets__()       # Internal: returns asset definitions
```

This enables a clean OO-like interface:

```elixir
# Either style works:
FlowStone.run(MyPipeline, :output)
MyPipeline.run(:output)

# Chaining
MyPipeline.run(:output, partition: ~D[2025-01-15])
|> case do
  {:ok, result} -> process(result)
  {:error, reason} -> handle_error(reason)
end
```

---

## Error Types

All errors are structured with clear messages:

```elixir
defmodule FlowStone.Error do
  defexception [:message, :type, :details]
end

# Types:
# :asset_not_found - Asset doesn't exist in pipeline
# :dependency_failed - Upstream asset failed
# :config_error - Missing or invalid configuration
# :storage_error - Storage backend error
# :timeout - Execution timed out
# :cancelled - Execution was cancelled
# :scatter_threshold - Too many scatter failures
```

Example errors:

```elixir
# Asset not found
%FlowStone.Error{
  type: :asset_not_found,
  message: "Asset :unknown not found in MyPipeline. Available: [:raw, :output]",
  details: %{asset: :unknown, pipeline: MyPipeline, available: [:raw, :output]}
}

# Config error
%FlowStone.Error{
  type: :config_error,
  message: """
  Async execution requires a repository. Add to config:

    config :flowstone, repo: MyApp.Repo

  Or run synchronously (default).
  """,
  details: %{missing: :repo, required_for: :async}
}
```

---

## Telemetry Events

All operations emit telemetry:

```elixir
# Execution events
[:flowstone, :run, :start]
[:flowstone, :run, :stop]
[:flowstone, :run, :exception]

# Storage events
[:flowstone, :storage, :load, :start]
[:flowstone, :storage, :load, :stop]
[:flowstone, :storage, :store, :start]
[:flowstone, :storage, :store, :stop]

# Scatter events
[:flowstone, :scatter, :start]
[:flowstone, :scatter, :item, :start]
[:flowstone, :scatter, :item, :stop]
[:flowstone, :scatter, :stop]
```

---

## Comparison: Before and After

### Running an Asset

**Before:**
```elixir
FlowStone.register(MyPipeline, registry: :my_registry)
FlowStone.materialize(:asset,
  registry: :my_registry,
  partition: ~D[2025-01-15],
  io: [config: %{agent: :my_io}]
)
```

**After:**
```elixir
FlowStone.run(MyPipeline, :asset, partition: ~D[2025-01-15])
```

### Getting Results

**Before:**
```elixir
FlowStone.IO.load(:asset, ~D[2025-01-15], config: %{agent: :my_io})
```

**After:**
```elixir
FlowStone.get(MyPipeline, :asset, partition: ~D[2025-01-15])
```

### Backfilling

**Before:**
```elixir
FlowStone.backfill(:asset,
  partitions: Date.range(...),
  registry: :my_registry,
  io: [config: %{agent: :my_io}],
  max_parallel: 4
)
```

**After:**
```elixir
FlowStone.backfill(MyPipeline, :asset,
  partitions: Date.range(...),
  parallel: 4
)
```

---

## Type Specifications

```elixir
@type pipeline :: module()
@type asset_name :: atom()
@type partition :: term()
@type result :: term()
@type reason :: term()

@type run_opts :: [
  partition: partition(),
  async: boolean(),
  force: boolean(),
  storage: atom(),
  with_deps: boolean(),
  timeout: pos_integer(),
  priority: 0..3,
  scheduled_at: DateTime.t()
]

@type get_opts :: [
  partition: partition(),
  storage: atom()
]

@type backfill_opts :: [
  partitions: Enumerable.t(),
  parallel: pos_integer(),
  force: boolean(),
  on_error: :continue | :halt,
  async: boolean()
]

@type status_map :: %{
  state: :completed | :running | :pending | :failed | :not_found,
  partition: partition(),
  completed_at: DateTime.t() | nil,
  duration_ms: non_neg_integer() | nil,
  storage: atom(),
  scatter: scatter_status() | nil
}

@type scatter_status :: %{
  total: non_neg_integer(),
  completed: non_neg_integer(),
  failed: non_neg_integer(),
  pending: non_neg_integer()
}
```
