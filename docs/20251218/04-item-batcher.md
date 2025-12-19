# Design Doc: ItemBatcher

**Status:** Draft
**Author:** AI Assistant
**Date:** 2025-12-18
**FlowStone Version:** 0.4.0 (proposed)

## 1. Overview

### Problem Statement

FlowStone's current Scatter executes one job per scatter key. This is efficient when each item requires substantial processing (e.g., Lambda invocation, API call). However, some workloads benefit from **batch processing**:

1. **ECS/Container tasks** - Container startup overhead makes one-item-per-container inefficient
2. **Bulk database operations** - Batch inserts/updates are faster than individual writes
3. **Embedding APIs** - Many services accept batch requests (up to N items per call)
4. **File processing** - Reading/writing many small files is slower than batched I/O

Your production Step Functions state machine uses **ItemBatcher** for ECS tasks:

```json
"Embed Summarized Articles": {
  "Type": "Map",
  "ItemProcessor": {
    "ProcessorConfig": {
      "Mode": "DISTRIBUTED",
      "ExecutionType": "STANDARD"
    },
    "StartAt": "Load Articles",
    "States": {
      "Load Articles": {
        "Type": "Task",
        "Resource": "arn:aws:states:::ecs:runTask.sync",
        "Parameters": {
          "Overrides": {
            "ContainerOverrides": [{
              "Environment": [{
                "Name": "BUCKET_OBJECT_KEYS",
                "Value.$": "States.JsonToString($.Items)"
              }]
            }]
          }
        }
      }
    }
  },
  "ItemBatcher": {
    "MaxItemsPerBatch": 20,
    "BatchInput": {
      "environment.$": "$.state.environment",
      "region_uuid.$": "$.result.region.output.Uuid"
    }
  },
  "MaxConcurrency": 100
}
```

Key characteristics:
- Items grouped into batches of N
- Each batch processed as a unit (one ECS task per batch)
- Common context (`BatchInput`) shared across all items in batch
- Reduces overhead while maintaining parallelism

### Goals

1. Enable batch-based scatter execution
2. Support configurable batch sizes and batching strategies
3. Provide batch-level context injection (`batch_input`)
4. Integrate with existing scatter features (rate limiting, failure handling)
5. Support both "batch of keys" and "batch of results" patterns

### Non-Goals

1. Dynamic batch sizing based on item properties (use custom logic)
2. Cross-batch dependencies (batches are independent)
3. Streaming batch results (batch completes atomically)

## 2. Design

### 2.1 Core Concept: `batch_options` DSL

Extend scatter with a `batch_options` block that groups items into batches:

```elixir
defmodule EmbeddingPipeline do
  use FlowStone.Pipeline

  asset :embed_articles do
    depends_on [:summarized_articles, :region]

    scatter_from :s3 do
      bucket fn %{region: r} -> "example-data-#{r.environment}-data" end
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
    end

    scatter_options do
      max_concurrent 100
      failure_threshold 0.5
    end

    execute fn ctx, _deps ->
      # ctx.batch_input - common context for all items
      # ctx.batch_items - list of items in this batch
      ECS.run_task("embed-s3-docs", %{
        environment: ctx.batch_input.environment,
        region_uuid: ctx.batch_input.region_uuid,
        bucket_object_keys: Enum.map(ctx.batch_items, & &1.key)
      })
    end
  end
end
```

### 2.2 Execution Model

```
Items from ItemReader or scatter fn:
[item1, item2, item3, item4, item5, item6, item7]

With max_items_per_batch: 3:

Batch 1: [item1, item2, item3] + batch_input
Batch 2: [item4, item5, item6] + batch_input
Batch 3: [item7]              + batch_input  (partial batch)

Each batch becomes ONE scatter instance (one Oban job)
```

### 2.3 Batching Strategies

#### Fixed Size (default)
```elixir
batch_options do
  max_items_per_batch 20
end
```

#### Size-Based Batching
```elixir
batch_options do
  max_bytes_per_batch 1_000_000  # 1MB total
  size_fn fn item -> item.size end
end
```

#### Key-Based Grouping
```elixir
batch_options do
  group_by fn item -> item.category end
  max_items_per_group 50
end
```

#### Custom Batching
```elixir
batch_options do
  batch_fn fn items ->
    # Custom grouping logic
    Enum.chunk_by(items, & &1.priority)
  end
end
```

