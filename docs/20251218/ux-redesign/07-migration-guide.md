# Migration Guide

**Status:** Design Proposal
**Date:** 2025-12-18

## Overview

This guide covers migrating from the current FlowStone API to the proposed new API. The migration is **incremental** - old code continues to work while you adopt new patterns.

---

## Migration Strategy

### Phase 1: Update Configuration (Low Risk)

Simplify your config.exs while keeping existing code.

### Phase 2: Adopt New API (Medium Risk)

Switch to `FlowStone.run/3` and `FlowStone.get/3`.

### Phase 3: Simplify Pipelines (Low Risk)

Use new DSL shortcuts where beneficial.

### Phase 4: Remove Deprecated Code (Cleanup)

Remove old patterns once fully migrated.

---

## Phase 1: Configuration Migration

### Before

```elixir
# config/config.exs
config :flowstone,
  ecto_repos: [FlowStone.Repo],
  io_managers: %{
    memory: FlowStone.IO.Memory,
    postgres: FlowStone.IO.Postgres,
    s3: FlowStone.IO.S3,
    parquet: FlowStone.IO.Parquet
  },
  default_io_manager: :postgres,
  start_repo: true,
  start_pubsub: true,
  start_resources: true,
  start_materialization_store: true,
  start_oban: true

config :flowstone, Oban,
  repo: FlowStone.Repo,
  queues: [
    assets: 10,
    checkpoints: 5,
    parallel_join: 5,
    flowstone_scatter: 10
  ],
  plugins: [Oban.Plugins.Pruner]

config :flowstone, FlowStone.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "flowstone_dev",
  pool_size: 10
```

### After

```elixir
# config/config.exs
config :flowstone,
  repo: MyApp.Repo,      # Use your app's repo
  storage: :postgres     # Default storage

# Your existing repo config stays the same
config :my_app, MyApp.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "my_app_dev",
  pool_size: 10
```

### What Changes

| Old Config | New Config | Notes |
|------------|------------|-------|
| `ecto_repos: [FlowStone.Repo]` | Removed | Uses your app's repo |
| `io_managers: %{...}` | `storage: :postgres` | Simplified |
| `default_io_manager: :memory` | `storage: :memory` | Renamed |
| `start_repo: true` | Removed | Auto-detected |
| `start_pubsub: true` | Removed | Auto-started |
| `start_resources: true` | Removed | Auto-started |
| `start_materialization_store: true` | Removed | Auto-started |
| `start_oban: true` | Removed | Auto-configured |
| `config :flowstone, Oban, ...` | Optional | Sensible defaults |

### Compatibility Mode

During migration, you can use both:

```elixir
config :flowstone,
  # New style
  repo: MyApp.Repo,
  storage: :postgres,

  # Old style (still works, deprecated)
  io_managers: %{...},
  start_oban: true
```

FlowStone will warn about deprecated config keys but continue working.

---

## Phase 2: API Migration

### Materialize → Run

#### Before
```elixir
# Manual setup
ensure_started(FlowStone.Registry, name: :my_registry)
ensure_started(FlowStone.IO.Memory, name: :my_io)

# Register
FlowStone.register(MyPipeline, registry: :my_registry)

# Materialize
FlowStone.materialize(:my_asset,
  registry: :my_registry,
  partition: ~D[2025-01-15],
  io: [config: %{agent: :my_io}]
)
```

#### After
```elixir
# Just run it
FlowStone.run(MyPipeline, :my_asset, partition: ~D[2025-01-15])
```

### Load → Get

#### Before
```elixir
FlowStone.IO.load(:my_asset, ~D[2025-01-15],
  config: %{agent: :my_io}
)
```

#### After
```elixir
FlowStone.get(MyPipeline, :my_asset, partition: ~D[2025-01-15])
```

### Backfill

#### Before
```elixir
FlowStone.backfill(:my_asset,
  partitions: Date.range(~D[2025-01-01], ~D[2025-01-31]),
  registry: :my_registry,
  io: [config: %{agent: :my_io}],
  max_parallel: 4
)
```

