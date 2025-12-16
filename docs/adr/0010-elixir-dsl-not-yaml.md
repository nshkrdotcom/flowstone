# ADR-0010: Elixir DSL (Not YAML)

## Status
Accepted

## Context

YAML-based pipeline definitions (e.g., in `pipeline_ex`) commonly introduce:

- runtime-only validation (typos and schema errors discovered late)
- poor IDE support (no navigation/refactoring)
- duplicated validation logic and unclear semantics
- limited expressiveness for complex orchestration logic

FlowStone targets Elixir/BEAM teams and prioritizes compile-time tooling and explicit, testable code.

## Decision

### 1. Use an Elixir Macro DSL as the Primary Interface

Assets are defined in modules using `use FlowStone.Pipeline` and macros such as:

- `asset/2`
- `description/1`
- `depends_on/1`
- `partition/1`
- `partitioned_by/1`
- `execute/1`

Implementation: `lib/flowstone/pipeline.ex`.

### 2. Store Asset Definitions on the Module

After compilation, asset definitions are cached per pipeline module so that FlowStone can retrieve them at runtime without re-evaluating macros.

Current implementation uses `:persistent_term` keyed by `{PipelineModule, :flowstone_assets}`.

### 3. Validation Strategy

FlowStone performs essential correctness checks when building a DAG from assets (cycle detection, ordering) and when executing materializations (missing `execute_fn`, missing dependencies, etc.).

Additional compile-time validation (e.g., ensuring each asset has an `execute/1`, dependency existence within a pipeline, duplicate name detection) is compatible with this decision and can be incrementally added in the DSL.

## Consequences

### Positive

1. Stronger tooling support (mix/Elixir compiler, editor integration).
2. Full expressiveness of Elixir for dynamic asset generation and reuse.
3. Clear, testable asset definitions without runtime parsing layers.

### Negative

1. Non-Elixir users cannot author pipelines directly.
2. Compile-time caching introduces operational considerations (e.g., `:persistent_term` update costs on recompilation).

## References

- `lib/flowstone/pipeline.ex`
- `lib/flowstone/asset.ex`
- `docs/adr/0001-asset-first-orchestration.md`
