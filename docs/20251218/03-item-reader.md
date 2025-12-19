# Design Doc: ItemReader for Scatter

**Status:** Draft
**Author:** AI Assistant
**Date:** 2025-12-18
**FlowStone Version:** 0.4.0 (proposed)

## 1. Overview

### Problem Statement

FlowStone's current Scatter implementation requires the scatter function to return an in-memory list of scatter keys:

```elixir
scatter fn %{source_urls: urls} ->
  Enum.map(urls, &%{url: &1})  # Must fit in memory
end
```

This works well for small-to-medium fan-outs but breaks down for large-scale processing. Your production Step Functions state machine uses **Distributed Map with ItemReader**:

```json
"Fetch Web Artifacts": {
  "Type": "Map",
  "ItemProcessor": {
    "ProcessorConfig": {
      "Mode": "DISTRIBUTED",
      "ExecutionType": "STANDARD"
    },
    "StartAt": "Get Web Source Artifact",
    "States": { ... }
  },
  "ItemReader": {
    "Resource": "arn:aws:states:::s3:listObjectsV2",
    "Parameters": {
      "Bucket.$": "$.state.runtime.s3.BucketName",
      "Prefix.$": "$.result.region.output.ScrapeUrlsPath"
    }
  },
  "MaxConcurrency": 50,
  "ToleratedFailurePercentage": 50
}
```

Key characteristics:
- Items are read incrementally from an external source (S3, DynamoDB, etc.)
- No need to load all items into memory upfront
- Can process millions of items
- Source can be paginated/streamed

### Goals

1. Enable scatter over large external datasets without memory pressure
2. Support multiple item sources: S3, DynamoDB, PostgreSQL, custom streams
3. Incremental/paginated reading for unbounded datasets
4. Maintain compatibility with existing scatter features (rate limiting, failure thresholds)
5. Enable "distributed mode" execution for massive parallelism

### Non-Goals

1. Real-time streaming (items must be enumerable at scatter start)
2. Cross-region S3 access (use standard AWS credentials)
3. Arbitrary data transformations during read (use `item_selector` instead)

## 2. Design

### 2.1 Core Concept: `scatter_from` DSL

Introduce `scatter_from` as an alternative to the `scatter fn` that reads from external sources:

```elixir
defmodule ArticlePipeline do
  use FlowStone.Pipeline

  asset :fetch_artifacts do
    depends_on [:region]

    scatter_from :s3 do
      bucket fn %{region: r} -> "example-data-#{r.environment}-data" end
      prefix fn %{region: r} -> r.scrape_urls_path end
      max_items 10_000
    end

    scatter_options do
      max_concurrent 50
      failure_threshold 0.5
      mode :distributed
    end

    item_selector fn item, deps ->
      %{
        key: item.key,
        bucket: "example-data-#{deps.region.environment}-data",
        region_id: deps.region.id
      }
    end

    execute fn ctx, _deps ->
      # ctx.scatter_key has the selected item
      Lambda.invoke("get-web-source-artifact", ctx.scatter_key)
    end
  end
end
```

### 2.2 Supported Item Sources

#### S3 (`scatter_from :s3`)

```elixir
scatter_from :s3 do
  bucket "my-bucket"                    # or fn(deps) -> string
  prefix "data/2024/"                   # or fn(deps) -> string
  suffix ".json"                        # optional filter
  max_items 10_000                      # optional limit
  start_after "data/2024/cursor.json"  # optional pagination cursor
end
```

Maps to `s3:ListObjectsV2`. Each item is an S3 object:
```elixir
%{
  key: "data/2024/file1.json",
  size: 1234,
  last_modified: ~U[2024-01-15 10:30:00Z],
  etag: "abc123"
}
```

#### DynamoDB (`scatter_from :dynamodb`)

```elixir
scatter_from :dynamodb do
  table "web-sources-by-region"
  # Scan
  filter_expression "status = :active"
  expression_values %{":active" => "active"}

  # Or Query
  key_condition "PK = :pk"
  expression_values %{":pk" => fn deps -> deps.region.id end}

  max_items 1_000
end
```

Maps to `dynamodb:Scan` or `dynamodb:Query`. Each item is a DynamoDB record.

#### PostgreSQL (`scatter_from :postgres`)

