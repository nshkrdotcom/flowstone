# FlowStone Ideal Modular Boundaries

**Status:** Design Proposal
**Date:** 2025-12-18

## 1. Layered Architecture Vision

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      INTEGRATION LAYER                                   │
│  flowstone_ai     flowstone_synapse     flowstone_messaging             │
│  (AI assets)      (workflow bridge)     (Kafka/NATS integration)        │
├─────────────────────────────────────────────────────────────────────────┤
│                      PLUGIN LAYER                                        │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐  │
│  │ flowstone_      │  │ flowstone_      │  │ flowstone_readers_aws   │  │
│  │ scatter         │  │ parallel        │  │ (S3, DynamoDB readers)  │  │
│  │ (fan-out)       │  │ (branches)      │  │                         │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────────────┘  │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐  │
│  │ flowstone_io_   │  │ flowstone_io_   │  │ flowstone_observability │  │
│  │ postgres        │  │ s3              │  │ (telemetry, metrics)    │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────────────┘  │
├─────────────────────────────────────────────────────────────────────────┤
│                      CORE LAYER (flowstone)                              │
│                                                                          │
│  Behaviors:          Protocols:           Modules:                       │
│  ├─ IO.Manager      ├─ Telemetry.Emitter ├─ Pipeline (DSL)              │
│  ├─ ItemReader      ├─ Error.Normalizer  ├─ Asset (struct)              │
│  ├─ Scatter.Coord   │                    ├─ DAG (graph)                 │
│  └─ Parallel.Coord  │                    ├─ Executor (orchestration)    │
│                     │                    ├─ Materializer (execution)    │
│  Registries:        │                    ├─ Context (runtime)           │
│  ├─ IO.Registry     │                    ├─ Registry (assets)           │
│  ├─ Reader.Registry │                    └─ Partition (serialization)   │
│  └─ Plugin.Registry │                                                   │
└─────────────────────────────────────────────────────────────────────────┘
```

## 2. Core Layer: What Stays in `flowstone`

The core package contains **abstractions and essential execution** only:

### 2.1 Essential Modules (Cannot Be Extracted)

```elixir
# DSL & Definition
FlowStone                  # API facade
FlowStone.Pipeline         # Macros for asset definition
FlowStone.Asset            # Asset struct (name, deps, execute_fn, etc.)
FlowStone.DAG              # DAG construction from assets
FlowStone.Partition        # Partition serialization/deserialization

# Execution Core
FlowStone.Executor         # Orchestrates single asset execution
FlowStone.Materializer     # Invokes asset functions, handles errors
FlowStone.Context          # Runtime context passed to assets
FlowStone.Registry         # In-memory asset lookup

# Error Handling
FlowStone.Error            # Error struct and construction

# Configuration
FlowStone.Application      # Supervision tree
FlowStone.RunConfig        # Runtime config for workers
```

### 2.2 Behaviors Defined in Core

```elixir
# I/O Manager behavior
defmodule FlowStone.IO.Manager do
  @callback load(asset :: atom(), partition :: term(), opts :: keyword()) ::
    {:ok, term()} | {:error, term()}
  @callback store(asset :: atom(), data :: term(), partition :: term(), opts :: keyword()) ::
    :ok | {:error, term()}
  @callback exists?(asset :: atom(), partition :: term(), opts :: keyword()) ::
    boolean()
  @callback delete(asset :: atom(), partition :: term(), opts :: keyword()) ::
    :ok | {:error, term()}
end

# ItemReader behavior
defmodule FlowStone.Scatter.ItemReader do
  @callback init(config :: map(), deps :: map()) :: {:ok, state :: term()} | {:error, term()}
  @callback read(state :: term(), batch_size :: pos_integer()) ::
    {:ok, [item :: map()], state :: term() | :halt} | {:error, term()}
  @callback count(state :: term()) :: {:ok, non_neg_integer()} | :unknown
  @callback checkpoint(state :: term()) :: map()
  @callback restore(state :: term(), checkpoint :: map()) :: term()
  @callback close(state :: term()) :: :ok
end

# Scatter Coordinator behavior
defmodule FlowStone.Scatter.Coordinator do
  @callback create_barrier(run_id :: binary(), asset :: atom(), opts :: keyword()) ::
    {:ok, barrier_id :: binary()} | {:error, term()}
  @callback insert_results(barrier_id :: binary(), keys :: [term()]) :: :ok | {:error, term()}
  @callback complete(barrier_id :: binary(), key :: term(), result :: term()) ::
    {:ok, :pending | :complete} | {:error, term()}
  @callback fail(barrier_id :: binary(), key :: term(), error :: term()) ::
    {:ok, :pending | :threshold_exceeded} | {:error, term()}
  @callback gather(barrier_id :: binary()) :: {:ok, map()} | {:error, term()}
