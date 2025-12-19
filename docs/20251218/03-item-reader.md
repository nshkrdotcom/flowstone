# Design Doc: ItemReader for Scatter

**Status:** Revised Draft
**Author:** AI Assistant
**Date:** 2025-12-18
**FlowStone Version:** 0.4.0 (proposed)

## 1. Overview

### Problem Statement

Scatter currently requires building an in-memory list of scatter keys. This does not scale for large datasets and does not match Step Functions Distributed Map with ItemReader.

### Goals

1. Support reading scatter items from external sources (S3, DynamoDB, Postgres, custom).
2. Enable scalable, incremental item retrieval.
3. Provide durable checkpoints for retries and resume.
4. Preserve existing scatter features (rate limit, failure thresholds, retries).
5. Support distributed mode for very large datasets.

### Non-Goals

1. Unbounded streaming beyond a bounded read window.
2. Full ASL ItemReader parity.
3. Automatic item transformations beyond `item_selector`.

## 2. Design Summary

Introduce `scatter_from` and an ItemReader behavior. Items are read in pages and transformed by `item_selector` into scatter keys. Inline mode streams items into scatter results in batches; distributed mode runs a dedicated reader worker and creates sub-barriers per batch.

## 3. DSL

```elixir
asset :fetch_web_artifacts do
  depends_on [:region, :runtime_config]

  scatter_from :s3 do
    bucket fn deps -> deps.runtime_config.s3.bucket_name end
    prefix fn deps -> deps.region.scrape_urls_path end
    max_items 250
    reader_batch_size 1000
  end

  item_selector fn item, deps ->
    %{
      key: item.key,
      bucket: deps.runtime_config.s3.bucket_name,
      region_id: deps.region.id
    }
  end

  scatter_options do
    mode :distributed
    max_concurrent 50
    failure_threshold 0.5
    batch_size 1000
    max_batches 50
  end

  execute fn ctx, _deps ->
    Lambda.invoke("get-web-source-artifact", ctx.scatter_key)
  end
end
```

### 3.1 Source Config Macros

`scatter_from` accepts source-specific config macros (all values can be literals or `fn deps -> ... end`):

- **S3**: `bucket`, `prefix`, `start_after`, `suffix`, `reader_batch_size`, `max_items`, `consistency_delay_ms`
- **DynamoDB**: `table`, `index`, `key_condition`, `filter_expression`, `expression_attribute_values`,
  `expression_attribute_names`, `projection_expression`, `consistent_read`, `reader_batch_size`, `max_items`
- **Postgres**: `query`, `cursor_field`, `order`, `start_after`, `row_selector`, `repo`,
  `reader_batch_size`, `max_items`
- **Custom**: `init`, `read` (required); `count`, `checkpoint`, `restore`, `close` (optional)

## 4. ItemReader Behavior

```elixir
defmodule FlowStone.Scatter.ItemReader do
  @type state :: term()
  @type item :: map()
  @type config :: map()
  @type deps :: map()

  @callback init(config(), deps()) :: {:ok, state()} | {:error, term()}
  @callback read(state(), batch_size :: pos_integer()) ::
              {:ok, [item()], state() | :halt} | {:error, term()}
  @callback count(state()) :: {:ok, non_neg_integer()} | :unknown
  @callback checkpoint(state()) :: map()
  @callback restore(state(), checkpoint :: map()) :: state()
  @callback close(state()) :: :ok
end
```

All state must be JSON-serializable via `checkpoint/1`.

## 5. Execution Modes

### 5.1 Inline Mode (default)

- Coordinator initializes reader.
- Items are read in pages and inserted into scatter results in batches.
- Scatter jobs are enqueued incrementally.
- Barrier stores counts only; scatter keys live in results.

### 5.2 Distributed Mode

- A reader worker reads pages and creates sub-barriers per batch.
- Each batch enqueues scatter jobs for its items.
- Reader checkpoints are stored on the parent barrier.
- `FlowStone.Scatter.start_distributed_reader/3` creates the parent barrier and enqueues
  `FlowStone.Workers.ItemReaderWorker` when Oban is running.

## 6. Asset Struct Changes

```elixir
defstruct [
  # existing fields...
  :scatter_source,
  :scatter_source_config,
  :item_selector_fn,
  :scatter_mode
]
```