```elixir
scatter_from :postgres do
  repo MyApp.Repo
  query fn deps ->
    from(a in Article,
      where: a.region_id == ^deps.region.id,
      where: a.status == "pending",
      select: %{id: a.id, url: a.url}
    )
  end
  batch_size 1_000
end
```

Uses Ecto streams for memory-efficient iteration.

#### Custom Source (`scatter_from :custom`)

```elixir
scatter_from :custom do
  init fn deps ->
    {:ok, %{page: 1, region: deps.region}}
  end

  next fn state ->
    case API.fetch_page(state.region, state.page) do
      {:ok, items, :more} ->
        {:ok, items, %{state | page: state.page + 1}}
      {:ok, items, :done} ->
        {:ok, items, :halt}
      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

### 2.3 Execution Modes

#### Inline Mode (default)

- Items enumerated by coordinator
- Scatter keys stored in barrier
- Jobs enqueued for each key
- Same as current scatter behavior

```elixir
scatter_options do
  mode :inline
end
```

#### Distributed Mode

- Items read in batches by child executions
- Each batch becomes a sub-barrier
- Enables processing of unbounded datasets
- Similar to Step Functions' DISTRIBUTED mode

```elixir
scatter_options do
  mode :distributed
  batch_size 1_000      # items per sub-execution
  max_batches 100       # limit total batches
end
```

### 2.4 Asset Struct Changes

```elixir
defstruct [
  # ... existing fields ...

  # ItemReader support
  :scatter_source,        # :s3 | :dynamodb | :postgres | :custom | nil
  :scatter_source_config, # source-specific configuration
  :item_selector_fn,      # fn(raw_item, deps) -> scatter_key
  :scatter_mode,          # :inline | :distributed
]
```

### 2.5 ItemReader Behaviour

```elixir
defmodule FlowStone.Scatter.ItemReader do
  @moduledoc """
  Behaviour for scatter item sources.
  """

  @type state :: term()
  @type item :: map()
  @type config :: map()
  @type deps :: map()

  @doc """
  Initialize the reader with configuration and dependencies.
  """
  @callback init(config(), deps()) :: {:ok, state()} | {:error, term()}

  @doc """
  Read the next batch of items.
  Returns {:ok, items, new_state} or {:ok, items, :halt} when done.
  """
  @callback read(state(), batch_size :: pos_integer()) ::
    {:ok, [item()], state() | :halt} | {:error, term()}

  @doc """
  Estimate total item count (for progress tracking).
  Returns {:ok, count} or {:unknown} if count cannot be determined.
  """
  @callback count(state()) :: {:ok, non_neg_integer()} | :unknown

  @doc """
  Clean up any resources.
  """
  @callback close(state()) :: :ok
end
```

### 2.6 Built-in Readers

```elixir
defmodule FlowStone.Scatter.ItemReaders.S3 do
  @behaviour FlowStone.Scatter.ItemReader
  alias ExAws.S3

  defstruct [:bucket, :prefix, :suffix, :max_items, :continuation_token, :items_read]

  @impl true
  def init(config, deps) do
    bucket = evaluate(config.bucket, deps)
    prefix = evaluate(config.prefix, deps)

    {:ok, %__MODULE__{
      bucket: bucket,
      prefix: prefix,
      suffix: config[:suffix],
      max_items: config[:max_items] || :infinity,
      continuation_token: nil,
      items_read: 0
    }}
  end

  @impl true
  def read(state, batch_size) do
    remaining = case state.max_items do
      :infinity -> batch_size
      max -> min(batch_size, max - state.items_read)
    end

    if remaining <= 0 do
      {:ok, [], :halt}
    else
      do_read(state, remaining)
    end
  end

  defp do_read(state, limit) do
    opts = [
      prefix: state.prefix,
      max_keys: limit
    ]
    opts = if state.continuation_token do
      [{:continuation_token, state.continuation_token} | opts]
    else
      opts
    end

    case S3.list_objects_v2(state.bucket, opts) |> ExAws.request() do
      {:ok, %{body: body}} ->
        items = body.contents
        |> Enum.map(&normalize_s3_object/1)
        |> filter_by_suffix(state.suffix)

        new_state = %{state |
          continuation_token: body.next_continuation_token,
          items_read: state.items_read + length(items)
        }

        if body.is_truncated == "true" and within_limit?(new_state) do
          {:ok, items, new_state}
        else
          {:ok, items, :halt}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_s3_object(obj) do
    %{
      key: obj.key,
      size: String.to_integer(obj.size),
      last_modified: parse_timestamp(obj.last_modified),
      etag: String.trim(obj.e_tag, "\"")
    }
  end

  @impl true
  def count(state) do
    # S3 doesn't provide efficient count, return unknown
    :unknown
  end

  @impl true
  def close(_state), do: :ok