end

# Parallel Coordinator behavior
defmodule FlowStone.Parallel.Coordinator do
  @callback create_execution(run_id :: binary(), asset :: atom(), branches :: [atom()]) ::
    {:ok, execution_id :: binary()} | {:error, term()}
  @callback schedule_branches(execution_id :: binary()) :: :ok | {:error, term()}
  @callback complete_branch(execution_id :: binary(), branch :: atom(), result :: term()) ::
    {:ok, :pending | :ready_for_join} | {:error, term()}
  @callback fail_branch(execution_id :: binary(), branch :: atom(), error :: term()) ::
    {:ok, :pending | :failed} | {:error, term()}
  @callback execute_join(execution_id :: binary(), join_fn :: function()) ::
    {:ok, term()} | {:error, term()}
end

# Telemetry Emitter protocol
defprotocol FlowStone.Telemetry.Emitter do
  def execute(emitter, event, measurements, metadata)
  def span(emitter, event, metadata, fun)
end
```

### 2.3 Registries in Core

Registries allow runtime configuration of implementations:

```elixir
defmodule FlowStone.IO.Registry do
  @moduledoc "Maps IO manager names to modules"

  def register(name, module, config \\ [])
  def resolve(name) :: {:ok, {module, config}} | {:error, :not_found}
  def list() :: [{name, module, config}]
end

defmodule FlowStone.Scatter.ReaderRegistry do
  @moduledoc "Maps reader names to ItemReader modules"

  def register(name, module, default_config \\ [])
  def resolve(name) :: {:ok, {module, config}} | {:error, :not_found}
end
```

## 3. Plugin Layer: Feature Packages

### 3.1 `flowstone_scatter` - Fan-Out Execution

**Scope**: All scatter functionality including barrier coordination, batching, and workers.

```
flowstone_scatter/
├── lib/
│   ├── flowstone_scatter.ex              # Entry point
│   └── flowstone/
│       └── scatter/
│           ├── coordinator.ex            # Implements Scatter.Coordinator
│           ├── barrier.ex                # Ecto schema
│           ├── result.ex                 # Ecto schema
│           ├── key.ex                    # Key normalization
│           ├── options.ex                # Options struct
│           ├── batch_options.ex          # Batching config
│           ├── batcher.ex                # Grouping logic
│           └── workers/
│               ├── scatter_worker.ex
│               ├── batch_worker.ex
│               └── reader_worker.ex
├── priv/
│   └── repo/migrations/
│       ├── 001_create_scatter_barriers.exs
│       └── 002_create_scatter_results.exs
└── mix.exs
```

**Dependencies**: `flowstone` (core), `ecto_sql`, `oban`

### 3.2 `flowstone_parallel` - Branch Execution

**Scope**: Parallel branch coordination and join logic.

```
flowstone_parallel/
├── lib/
│   └── flowstone/
│       └── parallel/
│           ├── coordinator.ex            # Implements Parallel.Coordinator
│           ├── execution.ex              # Ecto schema
│           ├── branch.ex                 # Ecto schema
│           └── workers/
│               └── join_worker.ex
├── priv/
│   └── repo/migrations/
│       └── 001_create_parallel_tables.exs
└── mix.exs
```

### 3.3 `flowstone_io_postgres` - PostgreSQL Storage

```
flowstone_io_postgres/
├── lib/
│   └── flowstone/io/postgres.ex          # Implements IO.Manager
├── priv/
│   └── repo/migrations/
│       └── 001_create_asset_storage.exs
└── mix.exs
```

### 3.4 `flowstone_io_s3` - S3 Storage

```
flowstone_io_s3/
├── lib/
│   └── flowstone/io/s3.ex                # Implements IO.Manager
└── mix.exs
```

**Dependencies**: `ex_aws`, `ex_aws_s3`

### 3.5 `flowstone_readers_aws` - AWS ItemReaders

```
flowstone_readers_aws/
├── lib/
│   └── flowstone/scatter/item_readers/
│       ├── s3.ex                         # Implements ItemReader
│       └── dynamodb.ex                   # Implements ItemReader
└── mix.exs
```

**Dependencies**: `ex_aws`, `ex_aws_s3`, `ex_aws_dynamo`

### 3.6 `flowstone_readers_postgres` - Postgres ItemReader

```
flowstone_readers_postgres/
├── lib/
│   └── flowstone/scatter/item_readers/
│       └── postgres.ex                   # Implements ItemReader
└── mix.exs
```

### 3.7 `flowstone_observability` - Telemetry & Metrics

```
flowstone_observability/
├── lib/
│   └── flowstone/
│       ├── telemetry.ex                  # Default Telemetry.Emitter impl
│       ├── telemetry_metrics.ex          # Prometheus metrics
│       ├── logger.ex                     # Structured logging
│       ├── audit_log.ex                  # Ecto schema
│       └── audit_log_context.ex          # Audit helpers
└── mix.exs
```

## 4. Integration Layer: Framework Bridges

### 4.1 `flowstone_ai` (Already Exists)

Bridges FlowStone's resource system to altar_ai for AI-powered assets.

```elixir
# Usage in assets
asset :classify_feedback do
  requires [:ai]

  execute fn ctx, deps ->
    FlowStone.AI.Assets.classify_each(
      ctx.resources.ai,
      deps.feedback,
      & &1.comment,
      ["bug", "feature", "question"]
    )
  end