#### After
```elixir
FlowStone.backfill(MyPipeline, :my_asset,
  partitions: Date.range(~D[2025-01-01], ~D[2025-01-31]),
  parallel: 4
)
```

### Async Execution

#### Before
```elixir
# Behavior depends on whether Oban is running
result = FlowStone.materialize(:my_asset, opts)
# Could be {:ok, result} or {:ok, %Oban.Job{}}
```

#### After
```elixir
# Explicit async option
{:ok, result} = FlowStone.run(MyPipeline, :my_asset)  # Always sync

{:ok, %Oban.Job{}} = FlowStone.run(MyPipeline, :my_asset, async: true)  # Always async
```

### Migration Table

| Old API | New API |
|---------|---------|
| `FlowStone.materialize(:asset, opts)` | `FlowStone.run(Pipeline, :asset, opts)` |
| `FlowStone.materialize_all(:asset, opts)` | `FlowStone.run(Pipeline, :asset, opts)` (with_deps: true is default) |
| `FlowStone.register(Pipeline, opts)` | Not needed (auto-registration) |
| `FlowStone.IO.load(:asset, partition, opts)` | `FlowStone.get(Pipeline, :asset, opts)` |
| `FlowStone.IO.store(...)` | Not typically needed (automatic) |
| `FlowStone.IO.exists?(...)` | `FlowStone.exists?(Pipeline, :asset, opts)` |

---

## Phase 3: Pipeline DSL Migration

### Short-Form Assets

#### Before
```elixir
asset :greeting do
  execute fn _, _ -> {:ok, "Hello"} end
end
```

#### After (Optional)
```elixir
asset :greeting, do: {:ok, "Hello"}
```

### Implicit Result Wrapping

#### Before
```elixir
execute fn _, _ ->
  result = compute()
  {:ok, result}
end
```

#### After (Optional)
```elixir
execute fn _, _ ->
  compute()  # Automatically wrapped in {:ok, _}
end
```

### Resource Access

#### Before
```elixir
asset :enriched do
  requires [:ai]

  execute fn ctx, deps ->
    FlowStone.AI.Resource.generate(ctx.resources.ai, "prompt")
  end
end
```

#### After
```elixir
asset :enriched do
  requires [:ai]

  execute fn ctx, deps ->
    ctx.ai.generate("prompt")  # Direct access
  end
end
```

### Scatter Syntax

#### Before
```elixir
asset :processed do
  depends_on [:items]

  scatter fn %{items: items} ->
    Enum.map(items, &%{id: &1.id})
  end

  scatter_options do
    max_concurrent 50
  end

  execute fn ctx, _ ->
    {:ok, process(ctx.scatter_key.id)}
  end

  gather fn results ->
    {:ok, Map.values(results)}
  end
end
```

#### After (Optional)
```elixir
asset :processed do
  depends_on [:items]

  scatter from: :items, by: :id, max_concurrent: 50

  execute fn ctx, _ ->
    process(ctx.key)  # Simpler access, auto-wrapped
  end

  gather &Map.values/1
end
```

---

## Phase 4: Cleanup

### Remove Deprecated Patterns

Once fully migrated, remove:

```elixir
# Remove manual server starts
ensure_started(FlowStone.Registry, name: :my_registry)  # Delete
ensure_started(FlowStone.IO.Memory, name: :my_io)       # Delete

# Remove explicit registration
FlowStone.register(MyPipeline, registry: :my_registry)  # Delete

# Remove old config
config :flowstone,
  start_repo: true,              # Delete
  start_pubsub: true,            # Delete
  io_managers: %{...}            # Delete if using storage: option
```

### Update Dependencies

```elixir
# Before
defp deps do
  [
    {:flowstone, path: "..."},
    {:ecto_sql, "~> 3.10"},     # Still needed
    {:postgrex, ">= 0.0.0"},    # Still needed
    {:oban, "~> 2.17"},         # Now optional (bundled or separate)
  ]
end

# After
defp deps do
  [
    {:flowstone, "~> 1.0"},     # Published package
    {:ecto_sql, "~> 3.10"},
    {:postgrex, ">= 0.0.0"}
  ]
end
```