end
```

### 2.7 Integration with Scatter Barrier

The scatter coordinator changes to support item readers:

```elixir
defmodule FlowStone.Scatter.Coordinator do
  @moduledoc """
  Coordinates scatter execution with item reader support.
  """

  alias FlowStone.Scatter
  alias FlowStone.Scatter.ItemReader

  def execute(asset, deps, opts) do
    case asset.scatter_source do
      nil ->
        # Traditional scatter function
        execute_with_function(asset, deps, opts)

      source ->
        # ItemReader-based scatter
        execute_with_reader(asset, source, deps, opts)
    end
  end

  defp execute_with_reader(asset, source, deps, opts) do
    reader_module = get_reader_module(source)
    config = asset.scatter_source_config

    with {:ok, reader_state} <- reader_module.init(config, deps),
         {:ok, barrier} <- create_barrier_for_reader(asset, reader_state, opts) do

      case asset.scatter_mode do
        :inline ->
          execute_inline(asset, reader_module, reader_state, barrier, deps, opts)

        :distributed ->
          execute_distributed(asset, reader_module, reader_state, barrier, deps, opts)
      end
    end
  end

  defp execute_inline(asset, reader_module, reader_state, barrier, deps, opts) do
    # Read all items and create scatter keys
    Stream.resource(
      fn -> reader_state end,
      fn
        :halt -> {:halt, :halt}
        state ->
          case reader_module.read(state, 1000) do
            {:ok, items, :halt} -> {items, :halt}
            {:ok, items, new_state} -> {items, new_state}
            {:error, reason} -> raise "ItemReader error: #{inspect(reason)}"
          end
      end,
      fn state ->
        unless state == :halt, do: reader_module.close(state)
      end
    )
    |> Stream.map(&apply_item_selector(asset, &1, deps))
    |> Enum.to_list()
    |> then(fn scatter_keys ->
      Scatter.create_barrier(
        run_id: opts[:run_id],
        asset_name: asset.name,
        partition: opts[:partition],
        scatter_keys: scatter_keys,
        options: asset.scatter_options
      )
    end)
  end

  defp execute_distributed(asset, reader_module, reader_state, barrier, deps, opts) do
    batch_size = asset.scatter_options[:batch_size] || 1000
    max_batches = asset.scatter_options[:max_batches] || :infinity

    # Create sub-barriers for each batch
    {:ok, parent_barrier} = Scatter.create_parent_barrier(
      run_id: opts[:run_id],
      asset_name: asset.name,
      partition: opts[:partition],
      mode: :distributed
    )

    # Enqueue batch processor jobs
    enqueue_batch_jobs(
      parent_barrier,
      asset,
      reader_module,
      reader_state,
      batch_size,
      max_batches,
      deps,
      opts
    )

    {:ok, parent_barrier}
  end
end
```

### 2.8 Persistence Changes

```elixir
# Extend flowstone_scatter_barriers table
defmodule FlowStone.Repo.Migrations.AddItemReaderSupport do
  use Ecto.Migration

  def change do
    alter table(:flowstone_scatter_barriers) do
      # Mode: inline or distributed
      add :mode, :string, default: "inline"

      # For distributed mode
      add :parent_barrier_id, references(:flowstone_scatter_barriers, type: :uuid)
      add :batch_index, :integer

      # Reader state for resume capability
      add :reader_checkpoint, :map
    end

    create index(:flowstone_scatter_barriers, [:parent_barrier_id])
  end
