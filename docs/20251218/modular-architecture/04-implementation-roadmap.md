# Implementation Roadmap

**Status:** Design Proposal
**Date:** 2025-12-18

## 1. Guiding Principles

From the brainstorm anti-patterns document:

> "A2 - Designing IR before you have repeatable runs: IR design becomes fantasy when not exercised by real runs."

> "G4 - Automation is allowed to be ugly at first: The first version is allowed to be a script that writes folders, runs tests, and calls one provider."

**Implication**: Ship features first, modularize after validation.

## 2. Phase Overview

| Phase | Version | Focus | Timeline Suggestion |
|-------|---------|-------|---------------------|
| **Phase 0** | v0.4.0 | Ship current features (routing, parallel, ItemReader, ItemBatcher) | Current |
| **Phase 1** | v0.5.0 | Add behaviors and registries, maintain backward compat | Next |
| **Phase 2** | v0.6.0 | Extract plugin packages, deprecate inline implementations | Following |
| **Phase 3** | v1.0.0 | Stable core, plugin ecosystem, remove deprecated code | Major release |

## 3. Phase 0: Feature Completion (Current - v0.4.0)

### 3.1 Goals

- Complete and ship routing, parallel, ItemReader, ItemBatcher
- Validate designs in real usage
- Identify actual pain points vs. theoretical concerns

### 3.2 Deliverables

- [x] Conditional routing design doc
- [x] Parallel branches design doc
- [x] ItemReader design doc
- [x] ItemBatcher design doc
- [x] ItemReader modularity analysis
- [ ] Implementation of all features
- [ ] Integration tests
- [ ] Documentation

### 3.3 Non-Goals

- Do NOT split packages yet
- Do NOT add abstraction layers
- Keep coupling as-is for now

### 3.4 Success Criteria

- All features work end-to-end
- At least one production usage of each feature
- Identified real vs. theoretical coupling issues

## 4. Phase 1: Abstraction Introduction (v0.5.0)

### 4.1 Goals

- Introduce behaviors without breaking existing code
- Add registries for runtime configuration
- Prepare extension points for plugins

### 4.2 Step 1: Define Core Behaviors

Create behavior modules alongside existing implementations:

```elixir
# New file: lib/flowstone/io/manager.ex
defmodule FlowStone.IO.Manager do
  @callback load(atom(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback store(atom(), term(), term(), keyword()) :: :ok | {:error, term()}
  @callback exists?(atom(), term(), keyword()) :: boolean()
  @callback delete(atom(), term(), keyword()) :: :ok | {:error, term()}
end

# Update existing: lib/flowstone/io/postgres.ex
defmodule FlowStone.IO.Postgres do
  @behaviour FlowStone.IO.Manager  # Add this line

  # Existing implementation unchanged
end
```

**Files to create:**
- `lib/flowstone/io/manager.ex` - IO behavior
- `lib/flowstone/scatter/item_reader.ex` - Already exists, verify callbacks
- `lib/flowstone/scatter/coordinator.ex` - Scatter coordination behavior
- `lib/flowstone/parallel/coordinator.ex` - Parallel coordination behavior

### 4.3 Step 2: Add Registries

Create registry modules that resolve implementations from config:

```elixir
# New file: lib/flowstone/io/registry.ex
defmodule FlowStone.IO.Registry do
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn ->
      Application.get_env(:flowstone, :io_managers, %{
        default: FlowStone.IO.Memory,
        memory: FlowStone.IO.Memory,
        postgres: FlowStone.IO.Postgres,
        s3: FlowStone.IO.S3,
        parquet: FlowStone.IO.Parquet
      })
    end, name: __MODULE__)
  end

  def resolve(name) do
    Agent.get(__MODULE__, &Map.get(&1, name))
  end
end
```

**Files to create:**
- `lib/flowstone/io/registry.ex`
- `lib/flowstone/scatter/reader_registry.ex`

### 4.4 Step 3: Update Application Supervision

Add registries to supervision tree:

```elixir
# lib/flowstone/application.ex
def start(_type, _args) do
  children = [
    FlowStone.IO.Registry,
    FlowStone.Scatter.ReaderRegistry,
    # ... existing children
  ]
end
```

### 4.5 Step 4: Update IO Dispatch

Modify `FlowStone.IO` to use registry:

```elixir
# lib/flowstone/io.ex
def load(asset, partition, opts \\ []) do
  manager_name = opts[:manager] || :default
  {module, config} = FlowStone.IO.Registry.resolve(manager_name)
  module.load(asset, partition, Keyword.merge(config, opts))
end
```

### 4.6 Step 5: Update ItemReader Resolution

Modify scatter to use reader registry:

```elixir
# lib/flowstone/scatter.ex (or new coordinator)
defp resolve_reader(source, config) do
  case FlowStone.Scatter.ReaderRegistry.resolve(source) do
    {:ok, {module, default_config}} ->
      {:ok, module, Keyword.merge(default_config, config)}
    {:error, :not_found} ->
      {:error, {:unknown_reader, source}}
  end
end
```

### 4.7 Backward Compatibility

All existing code continues to work:
- Default implementations are pre-registered
- Existing config formats still work
- No required migration

### 4.8 Deliverables

- [ ] Behavior modules for IO, ItemReader, Scatter, Parallel
- [ ] Registry modules for IO and Readers
- [ ] Updated Application supervision
- [ ] Updated dispatch logic
- [ ] Tests for registry resolution
- [ ] Documentation for custom implementations

## 5. Phase 2: Package Extraction (v0.6.0)

### 5.1 Goals

- Extract plugins to separate packages
- Maintain backward compatibility via defaults
- Deprecate inline implementations in core

