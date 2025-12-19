# Design Doc: Parallel Branches

**Status:** Revised Draft
**Author:** AI Assistant
**Date:** 2025-12-18
**FlowStone Version:** 0.4.0 (proposed)

## 1. Overview

### Problem Statement

Scatter provides dynamic fan-out over homogeneous items. Step Functions Parallel provides static, heterogeneous branches that run concurrently and then join. FlowStone needs a native Parallel equivalent to replace large Step Functions workflows.

### Goals

1. Execute multiple heterogeneous workflows concurrently.
2. Join branch outputs deterministically.
3. Preserve DAG lineage and observability.
4. Allow nested parallelism and scatter.
5. Integrate with Oban and existing materializations.

### Non-Goals

1. Cross-branch dependencies.
2. Streaming joins (join waits for branches).
3. Replacing scatter.

## 2. Design Summary

Parallel is modeled as a coordinator asset that schedules terminal assets for each branch and then runs a join function when branch materializations complete. Branches reference existing assets in the registry rather than defining nested asset blocks.

Key design choices:

- **Branch references**: Branches refer to terminal assets by name.
- **Durable coordination**: Parallel execution state is stored in the database.
- **Join loads results via IO**: Avoids storing large results in the parallel tables.

## 3. DSL

```elixir
asset :get_data do
  depends_on [:store_region]

  parallel do
    branch :maps, final: :generate_maps
    branch :news, final: :get_front_pages
    branch :web_sources, final: :process_keywords, required: false
  end

  parallel_options do
    failure_mode :partial
    timeout :timer.minutes(30)
  end

  join fn branches, deps ->
    %{
      maps: branches.maps,
      news: branches.news,
      web_sources: branches.web_sources,
      region: deps.store_region
    }
  end
end
```

### 3.1 Branch Options

- `final:` (required) - terminal asset for the branch
- `required:` (optional, default true) - must succeed for join
- `timeout:` (optional) - per-branch timeout

### 3.2 Join Function

`join/1` or `join/2` receives a map of branch results.

For `failure_mode :all_or_nothing`:

- `branches` contains values only (all branches succeeded)

For `failure_mode :partial`:

- `branches` contains `{:ok, value} | {:error, reason} | :skipped`

## 4. Execution Semantics

1. Parallel asset materializes and creates a parallel execution record.
2. Each branch terminal asset is enqueued with the same `run_id`.
3. Branch assets execute normally via existing FlowStone machinery.
4. A join worker watches branch materializations and executes join when ready.
5. Join output is stored as the parallel asset result.

### 4.1 Branch Completion

Branch completion is derived from materialization status:

- `:success` -> `{:ok, value}`
- `:failed` -> `{:error, reason}`
- `:skipped` -> `:skipped`

### 4.2 Failure Handling

- `failure_mode :all_or_nothing` fails on any failed required branch.
- `failure_mode :partial` allows join when all required branches are successful.

## 5. Asset Struct Changes

```elixir
defstruct [
  # existing fields...
  :parallel_branches,   # %{branch_name => %ParallelBranch{}}
  :parallel_options,    # %{failure_mode: ..., timeout: ...}
  :join_fn
]

defmodule FlowStone.ParallelBranch do
  defstruct [
    :name,
    :final,
    required: true,
    timeout: nil
  ]
end
```

## 6. Persistence

```elixir
create table(:flowstone_parallel_executions, primary_key: false) do
  add :id, :uuid, primary_key: true
  add :run_id, :uuid, null: false
  add :parent_asset, :string, null: false
  add :partition, :string
  add :status, :string, null: false
  add :branch_count, :integer, null: false
  add :completed_count, :integer, default: 0
  add :failed_count, :integer, default: 0
  add :metadata, :map, default: %{}
  timestamps(type: :utc_datetime_usec)
end

create table(:flowstone_parallel_branches, primary_key: false) do
  add :id, :uuid, primary_key: true
  add :execution_id, references(:flowstone_parallel_executions, type: :uuid), null: false
  add :branch_name, :string, null: false
  add :final_asset, :string, null: false
  add :status, :string, null: false
  add :materialization_id, :uuid
  add :error, :map
  add :started_at, :utc_datetime_usec
  add :completed_at, :utc_datetime_usec
  timestamps(type: :utc_datetime_usec)
end

create unique_index(:flowstone_parallel_branches, [:execution_id, :branch_name])
```

## 7. DAG and Lineage

- The parallel asset has virtual dependencies on branch final assets.
- Lineage for the parallel asset includes branch final assets.
- Branch assets remain normal assets with full lineage.

## 8. Telemetry

```elixir
[:flowstone, :parallel, :start]
[:flowstone, :parallel, :stop]
[:flowstone, :parallel, :error]
[:flowstone, :parallel, :branch_start]
[:flowstone, :parallel, :branch_complete]
[:flowstone, :parallel, :branch_fail]
```

## 9. Examples

### 9.1 Parallel with Required and Optional Branches

```elixir
asset :fetch_external_data do
  parallel do
    branch :primary, final: :call_primary
    branch :backup, final: :call_backup, required: false
  end

  parallel_options do
    failure_mode :partial
  end

  join fn branches ->
    case branches.primary do
      {:ok, value} -> value
      _ ->
        case branches.backup do
          {:ok, value} -> value
          _ -> raise "All sources failed"
        end
    end
  end
end
```

## 10. Migration from Step Functions

| Step Functions | FlowStone |
| --- | --- |
| Parallel state | `parallel` block |
| Branches[] | `branch :name, final: :asset` |
| Result merge | `join fn` |

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
| Branch assets defined inline | No, reference existing assets | Keeps registry consistent |
| Branch inheritance of deps | No implicit deps | Keeps DAG explicit |
| Join interface | Branch map with status tuples in partial mode | Clear failure semantics |
| Result storage | Store materialization id only | Avoid DB bloat |
| Timeout semantics | Per-branch timeout; overall timeout in options | Avoids hard cancellation |

## 13. Implementation Plan

1. Add parallel metadata to Asset struct and DSL macros.
2. Implement parallel coordinator and join worker using Oban.
3. Add persistence tables and telemetry events.
4. Update DAG and lineage integration.

## 14. Testing Strategy

- Integration tests for partial failure and required branches.
- Tests for join behavior with skipped branches.
- Nested parallel and scatter combinations.

