# FlowStone UX Redesign

**Status:** Design Proposal
**Date:** 2025-12-18
**Version Target:** v1.0.0

## Executive Summary

FlowStone's current developer experience requires too much ceremony for simple use cases. Users must understand registries, manually start servers, configure multiple subsystems, and pass numerous options to basic operations.

This document set proposes a complete UX overhaul with these goals:

1. **Zero-config start** - Works out of the box with no setup
2. **Single entry point** - One function to run pipelines
3. **Progressive complexity** - Simple cases are simple, advanced cases are possible
4. **Config-driven behavior** - Adding config unlocks features, not code changes
5. **Sensible defaults** - Production-ready without tuning

## Core Philosophy

> **"Make the simple things simple, and the complex things possible."**

A FlowStone user should be able to:
- Define a pipeline in 10 lines
- Run it with 1 function call
- Get results immediately
- Scale to production by adding config, not changing code

## The Five-Minute Experience

```elixir
# 1. Add dependency
{:flowstone, "~> 1.0"}

# 2. Define pipeline
defmodule MyPipeline do
  use FlowStone.Pipeline

  asset :greeting do
    execute fn _, _ -> {:ok, "Hello, World!"} end
  end
end

# 3. Run it
{:ok, "Hello, World!"} = FlowStone.run(MyPipeline, :greeting)
```

That's it. No config, no servers, no registries.

## Document Set

| Document | Purpose |
|----------|---------|
| `01-current-problems.md` | Analysis of current UX pain points |
| `02-api-design.md` | New public API specification |
| `03-configuration.md` | Simplified configuration system |
| `04-progressive-complexity.md` | Simple → Advanced usage patterns |
| `05-dsl-improvements.md` | Pipeline DSL enhancements |
| `06-flowstone-ai-integration.md` | AI integration ergonomics |
| `07-migration-guide.md` | Upgrading from current API |
| `08-examples.md` | Complete working examples |

## Key Changes Summary

### Before (Current)

```elixir
# Mix deps - unclear which are needed
{:flowstone, path: "..."},
{:ecto_sql, "~> 3.0"},
{:postgrex, "~> 0.17"},
{:oban, "~> 2.17"},

# Config - many flags, nothing on by default
config :flowstone,
  ecto_repos: [FlowStone.Repo],
  io_managers: %{memory: M, postgres: P, s3: S, parquet: Q},
  default_io_manager: :memory,
  start_repo: false,
  start_pubsub: false,
  start_resources: false,
  start_materialization_store: false,
  start_oban: false

config :flowstone, Oban, repo: FlowStone.Repo, queues: [...]

# Manual server startup
ensure_started(FlowStone.Registry, name: :my_registry)
ensure_started(FlowStone.IO.Memory, name: :my_io)

# Pipeline
defmodule MyPipeline do
  use FlowStone.Pipeline
  asset :foo do
    execute fn _, _ -> {:ok, "bar"} end
  end
end

# Manual registration
FlowStone.register(MyPipeline, registry: :my_registry)

# Run with many options
FlowStone.materialize(:foo,
  partition: :demo,
  registry: :my_registry,
  io: [config: %{agent: :my_io}],
  resource_server: nil,
  lineage_server: nil,
  materialization_store: nil,
  use_repo: true
)

# Load result
{:ok, result} = FlowStone.IO.load(:foo, :demo, config: %{agent: :my_io})
```

### After (Proposed)

```elixir
# Mix deps - just flowstone
{:flowstone, "~> 1.0"}

# Config - optional, for production
config :flowstone, repo: MyApp.Repo

# Pipeline
defmodule MyPipeline do
  use FlowStone.Pipeline
  asset :foo, do: {:ok, "bar"}
end

# Run and get result
{:ok, "bar"} = FlowStone.run(MyPipeline, :foo)
```

## Design Principles

### 1. Convention Over Configuration

FlowStone should work with zero configuration. Defaults are:
- In-memory storage
- Synchronous execution
- No persistence
- No job queue

Adding a repo unlocks everything:
```elixir
config :flowstone, repo: MyApp.Repo
# Now you get: Postgres storage, Oban async, lineage, checkpoints
```

### 2. Single Entry Point

One function to rule them all:
```elixir
FlowStone.run(Pipeline, :asset)              # Basic
FlowStone.run(Pipeline, :asset, opts)        # With options
```

Not:
- `materialize/2`
- `materialize_all/2`
- `materialize_with_deps/2`
- `backfill/3`

### 3. Pipeline-Centric API

The pipeline module is the primary unit:
```elixir
FlowStone.run(MyPipeline, :asset)           # Run asset
FlowStone.get(MyPipeline, :asset)           # Get result
FlowStone.status(MyPipeline, :asset)        # Check status
FlowStone.graph(MyPipeline)                 # Visualize DAG
```

Not asset-name-only with separate registry:
```elixir
# Bad - where does :foo come from?
FlowStone.materialize(:foo, registry: :my_registry)
```

### 4. Explicit Over Implicit (For Advanced Features)

Simple things need no options. Advanced features are explicit:
```elixir
# Simple - no options
FlowStone.run(MyPipeline, :asset)

# Advanced - explicit options
FlowStone.run(MyPipeline, :asset,
  partition: ~D[2025-01-15],
  storage: :s3,
  async: true,
  priority: :high
)
```

### 5. Fail Fast With Clear Errors

```elixir
# Bad error
** (KeyError) key :my_registry not found in: %{}

# Good error
** (FlowStone.ConfigError)
  No repository configured. Add to config/config.exs:

    config :flowstone, repo: MyApp.Repo

  Or run synchronously with in-memory storage (no config needed).
```

## Success Metrics

### Developer Experience

| Metric | Current | Target |
|--------|---------|--------|
| Lines to first working pipeline | 30+ | 10 |
| Config options for basic case | 10+ | 0 |
| Separate setup steps | 4 | 0 |
| Functions to learn for basics | 5+ | 2 |

### Cognitive Load

| Concept | Current | Target |
|---------|---------|--------|
| Servers to understand | 5+ | 0 (hidden) |
| Registration steps | Manual | Automatic |
| Storage configuration | Complex map | Single atom |
| Execution mode | Implicit | Explicit option |

## Non-Goals

This redesign does NOT:
- Change the underlying execution model
- Remove advanced features
- Break the behavior/registry internal pattern
- Remove flexibility for power users

It DOES:
- Hide complexity behind sensible defaults
- Provide a clean public API
- Make common cases trivial
- Keep advanced cases accessible

## Implementation Phases

### Phase 1: New API Layer
- Add `FlowStone.run/2-3`
- Add `FlowStone.get/2-3`
- Auto-registration of pipelines
- Deprecate but keep old API

### Phase 2: Configuration Simplification
- Single `repo:` config unlocks persistence
- Automatic Oban setup
- Storage defaults

### Phase 3: DSL Improvements
- Shorter asset syntax
- Better error messages
- Inline documentation

### Phase 4: Documentation & Examples
- Quick start guide
- Migration guide
- Example repository

## Compatibility

The new API will be **additive**. Existing code continues to work:
- `FlowStone.materialize/2` still works (deprecated)
- Manual registration still works
- All options still available

Migration is opt-in and incremental.