### 5.2 Package Extraction Order

**First Wave** (Low coupling):
1. `flowstone_io_s3` - Standalone, no core deps beyond behavior
2. `flowstone_io_parquet` - Standalone, no core deps
3. `flowstone_readers_aws` - Only depends on ItemReader behavior

**Second Wave** (Medium coupling):
4. `flowstone_scatter` - Core coordination logic
5. `flowstone_parallel` - Core coordination logic
6. `flowstone_observability` - Telemetry and metrics

**Third Wave** (Higher coupling):
7. `flowstone_scheduling` - Cron and sensors
8. `flowstone_lineage` - Lineage tracking
9. `flowstone_checkpoints` - HITL features

### 5.3 Package Structure Template

```
flowstone_scatter/
├── lib/
│   ├── flowstone_scatter.ex
│   └── flowstone/
│       └── scatter/
│           ├── impl.ex           # Implements Scatter.Coordinator
│           ├── barrier.ex        # Ecto schema
│           ├── result.ex         # Ecto schema
│           ├── key.ex
│           ├── options.ex
│           ├── batch_options.ex
│           ├── batcher.ex
│           └── workers/
│               ├── scatter_worker.ex
│               ├── batch_worker.ex
│               └── reader_worker.ex
├── priv/
│   └── repo/migrations/
│       └── 001_create_scatter_tables.exs
├── test/
│   └── ...
├── mix.exs
├── README.md
└── CHANGELOG.md
```

### 5.4 Core Package Cleanup

After extraction, core becomes:

```
flowstone/
├── lib/
│   ├── flowstone.ex
│   └── flowstone/
│       ├── application.ex
│       ├── pipeline.ex
│       ├── asset.ex
│       ├── dag.ex
│       ├── executor.ex
│       ├── materializer.ex
│       ├── context.ex
│       ├── registry.ex
│       ├── partition.ex
│       ├── error.ex
│       ├── run_config.ex
│       ├── io/
│       │   ├── manager.ex          # Behavior
│       │   ├── registry.ex         # Registry
│       │   └── memory.ex           # Default impl
│       ├── scatter/
│       │   ├── item_reader.ex      # Behavior
│       │   ├── reader_registry.ex  # Registry
│       │   ├── coordinator.ex      # Behavior
│       │   └── item_readers/
│       │       └── custom.ex       # Wraps user functions
│       └── parallel/
│           └── coordinator.ex      # Behavior
├── test/
└── mix.exs
```

### 5.5 Deprecation Strategy

```elixir
# lib/flowstone/io/postgres.ex
@deprecated "Use flowstone_io_postgres package instead"
defmodule FlowStone.IO.Postgres do
  # ... implementation moves to flowstone_io_postgres
  # This module becomes a passthrough

  def load(asset, partition, opts) do
    IO.warn("FlowStone.IO.Postgres is deprecated. Add {:flowstone_io_postgres, \"~> 0.1\"} to deps.")
    FlowStone.IO.Postgres.Impl.load(asset, partition, opts)
  end
end
```

### 5.6 Deliverables

- [ ] flowstone_io_s3 package
- [ ] flowstone_io_parquet package
- [ ] flowstone_readers_aws package
- [ ] flowstone_readers_postgres package
- [ ] flowstone_scatter package
- [ ] flowstone_parallel package
- [ ] flowstone_observability package
- [ ] Deprecation warnings in core
- [ ] Migration guide
- [ ] Updated documentation

## 6. Phase 3: Stable Release (v1.0.0)

### 6.1 Goals

- Remove deprecated code from core
- Stable behavior/protocol contracts
- Plugin ecosystem established

### 6.2 Breaking Changes

- Inline implementations removed (require plugin deps)
- Behaviors are stable and versioned
- Configuration format finalized

### 6.3 Deliverables

- [ ] Core package minimal and stable
- [ ] All plugins published
- [ ] Comprehensive documentation
- [ ] Migration tools/scripts
- [ ] Integration test suite
- [ ] Performance benchmarks

## 7. Parallel Workstreams

### 7.1 Documentation

Throughout all phases:
- Update README for each change
- Maintain CHANGELOG
- Add plugin authoring guide
- Add migration guides

### 7.2 Testing

Throughout all phases:
- Unit tests for behaviors
- Integration tests for registries
- End-to-end tests for extracted packages
- Property-based tests for contracts

### 7.3 Telemetry Consistency

Throughout all phases:
- Ensure consistent event naming
- Add observability for registry resolution
- Document telemetry events

## 8. Risk Mitigation

### 8.1 Risk: Breaking Changes

**Mitigation**: Deprecation period spans entire v0.x series

### 8.2 Risk: Performance Regression

**Mitigation**: Benchmark before/after each phase

### 8.3 Risk: Plugin Fragmentation

**Mitigation**: Core team maintains official plugins

### 8.4 Risk: Community Confusion

**Mitigation**: Clear migration guides and documentation

## 9. Success Metrics

### Phase 1 Success

- All existing tests pass
- No runtime errors from registry changes
- At least one custom implementation working

### Phase 2 Success

- Extracted packages compile independently
- Core package size reduced by 50%
- CI/CD pipelines for all packages

### Phase 3 Success

- v1.0.0 release
- 3+ community plugins
- Production usage at scale

## 10. Non-Goals (Explicit)

- **Not in scope**: Full NSAI.Work IR integration (future major version)
- **Not in scope**: Distributed execution via Handoff (future feature)
- **Not in scope**: Cross-cluster coordination (future feature)

These are tracked in brainstorm documents for future consideration, not this modularization effort.