end
```

## 3. Implementation

### 3.1 DSL Macros

```elixir
defmodule FlowStone.Pipeline do
  # ... existing macros ...

  @doc """
  Define an item reader source for scatter.
  """
  defmacro scatter_from(source, do: block) do
    quote do
      var!(scatter_source_config) = %{}
      unquote(block)

      var!(current_asset) = %{
        var!(current_asset) |
        scatter_source: unquote(source),
        scatter_source_config: var!(scatter_source_config)
      }
    end
  end

  # S3 config macros
  defmacro bucket(value) do
    quote do
      var!(scatter_source_config) = Map.put(
        var!(scatter_source_config),
        :bucket,
        unquote(value)
      )
    end
  end

  defmacro prefix(value) do
    quote do
      var!(scatter_source_config) = Map.put(
        var!(scatter_source_config),
        :prefix,
        unquote(value)
      )
    end
  end

  defmacro suffix(value) do
    quote do
      var!(scatter_source_config) = Map.put(
        var!(scatter_source_config),
        :suffix,
        unquote(value)
      )
    end
  end

  defmacro max_items(value) do
    quote do
      var!(scatter_source_config) = Map.put(
        var!(scatter_source_config),
        :max_items,
        unquote(value)
      )
    end
  end

  # DynamoDB config macros
  defmacro table(value) do
    quote do
      var!(scatter_source_config) = Map.put(
        var!(scatter_source_config),
        :table,
        unquote(value)
      )
    end
  end

  defmacro filter_expression(value) do
    quote do
      var!(scatter_source_config) = Map.put(
        var!(scatter_source_config),
        :filter_expression,
        unquote(value)
      )
    end
  end

  # Item selector
  defmacro item_selector(fun) do
    quote do
      var!(current_asset) = %{
        var!(current_asset) |
        item_selector_fn: unquote(fun)
      }
    end
  end

  # Scatter mode
  defmacro mode(value) when value in [:inline, :distributed] do
    quote do
      var!(scatter_opts) = Map.put(var!(scatter_opts), :mode, unquote(value))
    end
  end

  defmacro batch_size(value) do
    quote do
      var!(scatter_opts) = Map.put(var!(scatter_opts), :batch_size, unquote(value))
    end
  end
end
```

### 3.2 S3 Reader Implementation

```elixir
defmodule FlowStone.Scatter.ItemReaders.S3 do
  @behaviour FlowStone.Scatter.ItemReader

  defstruct [
    :bucket,
    :prefix,
    :suffix,
    :max_items,
    :start_after,
    :continuation_token,
    :items_read,
    :reader_config
  ]

  @impl true
  def init(config, deps) do
    bucket = resolve_value(config[:bucket], deps)
    prefix = resolve_value(config[:prefix], deps)

    state = %__MODULE__{
      bucket: bucket,
      prefix: prefix,
      suffix: config[:suffix],
      max_items: config[:max_items] || :infinity,
      start_after: config[:start_after],
      continuation_token: nil,
      items_read: 0,
      reader_config: config[:reader_config] || %{}
    }

    {:ok, state}
  end

  @impl true
  def read(%{items_read: read, max_items: max} = _state, _batch_size)
      when is_integer(max) and read >= max do
    {:ok, [], :halt}
  end

  def read(state, batch_size) do
    limit = case state.max_items do
      :infinity -> batch_size
      max -> min(batch_size, max - state.items_read)
    end

    request_opts = build_request_opts(state, limit)

    case ExAws.S3.list_objects_v2(state.bucket, request_opts) |> ExAws.request() do
      {:ok, %{body: body}} ->
        items = process_response(body, state.suffix)
        new_state = update_state(state, body, items)

        if should_continue?(body, new_state) do
          {:ok, items, new_state}
        else
          {:ok, items, :halt}
        end

      {:error, {:http_error, 404, _}} ->
        {:ok, [], :halt}

      {:error, reason} ->
        {:error, {:s3_error, reason}}
    end
  end

  @impl true
  def count(_state) do
    # S3 doesn't provide efficient count
    :unknown
  end

  @impl true
  def close(_state), do: :ok

  # Checkpointing for resume
  def checkpoint(state) do
    %{
      continuation_token: state.continuation_token,
      items_read: state.items_read
    }
  end

  def restore(state, checkpoint) do
    %{state |
      continuation_token: checkpoint.continuation_token,
      items_read: checkpoint.items_read
    }
  end

  # Private helpers

  defp resolve_value(fun, deps) when is_function(fun), do: fun.(deps)
  defp resolve_value(value, _deps), do: value

  defp build_request_opts(state, limit) do
    opts = [prefix: state.prefix, max_keys: limit]

    opts = if state.continuation_token do
      [{:continuation_token, state.continuation_token} | opts]
    else
      if state.start_after do
        [{:start_after, state.start_after} | opts]
      else
        opts
      end
    end

    opts
  end

  defp process_response(body, suffix) do
    body.contents
    |> Enum.map(&normalize_object/1)
    |> filter_suffix(suffix)
  end

  defp normalize_object(obj) do
    %{
      key: obj.key,
      size: parse_int(obj.size),
      last_modified: obj.last_modified,
      etag: String.trim(obj.e_tag || "", "\""),
      storage_class: obj.storage_class
    }
  end

  defp filter_suffix(items, nil), do: items
  defp filter_suffix(items, suffix) do
    Enum.filter(items, &String.ends_with?(&1.key, suffix))
  end

  defp parse_int(nil), do: 0
  defp parse_int(s) when is_binary(s), do: String.to_integer(s)
  defp parse_int(n) when is_integer(n), do: n

  defp update_state(state, body, items) do
    %{state |
      continuation_token: body[:next_continuation_token],
      items_read: state.items_read + length(items)
    }
  end

  defp should_continue?(body, state) do
    body[:is_truncated] == "true" and
      (state.max_items == :infinity or state.items_read < state.max_items)
  end
