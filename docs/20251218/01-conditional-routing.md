# Design Doc: Conditional Routing

**Status:** Revised Draft
**Author:** AI Assistant
**Date:** 2025-12-18
**FlowStone Version:** 0.4.0 (proposed)

## 1. Overview

### Problem Statement

FlowStone currently supports static DAG dependencies. Every declared dependency is always executed, and routing must be encoded inside asset execute functions. This makes pipelines harder to reason about and blocks Step Functions Choice migrations.

### Goals

1. Add a first-class Choice equivalent for runtime branch selection.
2. Preserve DAG visibility and lineage accuracy.
3. Ensure decisions are durable and replayable.
4. Keep optional branch outputs from blocking downstream assets.
5. Integrate cleanly with existing Oban execution and IO managers.

### Non-Goals

1. Full Step Functions ASL expression language.
2. Dynamic asset creation at runtime.
3. Cycles in the DAG.

## 2. Design Summary

Routing is modeled as a dedicated router asset that evaluates a route decision, persists it, and then allows downstream assets to proceed. Routed assets are normal assets; they are either executed or marked as skipped based on the decision.

Key design choices:

- **Single routing model**: Router assets select exactly one downstream target (or skip all). Parallel fan-out is handled by the Parallel feature, not routing.
- **No inline branch blocks**: Avoids DSL conflicts with Parallel branch syntax and keeps assets first-class.
- **Durable decisions**: Route decisions are persisted and reused on retries.
- **Optional dependencies**: Downstream assets can declare `optional_deps` to tolerate skipped branches.

## 3. DSL

### 3.1 Router Asset

```elixir
defmodule ReportPipeline do
  use FlowStone.Pipeline

  asset :initial_state do
    execute fn _ctx, input ->
      {:ok, %{search_type: input.search_type, query: input.query}}
    end
  end

  asset :identify_region_router do
    depends_on [:initial_state]

    route do
      choice :identify_region_mgrs,
        when: fn %{initial_state: %{search_type: "mgrs"}} -> true end

      default :identify_region_name
      on_error :fail
    end
  end

  asset :identify_region_mgrs do
    routed_from :identify_region_router
    depends_on [:initial_state]

    execute fn _ctx, %{initial_state: input} ->
      AWS.Lambda.invoke("identify-region-mgrs", %{mgrs: input.query})
    end
  end

  asset :identify_region_name do
    routed_from :identify_region_router
    depends_on [:initial_state]

    execute fn _ctx, %{initial_state: input} ->
      AWS.Lambda.invoke("identify-region-name", %{query: input.query})
    end
  end

  asset :store_region do
    depends_on [:identify_region_mgrs, :identify_region_name]
    optional_deps [:identify_region_mgrs, :identify_region_name]

    execute fn _ctx, deps ->
      region = deps[:identify_region_mgrs] || deps[:identify_region_name]
      {:ok, store(region)}
    end
  end
end
```

### 3.2 route fn (advanced)

For advanced routing logic, a plain function can be used instead of `route do`:

```elixir
route fn deps ->
  if deps.initial_state.search_type == "mgrs" do
    :identify_region_mgrs
  else
    :identify_region_name
  end
end
```

The return value must be one of:

- `:asset_name` - execute that asset
- `nil` - skip all routed assets
- `{:error, reason}` - fail routing (or apply `on_error` if configured)

### 3.3 routed_from and optional_deps

```elixir
asset :downstream do
  depends_on [:branch_a, :branch_b]
  optional_deps [:branch_a, :branch_b]
  execute fn _ctx, deps ->
    {:ok, deps[:branch_a] || deps[:branch_b]}
  end
end
```

`optional_deps` must be a subset of `depends_on` and only applies to downstream merges.

## 4. Execution Semantics

1. Router asset materializes normally and evaluates the route.
2. The decision is persisted and returned as the router asset output:

   ```elixir
   %{
     decision_id: "uuid",
     router_asset: :identify_region_router,
     selected_branch: :identify_region_mgrs | :identify_region_name | nil,
     available_branches: [:identify_region_mgrs, :identify_region_name]
   }
   ```

   `selected_branch` is `nil` when routing skips all branches.
3. Routed assets have an implicit dependency on the router asset.
4. When a routed asset starts, it checks the decision:
   - If selected, execute as normal.
   - If not selected, mark as skipped and return `{:ok, :skipped}` (Executor return).
     Skipped assets do not write to the IO manager.
