# Current UX Problems

**Status:** Analysis
**Date:** 2025-12-18

## Overview

This document catalogs the current FlowStone developer experience issues, organized by severity and frequency of impact.

## Problem Categories

1. **Setup Complexity** - Too many steps before first run
2. **Configuration Overload** - Too many options, unclear defaults
3. **API Fragmentation** - Multiple ways to do the same thing
4. **Naming Confusion** - Unclear terminology
5. **Error Opacity** - Unhelpful error messages
6. **Documentation Gaps** - Missing guidance

---

## 1. Setup Complexity

### 1.1 Manual Server Startup

**Problem:** Users must manually start multiple GenServers before using FlowStone.

```elixir
# Current - user must do this
ensure_started(FlowStone.Registry, name: :my_registry)
ensure_started(FlowStone.IO.Memory, name: :my_io)
# What about Resources? MaterializationStore? Lineage?
```

**Impact:**
- Confusing for new users
- Easy to forget a server
- Unclear which servers are needed
- Different servers needed for different features

**Root Cause:** FlowStone was designed for embedding in larger applications where the host app manages supervision. But standalone usage is the common case.

### 1.2 Manual Pipeline Registration

**Problem:** Pipelines must be explicitly registered before use.

```elixir
# Define pipeline
defmodule MyPipeline do
  use FlowStone.Pipeline
  asset :foo do ... end
end

# Must also register
FlowStone.register(MyPipeline, registry: :my_registry)

# Then run
FlowStone.materialize(:foo, registry: :my_registry)
```

**Impact:**
- Extra step that's easy to forget
- Registration state is mutable (can register multiple times)
- Registry must be passed to both register and materialize

**Root Cause:** Separation of definition (compile-time) from registration (runtime) was intended for flexibility but adds ceremony.

### 1.3 Dependency Confusion

**Problem:** Unclear which mix dependencies are needed for which features.

```elixir
# Which of these do I need?
{:flowstone, path: "..."},
{:ecto_sql, "~> 3.0"},      # For postgres storage?
{:postgrex, "~> 0.17"},     # For postgres?
{:oban, "~> 2.17"},         # For async?
{:ex_aws, "~> 2.0"},        # For S3?
{:ex_aws_s3, "~> 2.0"},     # For S3?
{:hackney, "~> 1.18"},      # For HTTP?
{:jason, "~> 1.0"},         # For JSON?
```

**Impact:**
- Trial and error to get working
- Unclear error messages when deps missing
- Bloated deps for simple use cases

---

## 2. Configuration Overload

### 2.1 Too Many Config Flags

**Problem:** Configuration has numerous boolean flags with unclear purposes.

```elixir
config :flowstone,
  start_repo: false,
  start_pubsub: false,
  start_resources: false,
  start_materialization_store: false,
  start_oban: false,
  start_lineage: false,
  start_schedule_store: false
```

**Impact:**
- Users don't know what these control
- Default is "off" for everything - nothing works
- Must understand internals to configure

### 2.2 IO Manager Configuration

**Problem:** IO managers require complex nested configuration.

```elixir
config :flowstone,
  io_managers: %{
    memory: FlowStone.IO.Memory,
    postgres: FlowStone.IO.Postgres,
    s3: FlowStone.IO.S3,
    parquet: FlowStone.IO.Parquet
  },
  default_io_manager: :memory
```

**Impact:**
- Must understand all available managers
- Must map names to modules
- Default is memory even if postgres configured

### 2.3 Oban Configuration Duplication

**Problem:** Oban requires separate configuration block.

```elixir
config :flowstone, Oban,
  repo: FlowStone.Repo,
  queues: [
    assets: 10,
    checkpoints: 5,
    parallel_join: 5,
    flowstone_scatter: 10
  ],
  plugins: [Oban.Plugins.Pruner]
```

**Impact:**
- Queue names are internal implementation detail
- Must know correct queue configuration
- Separate from main flowstone config

---

## 3. API Fragmentation

### 3.1 Multiple Execution Functions

**Problem:** Several functions for running pipelines with subtle differences.