end
```

### 3.3 DynamoDB Reader

```elixir
defmodule FlowStone.Scatter.ItemReaders.DynamoDB do
  @behaviour FlowStone.Scatter.ItemReader

  defstruct [
    :table,
    :operation,       # :scan or :query
    :key_condition,
    :filter_expression,
    :expression_values,
    :expression_names,
    :max_items,
    :exclusive_start_key,
    :items_read
  ]

  @impl true
  def init(config, deps) do
    operation = if config[:key_condition], do: :query, else: :scan

    state = %__MODULE__{
      table: resolve_value(config[:table], deps),
      operation: operation,
      key_condition: config[:key_condition],
      filter_expression: config[:filter_expression],
      expression_values: resolve_expression_values(config[:expression_values], deps),
      expression_names: config[:expression_names],
      max_items: config[:max_items] || :infinity,
      exclusive_start_key: nil,
      items_read: 0
    }

    {:ok, state}
  end

  @impl true
  def read(state, batch_size) do
    limit = calculate_limit(state, batch_size)

    if limit <= 0 do
      {:ok, [], :halt}
    else
      do_read(state, limit)
    end
  end

  defp do_read(state, limit) do
    request = build_request(state, limit)

    case ExAws.request(request) do
      {:ok, response} ->
        items = Enum.map(response["Items"] || [], &decode_item/1)
        new_state = update_state(state, response, items)

        if should_continue?(response, new_state) do
          {:ok, items, new_state}
        else
          {:ok, items, :halt}
        end

      {:error, reason} ->
        {:error, {:dynamodb_error, reason}}
    end
  end

  defp build_request(state, limit) do
    base_opts = [
      limit: limit,
      expression_attribute_values: state.expression_values
    ]

    base_opts = if state.expression_names do
      [{:expression_attribute_names, state.expression_names} | base_opts]
    else
      base_opts
    end

    base_opts = if state.filter_expression do
      [{:filter_expression, state.filter_expression} | base_opts]
    else
      base_opts
    end

    base_opts = if state.exclusive_start_key do
      [{:exclusive_start_key, state.exclusive_start_key} | base_opts]
    else
      base_opts
    end

    case state.operation do
      :scan ->
        ExAws.Dynamo.scan(state.table, base_opts)
      :query ->
        opts = [{:key_condition_expression, state.key_condition} | base_opts]
        ExAws.Dynamo.query(state.table, opts)
    end
  end

  @impl true
  def count(state) do
    # DynamoDB can provide approximate count via DescribeTable
    case ExAws.Dynamo.describe_table(state.table) |> ExAws.request() do
      {:ok, %{"Table" => %{"ItemCount" => count}}} ->
        {:ok, count}
      _ ->
        :unknown
    end
  end

  @impl true
  def close(_state), do: :ok