### 2.4 Batch Context

The execute function receives enhanced context when batching is enabled:

```elixir
%FlowStone.Context{
  # Standard fields
  asset_name: :embed_articles,
  run_id: "...",
  partition: ~D[2025-01-15],

  # Batch-specific fields (only present when batching)
  batch_index: 0,           # Which batch (0-indexed)
  batch_count: 10,          # Total batches
  batch_items: [...],       # List of items in this batch
  batch_input: %{...},      # Common context from batch_input fn

  # Not present when batching (scatter_key is for single-item scatter)
  scatter_key: nil
}
```

### 2.5 Asset Struct Changes

```elixir
defstruct [
  # ... existing fields ...

  # Batch options
  :batch_options,  # %BatchOptions{} struct
]

defmodule FlowStone.Scatter.BatchOptions do
  defstruct [
    :max_items_per_batch,    # integer
    :max_bytes_per_batch,    # integer (optional)
    :size_fn,                # fn(item) -> integer (for byte-based)
    :group_by_fn,            # fn(item) -> term (for grouping)
    :max_items_per_group,    # integer (for grouping)
    :batch_fn,               # fn(items) -> [[item]] (custom)
    :batch_input_fn,         # fn(deps) -> map (common context)
    :include_batch_metadata, # boolean - include index/count in context
  ]
end
```

### 2.6 Persistence Schema

```elixir
# Extend flowstone_scatter_results to support batch tracking
defmodule FlowStone.Repo.Migrations.AddBatchSupport do
  use Ecto.Migration

  def change do
    alter table(:flowstone_scatter_barriers) do
      # Batching config
      add :batching_enabled, :boolean, default: false
      add :batch_count, :integer
      add :batch_options, :map
    end

    # Each result record now represents a batch (when batching enabled)
    # or a single item (when not batching)
    alter table(:flowstone_scatter_results) do
      add :batch_index, :integer
      add :batch_items, {:array, :map}  # Original items in batch
      add :batch_input, :map            # Common batch context
    end
  end
end
```

## 3. Implementation

### 3.1 DSL Macros

```elixir
defmodule FlowStone.Pipeline do
  # ... existing macros ...

  @doc """
  Configure batch processing for scatter.
  """
  defmacro batch_options(do: block) do
    quote do
      var!(batch_opts) = %FlowStone.Scatter.BatchOptions{}
      unquote(block)
      var!(current_asset) = %{var!(current_asset) | batch_options: var!(batch_opts)}
    end
  end

  defmacro max_items_per_batch(value) do
    quote do
      var!(batch_opts) = %{var!(batch_opts) | max_items_per_batch: unquote(value)}
    end
  end

  defmacro max_bytes_per_batch(value) do
    quote do
      var!(batch_opts) = %{var!(batch_opts) | max_bytes_per_batch: unquote(value)}
    end
  end

  defmacro size_fn(fun) do
    quote do
      var!(batch_opts) = %{var!(batch_opts) | size_fn: unquote(fun)}
    end
  end

  defmacro group_by(fun) do
    quote do
      var!(batch_opts) = %{var!(batch_opts) | group_by_fn: unquote(fun)}
    end
  end

  defmacro max_items_per_group(value) do
    quote do
      var!(batch_opts) = %{var!(batch_opts) | max_items_per_group: unquote(value)}
    end
  end

  defmacro batch_fn(fun) do
    quote do
      var!(batch_opts) = %{var!(batch_opts) | batch_fn: unquote(fun)}
    end
  end

  defmacro batch_input(fun) do
    quote do
      var!(batch_opts) = %{var!(batch_opts) | batch_input_fn: unquote(fun)}
    end
  end
end
```

### 3.2 Batcher Module