5. Downstream assets with `optional_deps` ignore missing or skipped dependencies.

### 4.1 Replay and Idempotency

- A unique decision record exists for `(run_id, router_asset, partition)`.
- On retries, the decision is reused and never re-evaluated.
- If a decision exists but the router asset is re-run, the stored decision wins.

### 4.2 Error Handling

- Router evaluation errors are wrapped in `FlowStone.Error` and emit telemetry.
- `on_error :fail` is the default; `on_error {:fallback, :asset_name}` is supported.

## 5. Asset Struct Changes

```elixir
defstruct [
  # existing fields...
  :route_fn,
  :route_rules,          # compiled from route do
  :route_error_policy,   # :fail | {:fallback, atom}
  :routed_from,
  :optional_deps
]
```

## 6. Persistence

### 6.1 Route Decisions

```elixir
create table(:flowstone_route_decisions, primary_key: false) do
  add :id, :uuid, primary_key: true
  add :run_id, :uuid, null: false
  add :router_asset, :string, null: false
  add :partition, :string
  add :selected_branch, :string
  add :available_branches, {:array, :string}, null: false
  add :input_hash, :string
  add :metadata, :map, default: %{}
  timestamps(type: :utc_datetime_usec)
end

create unique_index(:flowstone_route_decisions, [:run_id, :router_asset, :partition])
```

### 6.2 Materialization Status

Add `:skipped` status to `flowstone_materializations` to record routed assets that were not selected.

## 7. Executor and Worker Integration

- `FlowStone.Materializer.execute/3` checks for `route_fn` and evaluates route before `execute_fn`.
- Assets with `routed_from` consult stored decisions and short-circuit as `:skipped` when not selected.
- `FlowStone.Workers.AssetWorker.check_dependencies/4` ignores missing optional deps.

## 8. DAG and Lineage

- `routed_from` adds an implicit edge from router to branch assets.
- Downstream assets with `optional_deps` record lineage only for available deps.
- Router decisions include selected branch in lineage metadata for auditability.

## 9. Telemetry

```elixir
[:flowstone, :route, :start]
[:flowstone, :route, :stop]
[:flowstone, :route, :error]
```

Metadata includes router asset, run_id, partition, selected_branch, and decision_id.

## 10. Migration from Step Functions

| Step Functions | FlowStone |
| --- | --- |
| Choice state | router asset with `route` |
| Choice rule | `choice :asset, when: fn deps -> ... end` |
| Default | `default :asset` |

## 11. Compatibility Mode Defaults

When `compatibility_mode: :step_functions` is enabled, defaults are:

- Routing: single target only; `on_error :fail`; `nil` means skip; decision persisted; unselected branches become `:skipped`.
- Parallel: `failure_mode :all_or_nothing`; all branches required; join waits for all; default join is identity if not provided.
- Scatter/Map: `failure_threshold 0.0`; `failure_mode :all_or_nothing`; `retry_strategy :individual`; `max_attempts 1`; `max_concurrent :unlimited` unless set.
- ItemReader: `reader_batch_size 1000` for S3; distributed mode only when explicitly set; reader errors fail the map unless retried.
- ItemBatcher: `on_item_error :fail_batch`; `batch_input` evaluated once at scatter start; gather receives batch results.

## 12. Open Questions Resolved

| Question | Decision | Rationale |
| --- | --- | --- |
| Dual route fn vs inline branch | Use router assets only; remove inline branches | Avoid DSL conflict with Parallel and keep assets first-class |
| Optional deps validation | Enforce subset of depends_on at compile time | Prevent invalid DAGs |
| Persist decisions | Yes, always | Deterministic replay and debugging |
| Route exceptions | Default fail, optional fallback | Aligns with FlowStone error model |
| Computed branch names | Disallow | Prevents atom leaks and invalid branches |
| Router + scatter same asset | Disallow in v1 | Avoid ambiguous semantics |

## 13. Implementation Plan

1. Add `:skipped` materialization status and optional deps handling.
2. Add route decision table and persistence helpers.
3. Extend DSL and asset struct for routing metadata.
4. Add routing evaluation and routed asset gating to Materializer.
5. Extend telemetry and lineage metadata.

## 14. Testing Strategy

- Unit tests for route rule compilation and decision replay.
- Integration tests for optional deps and skipped branches.
- Failure tests for router exceptions and fallback behavior.
