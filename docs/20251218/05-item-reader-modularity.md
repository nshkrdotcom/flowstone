# ItemReader Modularity and Decoupling Plan

**Status:** Draft (analysis)
**Author:** Codex
**Date:** 2025-12-18
**FlowStone Version:** 0.4.0 (targeted revision)

## 1. Summary

Prompt 3 added ItemReader support but it is tightly coupled to provider-specific
implementations (S3, DynamoDB, Postgres) in core. This blocks the stated goal of
swapping backends via configuration. This document explains what is coupled,
why it is risky, and how to restructure ItemReader into a clean adapter layer
while preserving FlowStone's DSL ergonomics and recovery semantics.

The proposed changes are additive when possible and minimize breaking changes
by introducing a registry/adapter layer, moving provider readers to optional
packages, and clarifying distributed gather and resume semantics.

## 2. Current Implementation Snapshot (Prompt 3)

Key additions (uncommitted):

- `scatter_from` DSL with provider-specific configuration macros
  (`bucket`, `table`, `query`, etc).
- `FlowStone.Scatter.ItemReader` behavior + `resolve/1`.
- Built-in readers:
  - `FlowStone.Scatter.ItemReaders.S3`
  - `FlowStone.Scatter.ItemReaders.DynamoDB`
  - `FlowStone.Scatter.ItemReaders.Postgres`
  - `FlowStone.Scatter.ItemReaders.Custom`
- Reader execution modes (`:inline` and `:distributed`) with checkpoints.
- New Oban worker `FlowStone.Workers.ItemReaderWorker`.
- Persistence changes: `flowstone_scatter_barriers` gains `mode`,
  `reader_checkpoint`, `parent_barrier_id`, `batch_index`.
- Optional AWS dependencies added to `mix.exs`.

The design is close to production but the coupling and resume semantics need a
structural pass before implementing ItemBatcher.

## 3. Findings (Detailed)

### 3.1 Provider-Specific Coupling in Core

**What exists now**
- `FlowStone.Scatter.ItemReader.resolve/1` maps `:s3`, `:dynamodb`, and `:postgres`
  directly to core modules.
- Core DSL macros embed provider-specific configuration keys.
- Core modules reference ExAws and Ecto directly.

**Why this is a problem**
- You cannot swap a backend by configuration alone. `scatter_from :s3` will
  always resolve to the S3 reader unless you change code.
- It makes optional integrations feel mandatory: core code knows about AWS
  modules and dependency errors.
- It blocks a clean abstraction boundary for integrations and makes it hard to
  ship provider modules on a different release cadence.

### 3.2 DSL Ties Usage to Providers

**What exists now**
- The DSL exposes `bucket`, `prefix`, `table`, `query`, etc in the core pipeline
  DSL.

**Why this is a problem**
- The core pipeline API now presumes S3/DynamoDB/Postgres concepts even when
  those providers are not used.
- It discourages building other readers (Kafka, Redis, Google Cloud Storage)
  because the primary DSL surface is already provider-specific.

### 3.3 Resume Semantics Are Incomplete

**What exists now**
- Reader state is checkpointed, but the loop counters (`batch_index`, `total_read`)
  are not persisted. On resume, those counters reset.

**Risk**
- `max_batches` and `max_items` are not applied consistently across retries.
- `batch_index` values can repeat on resume, impacting distributed audits and
  observability.

### 3.4 Distributed Gather Semantics Are Unclear

**What exists now**
- Distributed mode creates child barriers per batch.
- `Scatter.gather/1` only reads results from a single barrier, so parent
  barrier gathers are empty.

**Risk**
- Downstream assets expecting a single gather output will get partial or empty
  data in distributed mode.
- Operators cannot easily compute a unified result without bespoke logic.

### 3.5 Optional Dependencies Are Referenced in Core

**What exists now**
- The S3 and DynamoDB readers reference ExAws directly.

**Risk**
- Core builds can still warn if optional deps are not available.
- It complicates open-source usage because the base library now appears to be
  "AWS-first" in compile-time expectations.

### 3.6 Reader Config Evaluation Is Shallow

**What exists now**
- `resolve_config` only evaluates top-level functions.

**Risk**
- Nested expressions (for example, DynamoDB expression attribute maps) will not
  be evaluated as intended unless users wrap them at the top level.

## 4. Recommendations

### 4.1 Introduce an ItemReader Registry (Core)

Create a registry that maps reader names to modules and default config. This
keeps the core agnostic and allows swapping by configuration.

**Proposed API**

```elixir
config :flowstone, :item_readers, %{
  default: {MyApp.ItemReaders.Default, []},
  documents: {FlowStone.ItemReaders.S3, [bucket: "prod-bucket"]},
  reports: {FlowStone.ItemReaders.Postgres, [repo: MyApp.Repo]}
}
```

At runtime:
- `scatter_from :documents` resolves to the registry entry.
- Users can change the target by configuration without changing pipeline code.

### 4.2 Move Provider Readers Out of Core

Move S3/DynamoDB/Postgres readers into an integration package or sub-app, for
example:

- `flowstone_item_readers_aws`
- `flowstone_item_readers_postgres`

Core only ships:
- The ItemReader behavior.
- The registry resolver.
- The custom reader wrapper for user-defined read functions.

This is the same model used by `flowstone_ai`, which treats provider adapters
as plugins rather than core dependencies.

### 4.3 Make the DSL Provider-Neutral

Replace provider-specific macros with a generic reader config DSL. Keep the
ergonomics of `scatter_from` while allowing providers to add their own macros
in optional packages.