```elixir
defmodule FlowStone.Scatter.Batcher do
  @moduledoc """
  Groups scatter items into batches based on configuration.
  """

  alias FlowStone.Scatter.BatchOptions

  @doc """
  Create batches from a list of items based on batch options.
  Returns a list of batch structs.
  """
  @spec create_batches([map()], BatchOptions.t(), map()) :: [Batch.t()]
  def create_batches(items, batch_opts, deps) do
    batches = do_batch(items, batch_opts)
    batch_input = get_batch_input(batch_opts, deps)

    batches
    |> Enum.with_index()
    |> Enum.map(fn {batch_items, index} ->
      %Batch{
        index: index,
        items: batch_items,
        input: batch_input,
        item_count: length(batch_items)
      }
    end)
  end

  defp do_batch(items, %{batch_fn: batch_fn}) when not is_nil(batch_fn) do
    batch_fn.(items)
  end

  defp do_batch(items, %{group_by_fn: group_fn, max_items_per_group: max})
       when not is_nil(group_fn) do
    items
    |> Enum.group_by(group_fn)
    |> Enum.flat_map(fn {_key, group_items} ->
      Enum.chunk_every(group_items, max || 100)
    end)
  end

  defp do_batch(items, %{max_bytes_per_batch: max_bytes, size_fn: size_fn})
       when not is_nil(max_bytes) and not is_nil(size_fn) do
    chunk_by_size(items, max_bytes, size_fn)
  end

  defp do_batch(items, %{max_items_per_batch: max}) when not is_nil(max) do
    Enum.chunk_every(items, max)
  end

  defp do_batch(items, _opts) do
    # No batching config - single batch with all items
    [items]
  end

  defp chunk_by_size(items, max_bytes, size_fn) do
    {batches, current_batch, _current_size} =
      Enum.reduce(items, {[], [], 0}, fn item, {batches, current, size} ->
        item_size = size_fn.(item)

        if size + item_size > max_bytes and current != [] do
          # Start new batch
          {[Enum.reverse(current) | batches], [item], item_size}
        else
          # Add to current batch
          {batches, [item | current], size + item_size}
        end
      end)

    # Don't forget the last batch
    all_batches = if current_batch != [] do
      [Enum.reverse(current_batch) | batches]
    else
      batches
    end

    Enum.reverse(all_batches)
  end

  defp get_batch_input(%{batch_input_fn: nil}, _deps), do: %{}
  defp get_batch_input(%{batch_input_fn: fun}, deps), do: fun.(deps)
end

defmodule FlowStone.Scatter.Batch do
  @moduledoc """
  Represents a batch of items to be processed together.
  """

  defstruct [
    :index,       # Batch index (0-based)
    :items,       # List of items in batch
    :input,       # Common batch input
    :item_count,  # Number of items
    :id           # Unique batch ID (generated)
  ]

  def new(attrs) do
    %__MODULE__{
      index: attrs[:index],
      items: attrs[:items],
      input: attrs[:input] || %{},
      item_count: length(attrs[:items]),
      id: Ecto.UUID.generate()
    }
  end
end
```

### 3.3 Scatter Coordinator Integration

```elixir
defmodule FlowStone.Scatter.Coordinator do
  # ... existing code ...

  def execute(asset, deps, opts) do
    items = get_items(asset, deps, opts)

    case asset.batch_options do
      nil ->
        # Standard scatter - one job per item
        execute_unbatched(asset, items, deps, opts)

      batch_opts ->
        # Batched scatter - one job per batch
        execute_batched(asset, items, batch_opts, deps, opts)
    end
  end

  defp execute_batched(asset, items, batch_opts, deps, opts) do
    batches = Batcher.create_batches(items, batch_opts, deps)

    {:ok, barrier} = Scatter.create_barrier(
      run_id: opts[:run_id],
      asset_name: asset.name,
      partition: opts[:partition],
      scatter_keys: Enum.map(batches, &batch_to_key/1),
      options: asset.scatter_options,
      batching_enabled: true,
      batch_count: length(batches),
      batch_options: serialize_batch_opts(batch_opts)
    )

    # Create batch result records
    Enum.each(batches, fn batch ->
      Scatter.Result.create_batch_result(
        barrier.id,
        batch.index,
        batch.items,
        batch.input
      )
    end)

    # Enqueue batch jobs
    enqueue_batch_jobs(barrier, batches, asset, deps, opts)

    {:ok, barrier}
  end

  defp batch_to_key(batch) do
    %{
      _batch: true,
      index: batch.index,
      item_count: batch.item_count,
      batch_id: batch.id
    }
  end

  defp enqueue_batch_jobs(barrier, batches, asset, deps, opts) do
    jobs = Enum.map(batches, fn batch ->
      %{
        barrier_id: barrier.id,
        batch_index: batch.index,
        batch_id: batch.id,
        asset_name: to_string(asset.name),
        run_id: opts[:run_id],
        partition: opts[:partition] && Partition.serialize(opts[:partition])
      }
    end)

    FlowStone.Workers.ScatterBatchWorker.enqueue_many(jobs, asset.scatter_options)
  end
end
```