end
```

### 3.4 Distributed Mode Worker

```elixir
defmodule FlowStone.Workers.DistributedScatterWorker do
  @moduledoc """
  Processes a batch of items in distributed scatter mode.
  """

  use Oban.Worker,
    queue: :distributed_scatter,
    max_attempts: 3

  alias FlowStone.Scatter

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{
      "parent_barrier_id" => parent_barrier_id,
      "batch_index" => batch_index,
      "reader_checkpoint" => checkpoint,
      "asset_config" => asset_config,
      "deps" => deps,
      "run_id" => run_id
    } = args

    # Restore reader state
    reader_module = get_reader_module(asset_config["scatter_source"])
    {:ok, reader_state} = reader_module.init(asset_config["scatter_source_config"], deps)
    reader_state = reader_module.restore(reader_state, checkpoint)

    # Read batch
    batch_size = asset_config["scatter_options"]["batch_size"] || 1000
    {:ok, items, _} = reader_module.read(reader_state, batch_size)

    # Apply item selector
    scatter_keys = Enum.map(items, fn item ->
      apply_item_selector(asset_config, item, deps)
    end)

    # Create sub-barrier
    {:ok, barrier} = Scatter.create_barrier(
      run_id: run_id,
      asset_name: asset_config["name"],
      partition: asset_config["partition"],
      scatter_keys: scatter_keys,
      options: asset_config["scatter_options"],
      parent_barrier_id: parent_barrier_id,
      batch_index: batch_index
    )

    # Enqueue scatter instance jobs
    Scatter.enqueue_instances(barrier, asset_config, deps, run_id)

    :ok
  end
end
```

## 4. Examples

### 4.1 Your S3 Fetch Pattern

```elixir
defmodule ReportPipeline do
  use FlowStone.Pipeline

  asset :fetch_web_artifacts do
    depends_on [:region, :runtime_config]

    scatter_from :s3 do
      bucket fn %{runtime_config: c} -> c.s3.bucket_name end
      prefix fn %{region: r} -> r.scrape_urls_path end
    end

    scatter_options do
      max_concurrent 50
      failure_threshold 0.5
      mode :distributed
      batch_size 1000
    end

    item_selector fn item, deps ->
      %{
        key: item.key,
        bucket: deps.runtime_config.s3.bucket_name,
        region_id: deps.region.id,
        environment: deps.region.environment
      }
    end

    execute fn ctx, _deps ->
      Lambda.invoke("get-web-source-artifact", ctx.scatter_key)
    end
  end
end
```

### 4.2 DynamoDB Scan Pattern

```elixir
asset :process_all_sources do
  depends_on [:config]

  scatter_from :dynamodb do
    table "web-sources-global"
    filter_expression "active = :true"
    expression_values %{":true" => %{"BOOL" => true}}
    max_items 10_000
  end

  scatter_options do
    max_concurrent 20
    rate_limit {100, :minute}  # Respect DynamoDB capacity
  end

  item_selector fn item, _deps ->
    %{
      hostname: item["hostname"]["S"],
      source_type: item["type"]["S"]
    }
  end

  execute fn ctx, _deps ->
    process_source(ctx.scatter_key)
  end
end
```

### 4.3 PostgreSQL Query Pattern

```elixir
asset :backfill_embeddings do
  depends_on [:config]

  scatter_from :postgres do
    repo MyApp.Repo
    query fn _deps ->
      from(a in Article,
        where: is_nil(a.embedding),
        where: a.status == "published",
        select: %{id: a.id, content: a.content}
      )
    end
    batch_size 500
  end

  scatter_options do
    max_concurrent 10
    rate_limit {60, :minute}  # Embedding API rate limit
  end

  execute fn ctx, _deps ->
    embedding = EmbeddingService.generate(ctx.scatter_key.content)
    Article.update_embedding(ctx.scatter_key.id, embedding)
  end
end
```

### 4.4 Custom Paginated API

```elixir
asset :sync_external_records do
  depends_on [:api_config]

  scatter_from :custom do
    init fn deps ->
      {:ok, %{cursor: nil, api_key: deps.api_config.key}}
    end

    next fn state ->
      case ExternalAPI.list_records(state.api_key, cursor: state.cursor) do
        {:ok, %{records: records, next_cursor: nil}} ->
          {:ok, records, :halt}
        {:ok, %{records: records, next_cursor: cursor}} ->
          {:ok, records, %{state | cursor: cursor}}
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  scatter_options do
    max_concurrent 5
  end

  execute fn ctx, _deps ->
    sync_record(ctx.scatter_key)
  end