```elixir
FlowStone.materialize(:asset, opts)          # Single asset
FlowStone.materialize_all(:asset, opts)      # Asset + dependencies
FlowStone.materialize_with_deps(:asset, opts) # Same as above?
FlowStone.backfill(:asset, opts)             # Multiple partitions
```

**Impact:**
- Users must learn multiple functions
- Unclear which to use when
- Inconsistent option handling

### 3.2 Result Retrieval Complexity

**Problem:** Loading results requires knowing IO configuration.

```elixir
# After materialize
FlowStone.IO.load(:asset, partition, config: %{agent: :my_io})

# Must remember the agent name
# Must know to use FlowStone.IO, not FlowStone
# Must pass config separately from materialize
```

**Impact:**
- Configuration passed to materialize doesn't carry to load
- Different API shape (IO.load vs materialize)
- Agent naming convention unclear

### 3.3 Partition Handling

**Problem:** Partition semantics vary across operations.

```elixir
# Materialize with partition
FlowStone.materialize(:asset, partition: ~D[2025-01-15])

# Load with positional partition
FlowStone.IO.load(:asset, ~D[2025-01-15], opts)

# Backfill with partitions list
FlowStone.backfill(:asset, partitions: [...])

# Default partition behavior unclear
FlowStone.materialize(:asset)  # What partition?
```

---

## 4. Naming Confusion

### 4.1 "Registry" Overload

**Problem:** "Registry" means different things in different contexts.

```elixir
FlowStone.Registry              # Asset definition registry
FlowStone.IO.Registry           # IO manager registry (proposed)
FlowStone.Scatter.ReaderRegistry # ItemReader registry (proposed)
Elixir.Registry                 # Standard library Registry
```

**Impact:**
- Confusion about which registry
- Naming collisions
- Unclear mental model

### 4.2 "Agent" vs "Manager" vs "Server"

**Problem:** Inconsistent terminology for GenServer-based components.

```elixir
io: [config: %{agent: :my_io}]           # "agent"
io_manager: :memory                       # "manager"
registry: :my_registry                    # named process
resource_server: MyResources              # "server"
lineage_server: MyLineage                 # "server"
materialization_store: MyStore            # "store"
```

**Impact:**
- No consistent mental model
- Documentation uses terms interchangeably
- Hard to predict option names

### 4.3 "Materialize" Terminology

**Problem:** "Materialize" is jargon from data engineering.

For users from other backgrounds:
- Web developers: "run", "execute", "process"
- Data scientists: might understand "materialize"
- General developers: unfamiliar

**Impact:**
- Higher learning curve
- Searchability issues ("how to run flowstone pipeline")

---

## 5. Error Opacity

### 5.1 Missing Server Errors

**Problem:** Errors when servers aren't started are cryptic.

```elixir
# When registry not started
** (exit) no process: the process is not alive or there's no process
   currently associated with the given name

# When IO agent not started
** (KeyError) key :my_io not found in: %{}
```

**Expected:**
```elixir
** (FlowStone.SetupError)
  Registry not started. Either:

  1. Add FlowStone to your supervision tree:
     children = [FlowStone]

  2. Or start manually:
     FlowStone.Registry.start_link(name: :my_registry)
```

### 5.2 Configuration Errors

**Problem:** Missing or invalid configuration produces generic errors.

```elixir
# Missing Oban config
** (ArgumentError) unknown registry FlowStone.Oban

# Missing repo
** (UndefinedFunctionError) function FlowStone.Repo.all/1 is undefined
```

**Expected:**
```elixir
** (FlowStone.ConfigError)
  Async execution requires a repository. Add to config:

    config :flowstone, repo: MyApp.Repo

  Or run synchronously:
    FlowStone.run(Pipeline, :asset, async: false)
```

### 5.3 Asset Not Found

**Problem:** Missing asset produces confusing error.

```elixir
# When asset doesn't exist
** (FunctionClauseError) no function clause matching in
   FlowStone.Registry.get/2
```