### 3.4 Batch Worker

```elixir
defmodule FlowStone.Workers.ScatterBatchWorker do
  @moduledoc """
  Processes a batch of scatter items as a single unit.
  """

  use Oban.Worker,
    queue: :scatter_batches,
    max_attempts: 3

  alias FlowStone.{Scatter, Materializer, RunConfig}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{
      "barrier_id" => barrier_id,
      "batch_index" => batch_index,
      "batch_id" => batch_id,
      "asset_name" => asset_name,
      "run_id" => run_id,
      "partition" => partition
    } = args

    # Load batch data
    {:ok, batch_result} = Scatter.Result.get_batch(barrier_id, batch_index)
    {:ok, barrier} = Scatter.get_barrier(barrier_id)

    # Get runtime config and asset
    config = RunConfig.get(run_id)
    {:ok, asset} = Registry.lookup(config.registry, String.to_existing_atom(asset_name))

    # Build batch context
    context = %FlowStone.Context{
      asset_name: asset.name,
      run_id: run_id,
      partition: partition && Partition.deserialize(partition),
      batch_index: batch_index,
      batch_count: barrier.batch_count,
      batch_items: batch_result.batch_items,
      batch_input: batch_result.batch_input
    }

    # Execute
    case safe_execute(asset, context, config) do
      {:ok, result} ->
        Scatter.complete(barrier_id, %{_batch: true, index: batch_index}, result)
        :ok

      {:error, reason} ->
        Scatter.fail(barrier_id, %{_batch: true, index: batch_index}, reason)
        {:error, reason}
    end
  end

  defp safe_execute(asset, context, config) do
    deps = load_dependencies(asset, context, config)
    asset.execute_fn.(context, deps)
  rescue
    e -> {:error, Exception.format(:error, e, __STACKTRACE__)}
  end

  @doc """
  Enqueue multiple batch jobs efficiently.
  """
  def enqueue_many(jobs, scatter_opts) do
    oban_jobs = Enum.map(jobs, fn job_args ->
      new(job_args, build_oban_opts(scatter_opts))
    end)

    Oban.insert_all(oban_jobs)
  end

  defp build_oban_opts(scatter_opts) do
    opts = []

    opts = if scatter_opts[:queue] do
      [{:queue, scatter_opts[:queue]} | opts]
    else
      opts
    end

    opts = if scatter_opts[:priority] do
      [{:priority, scatter_opts[:priority]} | opts]
    else
      opts
    end

    opts
  end
end
```

### 3.5 Context Enhancement

```elixir
defmodule FlowStone.Context do
  defstruct [
    # Existing fields
    :asset_name,
    :run_id,
    :partition,
    :resources,
    :started_at,
    :scatter_key,      # For single-item scatter

    # Batch fields (mutually exclusive with scatter_key)
    :batch_index,      # Index of current batch
    :batch_count,      # Total number of batches
    :batch_items,      # Items in this batch
    :batch_input,      # Common batch context

    # Signal gate fields
    :gate
  ]

  @doc """
  Check if this context is for a batched execution.
  """
  def batched?(%__MODULE__{batch_items: items}) when is_list(items), do: true
  def batched?(_), do: false

  @doc """
  Get the number of items being processed.
  Returns 1 for single-item scatter, N for batched.
  """
  def item_count(%__MODULE__{batch_items: items}) when is_list(items), do: length(items)
  def item_count(%__MODULE__{scatter_key: key}) when not is_nil(key), do: 1
  def item_count(_), do: 0
end
```

## 4. Examples

### 4.1 Your ECS Embedding Pattern