---

## Deprecation Warnings

The old API will emit deprecation warnings:

```
warning: FlowStone.materialize/2 is deprecated. Use FlowStone.run/3 instead.
  FlowStone.materialize(:asset, opts)
  ->
  FlowStone.run(MyPipeline, :asset, opts)

warning: FlowStone.register/2 is deprecated. Pipelines are now auto-registered.
  Remove this call.

warning: config :flowstone, :io_managers is deprecated.
  Use `config :flowstone, storage: :postgres` instead.
```

---

## Codemod Script

A migration script can automate common changes:

```bash
# Run the migration script
mix flowstone.migrate

# Preview changes without applying
mix flowstone.migrate --dry-run

# Migrate specific files
mix flowstone.migrate lib/my_app/pipelines/*.ex
```

### What the Script Does

1. **Config migration** - Rewrites config.exs
2. **API updates** - `materialize` → `run`, `IO.load` → `get`
3. **Import cleanup** - Removes unnecessary imports
4. **Warning cleanup** - Removes deprecated patterns

---

## Testing During Migration

### Run Both APIs

During migration, you can run both APIs in tests:

```elixir
defmodule MyPipelineTest do
  use ExUnit.Case

  describe "old API (deprecated)" do
    setup do
      {:ok, registry} = FlowStone.Registry.start_link(name: :test_registry)
      {:ok, io} = FlowStone.IO.Memory.start_link(name: :test_io)
      FlowStone.register(MyPipeline, registry: :test_registry)
      %{registry: registry, io: io}
    end

    test "materialize works", %{registry: reg, io: io} do
      FlowStone.materialize(:my_asset,
        registry: reg,
        io: [config: %{agent: io}]
      )
    end
  end

  describe "new API" do
    test "run works" do
      {:ok, result} = FlowStone.run(MyPipeline, :my_asset)
      assert result == expected
    end
  end
end
```

### Verify Equivalence

```elixir
test "old and new API produce same results" do
  # Run with old API
  old_result = old_api_materialize()

  # Run with new API
  {:ok, new_result} = FlowStone.run(MyPipeline, :my_asset)

  assert old_result == new_result
end
```

---

## Rollback Plan

If issues arise during migration:

### Config Rollback

```elixir
# Revert to old config
config :flowstone,
  io_managers: %{...},
  start_repo: true,
  # ... old config
```

### Code Rollback

The old API continues to work, so you can revert individual files:

```bash
git checkout HEAD~1 -- lib/my_app/pipelines/my_pipeline.ex
```

### Gradual Migration

Migrate one pipeline at a time:

```elixir
# Old pipeline (still works)
FlowStone.materialize(:old_asset, registry: :my_registry, ...)

# New pipeline
FlowStone.run(NewPipeline, :new_asset)
```

---

## Timeline

| Version | Status |
|---------|--------|
| v0.5.0 | New API added, old API deprecated with warnings |
| v0.6.0 | Deprecation warnings become errors (can be silenced) |
| v1.0.0 | Old API removed |

---

## Getting Help

If you encounter issues during migration:

1. Check the [migration FAQ](#faq)
2. Run `mix flowstone.doctor` to diagnose common issues
3. Open an issue with migration tag

---

## FAQ

### Q: Can I use both APIs simultaneously?

Yes, both APIs work during the transition period. You can migrate incrementally.

### Q: What happens to my existing data?

Nothing changes. The storage format is identical; only the API changes.

### Q: Do I need to run migrations?

No new database migrations are required for the API change.

### Q: Will my Oban jobs continue to work?

Yes, existing queued jobs will complete normally. New jobs use the same format.

### Q: Can I still use custom registries?

Yes, but they're optional. If you have a specific need for multiple registries, you can pass `registry:` option to `run/3`.
