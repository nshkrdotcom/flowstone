# Architecture & Docs/Code Gap Review

This document highlights fundamental architectural risks and mismatches between the stated design (README/design docs/ADRs) and the current implementation.

## 1) Design Documents Diverge from Implementation

### 1.1 DAG Engine: “Runic” vs. Custom Implementation

- `docs/design/OVERVIEW.md` and `docs/adr/0002-dag-engine-persistence.md` state FlowStone uses **Runic**.
- The code uses a custom DAG implementation in `lib/flowstone/dag.ex`, and `mix.exs` does not include `:runic`.

**Impact**
- Readers are led to expect a particular algorithmic/validation behavior (and dependency), but will debug an entirely different implementation.
- ADRs lose their value if they don’t track actual code.

**Recommendation**
- Either implement Runic as designed, or update the docs/ADRs to reflect the custom DAG (and its limitations/behavior).

### 1.2 “Compile-Time Validation” is Mostly Not Present

The README and design overview emphasize compile-time safety, but the DSL in `lib/flowstone/pipeline.ex`:
- Does not validate that `execute/1` is provided.
- Does not validate that dependency assets exist or that names are unique.
- Does not validate resource requirements.

Failures (missing `execute_fn`, missing dependencies) occur at runtime inside `Executor`/`Materializer`.

**Recommendation**
- Add `__before_compile__/1` validations for:
  - `execute_fn` presence
  - dependency existence within the pipeline module
  - duplicate asset names
  - basic shape constraints for partition/resource declarations

### 1.3 Documented DSL Surface Area Exceeds Implemented DSL

Docs show macros like `io_manager`, `bucket`, `table`, `path`, `requires`, checkpoint DSL, and other features. The implemented DSL in `lib/flowstone/pipeline.ex` only provides:
- `asset/2`
- `description/1`
- `depends_on/1`
- `partition/1`
- `partitioned_by/1`
- `execute/1`

**Impact**
- The public story suggests a significantly richer DSL than exists.
- Potential user frustration and incorrect assumptions.

**Recommendation**
- Either:
  - implement the missing macros and enforce their semantics, or
  - explicitly mark these as “planned” and document what is implemented today.

### 1.4 “Integrations/UI” are Largely Stubbed Today

Several subsystems described in docs exist as placeholders or test-only shims:

- I/O managers:
  - `FlowStone.IO.S3` and `FlowStone.IO.Parquet` rely on injected functions and default to `{:error, :not_configured}` (`lib/flowstone/io/s3.ex`, `lib/flowstone/io/parquet.ex`).
  - `FlowStone.IO.Postgres` uses raw SQL and assumes existence of per-asset tables but FlowStone provides no migrations for those data tables (`lib/flowstone/io/postgres.ex`).
- UI:
  - There is no LiveView dashboard implementation in `lib/` despite documentation claims (e.g. `docs/design/OVERVIEW.md`).

**Impact**
- Users reading the docs may assume these subsystems are “ready” when they are currently scaffolding.

**Recommendation**
- Add a clear “implemented vs planned” matrix in docs.
- Consider marking stub modules as `@moduledoc false` or explicitly “experimental” until semantics are stable.

## 2) Global/Runtime State and Process Topology

### 2.1 Dual Registry Sources (persistent_term + Agent)

Assets are stored in:
- `:persistent_term` keyed by pipeline module (`lib/flowstone/pipeline.ex`)
- an Agent-based registry (`lib/flowstone/registry.ex`)

**Impact**
- Two sources of truth increase drift risk.
- `:persistent_term` updates are costly and global; frequent recompilation in dev/hot reload can have system-wide performance implications.

**Recommendation**
- Pick a single “authoritative” source for asset definitions (ideally the module itself) and treat the runtime registry as a cache (or remove it).

### 2.2 Repo Hygiene: Large Vendored `dagster/` Subtree

The root `dagster/` directory appears to be a full Dagster repository including its own `.git/`.

**Impact**
- Increases clone size and developer cognitive load.
- Nested git repos confuse common tooling and can cause accidental commits, search noise, and poor performance.

**Recommendation**
- If Dagster is needed for reference, consider:
  - moving it to a separate repo/submodule, or
  - documenting it as an explicit vendor reference and keeping it out of normal workflows.

## 3) Configuration and “Start Flags” as API

Several components are gated by `Application.get_env(:flowstone, ...)` flags (`lib/flowstone/application.ex`), and “Repo-or-fallback” decisions vary across modules:
- `FlowStone.Materializations` checks `:start_repo` and `Process.whereis/1` (`lib/flowstone/materializations.ex`)
- `FlowStone.MaterializationContext` checks only `Process.whereis/1` (`lib/flowstone/materialization_context.ex`)

**Impact**
- Behavior differs depending on which entrypoint is used and which flags are set.
- A host application starting `FlowStone.Repo` without setting `:start_repo` may see unexpected “fallback” behavior.

**Recommendation**
- Define a single, explicit configuration story:
  - either “FlowStone manages its own Repo when enabled” or
  - “FlowStone integrates into the host Repo” (preferable for libraries),
  - but avoid a hybrid that changes semantics across modules.