```elixir
defmodule ReportPipeline do
  use FlowStone.Pipeline

  asset :embed_summarized_articles do
    depends_on [:summarize_artifacts, :region]

    scatter_from :s3 do
      bucket fn %{region: r} -> "example-data-#{r.environment}-data" end
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
    end

    scatter_options do
      max_concurrent 100
      failure_threshold 0.5
    end

    execute fn ctx, _deps ->
      # Run ECS task with batched items
      ECS.run_task_sync("embed-s3-docs", %{
        cluster: "example-data",
        task_definition: "embed-s3-docs",
        network_configuration: get_network_config(),
        overrides: %{
          container_overrides: [%{
            name: "worker",
            environment: [
              %{name: "REGION_UUID", value: ctx.batch_input.region_uuid},
              %{name: "REGION_ID", value: ctx.batch_input.region_id},
              %{name: "ENVIRONMENT", value: ctx.batch_input.environment},
              %{name: "BUCKET_OBJECT_KEYS", value: Jason.encode!(
                Enum.map(ctx.batch_items, & &1.key)
              )}
            ]
          }]
        }
      })
    end
  end
end
```

### 4.2 Batch Database Inserts

```elixir
asset :insert_records do
  depends_on [:transformed_data]

  scatter fn %{transformed_data: records} ->
    Enum.map(records, &%{record: &1})
  end

  batch_options do
    max_items_per_batch 1000
  end

  scatter_options do
    max_concurrent 5  # Limit DB connections
  end

  execute fn ctx, _deps ->
    records = Enum.map(ctx.batch_items, & &1.record)
    MyApp.Repo.insert_all(Record, records)
    {:ok, %{inserted: length(records)}}
  end
end
```

### 4.3 Embedding API with Size Limits

```elixir
asset :generate_embeddings do
  depends_on [:documents]

  scatter fn %{documents: docs} ->
    Enum.map(docs, fn doc ->
      %{id: doc.id, text: doc.text, size: byte_size(doc.text)}
    end)
  end

  batch_options do
    # OpenAI has ~8K token limit per batch
    max_bytes_per_batch 32_000
    size_fn fn item -> item.size end
    batch_input fn _deps -> %{model: "text-embedding-3-small"} end
  end

  scatter_options do
    rate_limit {60, :minute}  # API rate limit
    max_concurrent 3
  end

  execute fn ctx, _deps ->
    texts = Enum.map(ctx.batch_items, & &1.text)

    {:ok, embeddings} = OpenAI.create_embeddings(%{
      model: ctx.batch_input.model,
      input: texts
    })

    # Return paired results
    results = Enum.zip(ctx.batch_items, embeddings.data)
    |> Enum.map(fn {item, emb} -> {item.id, emb.embedding} end)
    |> Map.new()

    {:ok, results}
  end
end
```

### 4.4 Grouped Batching

```elixir
asset :process_by_category do
  depends_on [:categorized_items]

  scatter fn %{categorized_items: items} -> items end

  batch_options do
    # Group by category, then batch within group
    group_by fn item -> item.category end
    max_items_per_group 100
    batch_input fn deps -> %{processor: deps.config.processor} end
  end

  execute fn ctx, _deps ->
    # All items in batch have same category
    category = hd(ctx.batch_items).category
    process_category_batch(category, ctx.batch_items)
  end
end
```

### 4.5 Custom Batching Logic

```elixir
asset :smart_batch_processing do
  depends_on [:mixed_items]

  scatter fn %{mixed_items: items} -> items end

  batch_options do
    batch_fn fn items ->
      # Custom: separate large and small items
      {large, small} = Enum.split_with(items, & &1.size > 10_000)

      large_batches = Enum.chunk_every(large, 5)   # Few large items per batch
      small_batches = Enum.chunk_every(small, 50)  # Many small items per batch

      large_batches ++ small_batches
    end
  end

  execute fn ctx, _deps ->
    process_items(ctx.batch_items)
  end
end
```

## 5. Comparison with Step Functions

| Step Functions ItemBatcher | FlowStone batch_options |
|---------------------------|------------------------|
| `MaxItemsPerBatch` | `max_items_per_batch N` |
| `MaxInputBytesPerBatch` | `max_bytes_per_batch N` + `size_fn` |
| `BatchInput` | `batch_input fn` |
| `$.Items` in task | `ctx.batch_items` |
| `$.BatchInput` in task | `ctx.batch_input` |

### Migration Example