**Expected:**
```elixir
** (FlowStone.AssetNotFound)
  Asset :unknown_asset not found in MyPipeline.

  Available assets: [:raw, :processed, :output]

  Did you mean: :output?
```

---

## 6. Documentation Gaps

### 6.1 No Quick Start

**Problem:** No simple "copy-paste and it works" example.

Current docs assume:
- Understanding of supervision trees
- Familiarity with Ecto/Oban
- Knowledge of data pipeline concepts

**Impact:**
- High barrier to entry
- Users bounce before first success

### 6.2 Examples Require Context

**Problem:** Example files require reading other examples first.

```elixir
# From examples/core_example.exs
defp ensure_started(module, opts) do
  # What is this function?
  # Why do I need it?
end
```

### 6.3 Missing Mental Model

**Problem:** No explanation of core concepts and how they relate.

Questions not clearly answered:
- What is an asset vs a pipeline?
- What is a partition?
- When do I need Oban vs sync execution?
- What's the difference between IO managers?

---

## 7. Option Pollution

### 7.1 Too Many Options to materialize/2

```elixir
FlowStone.materialize(:asset,
  partition: :demo,
  registry: :my_registry,
  io: [config: %{agent: :my_io}],
  resource_server: nil,
  lineage_server: nil,
  materialization_store: nil,
  use_repo: true,
  skip_if_cached: true,
  force: false,
  timeout: 30_000,
  priority: 0,
  scheduled_at: nil,
  tags: [],
  meta: %{}
)
```

**Impact:**
- Overwhelming for beginners
- Most options rarely used
- Unclear which are related

### 7.2 Nested Configuration

```elixir
io: [config: %{agent: :my_io}]
```

**Why is this nested?**
- `io:` - the IO system
- `config:` - configuration for it
- `agent:` - the specific agent

Three levels of nesting for one concept: "use this storage."

---

## 8. Concurrency Model Confusion

### 8.1 Sync vs Async Ambiguity

**Problem:** Unclear when execution is sync vs async.

```elixir
# When is this async?
FlowStone.materialize(:asset, opts)

# Returns Job if Oban running, result if not
# But how do I know if Oban is running?
```

**Impact:**
- Code behavior depends on environment
- Hard to test
- Surprising production behavior

### 8.2 Oban State Dependency

**Problem:** Execution mode depends on Oban state, not explicit option.

```elixir
# In dev (no Oban): returns {:ok, result}
# In prod (Oban running): returns {:ok, %Oban.Job{}}

# Same code, different behavior
```

---

## 9. Testing Difficulty

### 9.1 Global State Dependencies

**Problem:** Tests require managing multiple GenServers.

```elixir
setup do
  {:ok, registry} = FlowStone.Registry.start_link(name: :"test_#{System.unique_integer()}")
  {:ok, io} = FlowStone.IO.Memory.start_link(name: :"io_#{System.unique_integer()}")

  on_exit(fn ->
    Process.exit(registry, :normal)
    Process.exit(io, :normal)
  end)

  %{registry: registry, io: io}
end
```

### 9.2 No Test Helpers

**Problem:** No built-in test utilities.

Missing:
- `FlowStone.Test.run_sync/3` - Always runs synchronously
- `FlowStone.Test.with_memory_storage/1` - Isolated storage
- `FlowStone.Test.assert_asset_equals/3` - Check results

---

## Summary

| Category | Issues | Severity |
|----------|--------|----------|
| Setup Complexity | 3 | High |
| Configuration Overload | 3 | High |
| API Fragmentation | 3 | Medium |
| Naming Confusion | 3 | Medium |
| Error Opacity | 3 | High |
| Documentation Gaps | 3 | High |
| Option Pollution | 2 | Medium |
| Concurrency Confusion | 2 | Medium |
| Testing Difficulty | 2 | Medium |

**Total: 24 distinct issues**

The most impactful improvements would address:
1. Zero-config startup (Setup Complexity)
2. Single entry point API (API Fragmentation)
3. Clear error messages (Error Opacity)
4. Quick start documentation (Documentation Gaps)