end
```

### 4.2 Future: `flowstone_synapse`

Bridges FlowStone and Synapse for agent-powered steps:

```elixir
# Flowstone orchestrates the run; Synapse executes specific steps
asset :implement_fix do
  depends_on [:failing_tests, :codebase_summary]

  execute fn ctx, deps ->
    FlowStone.Synapse.execute_step(
      ctx,
      goal: "Fix the failing test",
      definition_of_done: "All tests pass",
      context_artifacts: [deps.failing_tests, deps.codebase_summary],
      budgets: %{max_iters: 3, max_usd: 5.00}
    )
  end
end
```

## 5. Boundary Principles

### 5.1 Core Contains Only Abstractions

**Rule**: If a module references external services (S3, Postgres, AWS SDK), it belongs in a plugin.

**Test**: Can this module work with zero external dependencies beyond OTP? If no, extract it.

### 5.2 Plugins Implement Behaviors

**Rule**: Every plugin must implement at least one core behavior.

**Test**: Does this plugin register itself with a core registry? If no, it's not a plugin.

### 5.3 Integration Layers Bridge Frameworks

**Rule**: Integration packages depend on both FlowStone AND the external framework.

**Test**: Does this package translate between two frameworks? If yes, it's an integration.

### 5.4 Backward Compatibility via Defaults

**Rule**: Core provides default implementations for essential features.

**Example**: `FlowStone.IO.Memory` is built into core as a fallback.

## 6. Dependency Graph

```
flowstone_ai
    │
    ├── altar_ai (AI adapters)
    │
    └── flowstone (core)
            │
            ├── flowstone_scatter
            │       └── ecto_sql, oban
            │
            ├── flowstone_parallel
            │       └── ecto_sql, oban
            │
            ├── flowstone_io_postgres
            │       └── ecto_sql
            │
            ├── flowstone_io_s3
            │       └── ex_aws, ex_aws_s3
            │
            ├── flowstone_readers_aws
            │       └── ex_aws, ex_aws_s3, ex_aws_dynamo
            │
            └── flowstone_observability
                    └── telemetry, telemetry_metrics_prometheus
```

## 7. Configuration Example

```elixir
# config/config.exs in host application

config :flowstone,
  repo: MyApp.Repo,

  # IO manager registry
  io_managers: %{
    default: FlowStone.IO.Memory,
    postgres: FlowStone.IO.Postgres,
    s3: FlowStone.IO.S3
  },

  # ItemReader registry
  item_readers: %{
    documents: {FlowStone.Scatter.ItemReaders.S3, bucket: "my-bucket"},
    reports: {FlowStone.Scatter.ItemReaders.Postgres, repo: MyApp.Repo}
  },

  # Coordinator implementations
  scatter_coordinator: FlowStone.Scatter.Coordinator,
  parallel_coordinator: FlowStone.Parallel.Coordinator,

  # Telemetry emitter
  telemetry_emitter: FlowStone.Telemetry.Default
```

## 8. Migration Path

### Phase 1: Add Behaviors (Non-Breaking)

1. Define behaviors in core
2. Add registries with default resolution to existing modules
3. Existing code continues to work unchanged

### Phase 2: Extract Plugins (Optional Migration)

1. Move implementations to separate packages
2. Existing users can add new dependencies to mix.exs
3. Configuration points to new modules
4. Old inline modules deprecated but functional

### Phase 3: Remove Deprecated (Major Version)

1. Remove inline implementations from core
2. Core contains only abstractions
3. Plugins are required dependencies