**Step Functions:**
```json
{
  "Type": "Map",
  "ItemBatcher": {
    "MaxItemsPerBatch": 20,
    "BatchInput": {
      "environment.$": "$.state.environment",
      "region_uuid.$": "$.result.region.output.Uuid"
    }
  },
  "ItemProcessor": {
    "StartAt": "ProcessBatch",
    "States": {
      "ProcessBatch": {
        "Type": "Task",
        "Resource": "arn:aws:states:::ecs:runTask.sync",
        "Parameters": {
          "Overrides": {
            "ContainerOverrides": [{
              "Environment": [{
                "Name": "ITEMS",
                "Value.$": "States.JsonToString($.Items)"
              }, {
                "Name": "REGION",
                "Value.$": "$.BatchInput.region_uuid"
              }]
            }]
          }
        }
      }
    }
  }
}
```

**FlowStone:**
```elixir
batch_options do
  max_items_per_batch 20
  batch_input fn deps ->
    %{
      environment: deps.state.environment,
      region_uuid: deps.result.region.output.uuid
    }
  end
end

execute fn ctx, _deps ->
  ECS.run_task_sync("process-batch", %{
    overrides: %{
      container_overrides: [%{
        environment: [
          %{name: "ITEMS", value: Jason.encode!(ctx.batch_items)},
          %{name: "REGION", value: ctx.batch_input.region_uuid}
        ]
      }]
    }
  })
end
```

## 6. Gather Function with Batches

When batching is enabled, the `gather` function receives batch results:

```elixir
asset :batched_processing do
  scatter fn deps -> deps.items end

  batch_options do
    max_items_per_batch 100
  end

  execute fn ctx, _deps ->
    # Returns result for this batch
    {:ok, %{processed: length(ctx.batch_items), batch: ctx.batch_index}}
  end

  gather fn batch_results ->
    # batch_results is %{batch_key => result}
    # where batch_key is %{_batch: true, index: N}

    total_processed = batch_results
    |> Map.values()
    |> Enum.map(& &1.processed)
    |> Enum.sum()

    %{total_processed: total_processed, batches: map_size(batch_results)}
  end
end
```

## 7. Telemetry

```elixir
# Batch creation
[:flowstone, :scatter, :batch_create]  # measurements: %{batch_count: N, total_items: M}

# Per-batch execution
[:flowstone, :scatter, :batch_start]
[:flowstone, :scatter, :batch_complete]  # measurements: %{items: N, duration_ms: _}
[:flowstone, :scatter, :batch_fail]

# Metadata includes:
# - asset: atom
# - run_id: uuid
# - batch_index: integer
# - batch_count: integer
# - item_count: integer (items in this batch)
```

## 8. Open Questions

1. **Partial batch failures:**
   - If one item in a batch fails, does the whole batch fail?
   - Option: `on_item_error: :fail_batch | :skip_item | :collect_errors`

2. **Batch result aggregation:**
   - Should gather receive individual item results or batch results?
   - Current design: batch results (simpler, matches Step Functions)

3. **Dynamic batch sizing:**
   - Should we support runtime batch size adjustments?
   - e.g., Reduce batch size after failures

4. **Batch ordering:**
   - Should batches execute in order or any order?
   - Current: any order (parallel)
   - Option: `ordered: true` for sequential batch processing

5. **Empty batches:**
   - What if batch_fn returns empty batches?
   - Filter them out? Error?

## 9. Appendix: Full DSL Grammar Extension

```
batch_options ::=
  batch_options do
    batch_config+
  end

batch_config ::=
  max_items_per_batch integer
  | max_bytes_per_batch integer
  | size_fn fn(item) -> integer
  | group_by fn(item) -> term
  | max_items_per_group integer
  | batch_fn fn(items) -> [[item]]
  | batch_input fn(deps) -> map

execute_fn_signature (when batching) ::=
  fn(ctx, deps) -> result
  where ctx.batch_items :: [item]
        ctx.batch_input :: map
        ctx.batch_index :: integer
        ctx.batch_count :: integer
```

## 10. Implementation Phases

### Phase 1: Core Batching
- `max_items_per_batch` support
- `batch_input` function
- Batch-aware scatter barrier
- `ScatterBatchWorker`

### Phase 2: Advanced Batching
- `max_bytes_per_batch` with `size_fn`
- `group_by` with `max_items_per_group`
- Custom `batch_fn`

### Phase 3: Integration
- Combine with ItemReader
- Combine with distributed mode
- Enhanced telemetry and monitoring
