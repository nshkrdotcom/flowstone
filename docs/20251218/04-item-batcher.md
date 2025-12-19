# Design Doc: ItemBatcher

**Status:** Implemented
**Author:** AI Assistant
**Date:** 2025-12-18
**FlowStone Version:** 0.4.0 (proposed)

## 1. Overview

### Problem Statement

Scatter currently executes one job per item. For workloads like ECS tasks or batch APIs, per-item execution is inefficient. Step Functions ItemBatcher groups items into batches with shared context. FlowStone needs a native batching feature for scatter.

### Goals

1. Batch scatter items into groups of N or by size.
2. Provide shared batch input context.
3. Preserve scatter concurrency and failure handling.
4. Keep compatibility with existing scatter execution.

### Non-Goals

1. Streaming batch results.
2. Automatic dynamic batch sizing (v1).

## 2. Design Summary

Batching is applied after item selection. Each batch becomes a scatter instance. Batch context is added to `FlowStone.Context`, but `scatter_key` remains available as batch metadata for compatibility.

## 3. DSL

```elixir
asset :embed_summarized_articles do
  depends_on [:summarize_artifacts, :region]

  scatter_from :s3 do
    bucket fn %{region: r} -> "example-data-#{r.environment}" end
    prefix fn %{region: r} -> r.summarized_articles_path end
  end

  batch_options do
    max_items_per_batch 20
    batch_input fn deps ->
      %{
        environment: deps.region.environment,
        region_uuid: deps.region.uuid,
        region_id: deps.region.id
      }
    end
    on_item_error :fail_batch
  end

  scatter_options do
    max_concurrent 100
    failure_threshold 0.5
  end

  execute fn ctx, _deps ->
    ECS.run_task("embed-s3-docs", %{
      environment: ctx.batch_input.environment,
      region_uuid: ctx.batch_input.region_uuid,
      bucket_object_keys: Enum.map(ctx.batch_items, & &1.key)
    })
  end
end
```

## 4. Batch Context

`FlowStone.Context` gains batch fields but preserves `scatter_key`:

```elixir
%FlowStone.Context{
  scatter_key: %{_batch: true, index: 3, item_count: 20},
  batch_index: 3,
  batch_count: 10,
  batch_items: [...],
  batch_input: %{...}
}
```

## 5. Batching Strategies

- Fixed size: `max_items_per_batch`
- Size-based: `max_bytes_per_batch` + `size_fn`
- Grouping: `group_by` + `max_items_per_group`
- Custom: `batch_fn`

Empty batches are filtered. If a single item exceeds size limits, it becomes a single-item batch.

## 6. Failure Semantics

- Default `on_item_error :fail_batch`.
- Failure thresholds apply to batches (not items).
- Optional future mode: `:collect_errors` for partial batch results.

## 7. Gather Semantics

By default, gather receives batch results:

```elixir
gather fn batch_results ->
  total =
    batch_results
    |> Map.values()
    |> Enum.map(& &1.processed)
    |> Enum.sum()

  %{total_processed: total, batches: map_size(batch_results)}
end
```

A helper can unbatch for item-level aggregation in v2.

## 8. Persistence

- Barrier stores batching metadata and batch count.
- Results store per-batch metadata; batch items may be stored inline or externally.

```elixir
alter table(:flowstone_scatter_barriers) do
  add :batching_enabled, :boolean, default: false
  add :batch_count, :integer
  add :batch_options, :map
end

alter table(:flowstone_scatter_results) do
  add :batch_index, :integer
  add :batch_items, {:array, :map}
  add :batch_input, :map
end
```

## 9. Telemetry

```elixir
[:flowstone, :scatter, :batch_create]
[:flowstone, :scatter, :batch_start]
[:flowstone, :scatter, :batch_complete]
[:flowstone, :scatter, :batch_fail]
```

## 10. Migration from Step Functions

| Step Functions | FlowStone |
| --- | --- |
| ItemBatcher MaxItemsPerBatch | `max_items_per_batch` |
| ItemBatcher BatchInput | `batch_input fn` |
| $.Items | `ctx.batch_items` |
| $.BatchInput | `ctx.batch_input` |

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
| ctx.scatter_key change | Preserve scatter_key as batch metadata | Avoid breaking existing code |
| Partial item errors | Fail batch (v1) | Matches Step Functions |
| Gather input | Batch results only | Simpler and explicit |
| Dynamic batch sizing | Not in v1 | Complexity without evidence |
| Batch ordering | Parallel by default | Keeps throughput |
| Empty batches | Filter and warn | Avoid wasted jobs |
| batch_input timing | Evaluate once at scatter start | Matches Step Functions |

## 13. Implementation Plan

1. Add batch fields to `FlowStone.Context`.
2. Implement `BatchOptions` and batcher logic.
3. Add batch-aware scatter execution and batch worker.
4. Extend persistence and telemetry.

## 14. Testing Strategy

- Unit tests for batching strategies and edge cases.
- Integration tests for batch failure thresholds.
- Compatibility tests for existing scatter assets.