end
```

## 5. Comparison with Step Functions

| Step Functions ItemReader | FlowStone scatter_from |
|--------------------------|------------------------|
| `arn:aws:states:::s3:listObjectsV2` | `scatter_from :s3` |
| `arn:aws:states:::s3:getObject` | Custom reader |
| `Parameters.Bucket.$` | `bucket fn deps -> ... end` |
| `Parameters.Prefix.$` | `prefix fn deps -> ... end` |
| `ReaderConfig.MaxItems` | `max_items N` |
| `ItemSelector` | `item_selector fn` |
| `Mode: DISTRIBUTED` | `mode :distributed` |
| `MaxConcurrency` | `max_concurrent N` |
| `ToleratedFailurePercentage` | `failure_threshold 0.5` |

### Migration Example

**Step Functions:**
```json
{
  "Type": "Map",
  "ItemReader": {
    "Resource": "arn:aws:states:::s3:listObjectsV2",
    "Parameters": {
      "Bucket.$": "$.state.runtime.s3.BucketName",
      "Prefix.$": "$.result.region.output.ScrapeUrlsPath"
    },
    "ReaderConfig": {
      "MaxItems": 250
    }
  },
  "MaxConcurrency": 50,
  "ToleratedFailurePercentage": 50,
  "ItemSelector": {
    "key.$": "$$.Map.Item.Value.Key",
    "bucket.$": "$.state.runtime.s3.BucketName"
  }
}
```

**FlowStone:**
```elixir
scatter_from :s3 do
  bucket fn %{state: s} -> s.runtime.s3.bucket_name end
  prefix fn %{result: r} -> r.region.output.scrape_urls_path end
  max_items 250
end

scatter_options do
  max_concurrent 50
  failure_threshold 0.5
end

item_selector fn item, deps ->
  %{
    key: item.key,
    bucket: deps.state.runtime.s3.bucket_name
  }
end
```

## 6. Telemetry

```elixir
# ItemReader events
[:flowstone, :item_reader, :init]
[:flowstone, :item_reader, :read]      # measurements: %{items: N, duration_ms: _}
[:flowstone, :item_reader, :complete]  # measurements: %{total_items: N}
[:flowstone, :item_reader, :error]

# Distributed scatter events
[:flowstone, :scatter, :batch_start]
[:flowstone, :scatter, :batch_complete]

# Metadata includes:
# - source: :s3 | :dynamodb | :postgres | :custom
# - asset: atom
# - run_id: uuid
# - batch_index: integer (for distributed mode)
```

## 7. Open Questions

1. **Checkpoint granularity for distributed mode:**
   - Per-page checkpoint (more resume points, more storage)?
   - Per-batch checkpoint (simpler, coarser)?

2. **S3 object filtering:**
   - Support additional filters (size, date range)?
   - Handle S3 Select for content-based filtering?

3. **Error handling during read:**
   - Retry transient errors automatically?
   - Fail entire scatter on read error?
   - Skip problematic items?

4. **Memory management for inline mode:**
   - Stream items to barrier creation?
   - Set hard limit on inline mode item count?

5. **Cross-account/region S3 access:**
   - Support assuming roles?
   - Support S3 access points?

## 8. Appendix: Full DSL Grammar Extension

```
scatter_source ::=
  scatter_from source_type do
    source_config+
  end

source_type ::= :s3 | :dynamodb | :postgres | :custom

s3_config ::=
  bucket (string | fn)
  prefix (string | fn)
  [suffix string]
  [max_items integer]
  [start_after string]

dynamodb_config ::=
  table (string | fn)
  [key_condition string]
  [filter_expression string]
  [expression_values map]
  [expression_names map]
  [max_items integer]

postgres_config ::=
  repo module
  query fn
  [batch_size integer]

custom_config ::=
  init fn
  next fn

item_selector ::= item_selector fn(item, deps) -> scatter_key

scatter_mode ::= mode (:inline | :distributed)
```