**Recommended DSL (core)**

```elixir
asset :fetch_reports do
  scatter_from :documents do
    reader_config bucket: fn deps -> deps.bucket end,
                  prefix: fn deps -> deps.path end,
                  max_items: 250
  end

  item_selector fn item, _deps -> %{key: item.key} end
end
```

**Optional provider DSL (package)**

```elixir
use FlowStone.ItemReaders.S3.DSL

asset :fetch_reports do
  scatter_from :documents do
    bucket fn deps -> deps.bucket end
    prefix fn deps -> deps.path end
    max_items 250
  end
end
```

Core remains provider-agnostic; provider packages can ship their own macro
extensions that write into `reader_config`.

### 4.4 Persist Reader Progress Fields

Store `reader_batch_index` and `reader_total_read` on the barrier (or inside
`reader_checkpoint`). On resume, the loops should pick up from these counters
so `max_batches` and `max_items` are applied consistently across restarts.

**Proposed fields**
- `reader_batch_index` (integer)
- `reader_total_read` (integer)
- `reader_total_enqueued` (optional, for diagnostics)

### 4.5 Clarify Distributed Gather Semantics

Define the standard gather behavior for distributed mode:

- `Scatter.gather/1` on a parent barrier should aggregate results from all
  child barriers (by `parent_barrier_id`).
- Expose `Scatter.gather_batches/1` to return results keyed by `batch_index`
  when batch-level processing is desired.

This allows both Step Functions-style aggregation and batch-aware workflows.

### 4.6 Resolve Dependencies via Resources Where Useful

Allow ItemReader modules to access external clients via `FlowStone.Resources`
or explicit config to avoid hard-coded module references.

Example:

```elixir
config :flowstone, :resources, %{
  s3_client: {MyApp.S3Resource, %{}}
}
```

The ItemReader receives the resource instance via `deps` or a `resource`
reference in reader config, keeping the reader decoupled from ExAws or other
clients.

### 4.7 Maintain Compatibility via a Bridge Package

- Make provider-specific macros and reader modules available in an optional
  integration package so existing pipelines can keep `scatter_from :s3` without
  rewriting their DSL.
- In core, support both `scatter_from :reader_key` (registry) and
  `scatter_from Module` (direct module) for advanced users.

## 5. Proposed API Changes (Concrete)

### 5.1 Registry Resolver

```elixir
defmodule FlowStone.Scatter.ItemReaderRegistry do
  @spec resolve(atom() | module()) :: {module(), map()}
end
```

Resolution order:
1. If module passed directly, use it.
2. If atom passed, look in `:item_readers` config for `{module, opts}`.
3. If not found, return a clear error.

### 5.2 Core DSL Additions

```elixir
scatter_from :documents do
  reader_config max_items: 500,
                reader_batch_size: 1000
end
```

Optional: `reader_option/2` for incremental updates in a block.

### 5.3 Reader Config Evaluation

Extend `resolve_config` to handle nested maps and lists so readers can accept
structured config without forcing users to wrap everything at the top level.

## 6. Testing Strategy

Add tests that specifically validate the abstraction layer:

- Registry resolution based on config.
- Swapping a reader implementation via config only.
- Resume behavior: `max_batches` and `max_items` are respected across restart.
- Distributed gather aggregates child results correctly.
- Provider packages can be omitted without compile warnings.

## 7. Migration Guide (Internal)

1. Add the registry to core and migrate `scatter_from` to use it.
2. Move S3/DynamoDB/Postgres readers and provider DSL into a plugin package.
3. Update pipeline DSL to prefer `reader_config`.
4. Provide a compatibility module that re-exports the old macros when the
   plugin is present.
5. Update `docs/20251218/03-item-reader.md` to describe the new registry model.

## 8. Next Steps (Detailed)

1. **Choose the resolution strategy**
   - Decide between a dedicated ItemReader registry or full `FlowStone.Resources`
     integration for item readers. The registry is simpler; resources are more
     flexible for shared clients.

2. **Refactor core**
   - Remove provider-specific mappings from `ItemReader.resolve/1`.
   - Add `ItemReaderRegistry` and update `scatter_from` to use it.
   - Introduce `reader_config` macro and deprecate provider-specific macros
     in core.

3. **Extract provider readers**
   - Move S3/DynamoDB/Postgres readers into an integration package.
   - Keep `FlowStone.Scatter.ItemReaders.Custom` in core.
   - Provide optional DSL helpers in the integration package.

4. **Fix resume semantics**
   - Persist `reader_batch_index` and `reader_total_read`.
   - Update inline and distributed loops to resume correctly.
   - Add tests for restarts with `max_batches` and `max_items`.

5. **Define distributed gather**
   - Implement `Scatter.gather/1` aggregation across child barriers when
     mode is `:distributed`.
   - Add `Scatter.gather_batches/1` for batch-level processing.

6. **Update documentation and examples**
   - `docs/20251218/03-item-reader.md`: new registry model.
   - `README.md` and examples: show provider-neutral DSL.
   - Add a compatibility note that provider DSL macros live in integration
     packages, not core.

7. **Re-run full quality gates**
   - `mix test`, `mix credo --strict`, `mix dialyzer`
   - Validate no warnings when optional integrations are not installed.

## 9. Decision Record (Optional)

If desired, add an ADR under `docs/adr/` that captures:

- Why ItemReader integration is a plugin boundary.
- The expected config-based swapping behavior.
- The guarantees for distributed gather and resume semantics.