## 7. Persistence Changes

- `flowstone_scatter_barriers` stores counts, status, and reader checkpoint.
- `flowstone_scatter_results` stores scatter keys and per-item status.
- Large runs avoid storing all keys in the barrier record.
- Barrier uniqueness by `{run_id, asset_name, partition}` is removed to allow multiple sub-barriers.
- `FlowStone.Scatter.start_barrier/1` and `FlowStone.Scatter.insert_results/2` support streaming inserts.

```elixir
alter table(:flowstone_scatter_barriers) do
  add :mode, :string, default: "inline"
  add :reader_checkpoint, :jsonb
  add :parent_barrier_id, references(:flowstone_scatter_barriers, type: :uuid)
  add :batch_index, :integer
end
```

## 8. Built-in Readers

### 8.1 S3

- Uses `ExAws.S3.list_objects_v2`.
- Caps `max_keys` at 1000 per request.
- Supports `start_after` and `suffix` filters.
- Optional `consistency_delay_ms` to avoid eventual consistency gaps.
- Raises a clear error on init if `ex_aws_s3` is not available.

### 8.2 DynamoDB

- Uses `scan` or `query` based on `key_condition`.
- Requires `ex_aws_dynamo` as an optional dependency.
- Raises a clear error on init if `ex_aws_dynamo` is not available.

### 8.3 Postgres

- Uses keyset pagination with `cursor_field` and `order`.
- Supports `row_selector` to map rows into item maps.

### 8.4 Custom

- `init` and `read` callbacks define custom pagination logic.

## 9. Error Handling and Retries

- Reader errors are wrapped in `FlowStone.Error` and emit telemetry.
- Retry behavior follows scatter retry settings.
- Transient errors can be retried in `read/2` or by the reader worker.

## 10. Telemetry

```elixir
[:flowstone, :item_reader, :init]
[:flowstone, :item_reader, :read]
[:flowstone, :item_reader, :complete]
[:flowstone, :item_reader, :error]
[:flowstone, :scatter, :batch_start]
[:flowstone, :scatter, :batch_complete]
```

## 11. Migration from Step Functions

| Step Functions | FlowStone |
| --- | --- |
| ItemReader (S3 listObjectsV2) | `scatter_from :s3` |
| ItemSelector | `item_selector fn` |
| MaxConcurrency | `scatter_options max_concurrent` |
| ToleratedFailurePercentage | `failure_threshold` |
| Mode DISTRIBUTED | `scatter_options mode :distributed` |

## 12. Compatibility Mode Defaults

When `compatibility_mode: :step_functions` is enabled, defaults are:

- Routing: single target only; `on_error :fail`; `nil` means skip; decision persisted; unselected branches become `:skipped`.
- Parallel: `failure_mode :all_or_nothing`; all branches required; join waits for all; default join is identity if not provided.
- Scatter/Map: `failure_threshold 0.0`; `failure_mode :all_or_nothing`; `retry_strategy :individual`; `max_attempts 1`; `max_concurrent :unlimited` unless set.
- ItemReader: `reader_batch_size 1000` for S3; distributed mode only when explicitly set; reader errors fail the map unless retried.
- ItemBatcher: `on_item_error :fail_batch`; `batch_input` evaluated once at scatter start; gather receives batch results.

## 13. Open Questions Resolved

| Question | Decision | Rationale |
| --- | --- | --- |
| Checkpoint granularity | Per page | Reduces reprocessing on resume |
| S3 filters | Suffix + start_after only | Keep core simple |
| Read errors | Retry then fail scatter | Consistent with scatter semantics |
| Inline memory limits | Stream to results and enforce max inline items | Avoid large in-memory lists |
| ExAws dependency | Optional with clear error if missing | Avoid forced dependency |
| Postgres pooling | Coordinator-only reader or keyset paging | Protect pool |

## 14. Implementation Plan

1. Refactor scatter to store keys only in results.
2. Add ItemReader behavior and scatter_from DSL.
3. Implement S3 reader, then DynamoDB and Postgres readers.
4. Implement distributed mode with reader worker and sub-barriers.
5. Add telemetry and metrics.

## 15. Testing Strategy

- Pagination tests for each reader.
- Resume tests using stored checkpoints.
- Large-run tests to verify memory behavior.
