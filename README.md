<p align="center">
  <img src="assets/flowstone.svg" alt="FlowStone Logo" width="220" height="248">
</p>

# FlowStone

[![CI](https://github.com/nshkrdotcom/flowstone/actions/workflows/ci.yml/badge.svg)](https://github.com/nshkrdotcom/flowstone/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/flowstone.svg)](https://hex.pm/packages/flowstone)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/flowstone)
[![License](https://img.shields.io/hexpm/l/flowstone.svg)](https://github.com/nshkrdotcom/flowstone/blob/main/LICENSE)

**Asset-first data orchestration for the BEAM.**

FlowStone is an orchestration library for Elixir that treats *assets* (named data artifacts) as the primary abstraction. It's designed for building reliable, auditable data pipelines where persistence, lineage tracking, and operational visibility matter.

## When to Use FlowStone

FlowStone is the right choice when you need:

| Use Case | Why FlowStone |
|----------|---------------|
| **ETL/ELT pipelines** | Partition-aware materialization, dependency tracking |
| **Data warehouse orchestration** | Scheduled jobs, backfill support, lineage queries |
| **Audit-sensitive workflows** | Comprehensive audit logging, approval gates |
| **Durable job execution** | Oban-backed persistence, jobs survive restarts |
| **Multi-format data storage** | Pluggable I/O managers (PostgreSQL, S3, Parquet) |

### Ideal Workloads

- Daily/hourly batch processing with date-partitioned data
- Data transformation pipelines with explicit dependencies
- Workflows requiring human approval checkpoints
- Systems where "what produced this data?" matters (lineage)
- Long-running jobs that must not be lost on node failure

## When to Use Something Else

FlowStone is **not** the best fit for:

| Use Case | Better Alternative |
|----------|-------------------|
| **Real-time distributed compute** | [Handoff](https://github.com/polvalente/handoff) - native BEAM distribution, resource-aware scheduling |
| **High-throughput stream processing** | [Broadway](https://github.com/dashbitco/broadway), [GenStage](https://github.com/elixir-lang/gen_stage) |
| **Simple background jobs** | [Oban](https://github.com/sorentwo/oban) directly |
| **Ad-hoc parallel computation** | [Task.async_stream](https://hexdocs.pm/elixir/Task.html), [Flow](https://github.com/dashbitco/flow) |
| **ML model training/inference** | [Nx](https://github.com/elixir-nx/nx) + distributed compute layer |

### FlowStone vs Handoff

| Aspect | FlowStone | Handoff |
|--------|-----------|---------|
| **Primary abstraction** | Assets (data artifacts) | Functions (computation) |
| **Execution model** | Database-mediated (Oban) | Native BEAM RPC |
| **Durability** | Jobs persist to PostgreSQL | Ephemeral (ETS) |
| **Best for** | Data pipelines, ETL, audit trails | Distributed compute, GPU scheduling |
| **Dependencies** | Ecto, Oban, PostgreSQL | Zero production deps |

**Rule of thumb:** If your data needs to survive a restart and you care about lineage, use FlowStone. If you need fast ephemeral computation across nodes with resource awareness, use Handoff.

See `docs/20251215/flowstone-vs-handoff-comparison.md` for detailed analysis.

## Status

FlowStone is in **alpha**. Core execution, persistence primitives, and safety hardening are implemented, but some higher-level platform features (e.g., a bundled UI, fully resumable approvals, richer DSL surface) are still evolving.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:flowstone, "~> 0.4.0"}
  ]
end
```

## Quick Start

Define a pipeline:

```elixir
defmodule MyApp.Pipeline do
  use FlowStone.Pipeline

  asset :raw do
    execute fn _context, _deps -> {:ok, load_from_source()} end
  end

  asset :cleaned do
    depends_on [:raw]
    execute fn _context, %{raw: raw} -> {:ok, clean(raw)} end
  end

  asset :report do
    depends_on [:cleaned]
    execute fn _context, %{cleaned: data} -> {:ok, generate_report(data)} end
  end
end
```

Register and materialize:

```elixir
# Start required services
{:ok, _} = FlowStone.Registry.start_link(name: MyRegistry)
{:ok, _} = FlowStone.IO.Memory.start_link(name: MyMemory)

# Register pipeline assets
FlowStone.register(MyApp.Pipeline, registry: MyRegistry)

# Configure I/O (in-memory for dev/test)
io = [config: %{agent: MyMemory}]

# Materialize a single asset for a partition
FlowStone.materialize(:report,
  partition: ~D[2025-01-15],
  registry: MyRegistry,
  io: io
)

# Or materialize with all dependencies
FlowStone.materialize_all(:report,
  partition: ~D[2025-01-15],
  registry: MyRegistry,
  io: io
)
```

Backfill across partitions:

```elixir
FlowStone.backfill(:report,
  partitions: Date.range(~D[2025-01-01], ~D[2025-01-31]),
  registry: MyRegistry,
  io: io,
  max_parallel: 4
)
```

## Core Concepts

### Assets

Assets are named data artifacts. Each asset declares:
- **Dependencies** - other assets it consumes
- **Execute function** - computation that produces the asset's value
- **Partition** - temporal or dimensional key (dates, tuples, custom)

```elixir
asset :daily_sales do
  depends_on [:raw_transactions, :product_catalog]
  execute fn context, deps ->
    sales = compute_sales(deps.raw_transactions, deps.product_catalog)
    {:ok, sales}
  end
end
```

### Partitions

FlowStone supports partition-aware execution for time-series and dimensional data:

```elixir
# Date partitions
FlowStone.materialize(:report, partition: ~D[2025-01-15])

# DateTime partitions
FlowStone.materialize(:hourly_stats, partition: ~U[2025-01-15 14:00:00Z])

# Tuple partitions (multi-dimensional)
FlowStone.materialize(:regional_report, partition: {~D[2025-01-15], "us-east"})
```

### I/O Managers

Pluggable storage backends for asset data:

| Manager | Use Case |
|---------|----------|
| `FlowStone.IO.Memory` | Development, testing |
| `FlowStone.IO.Postgres` | Structured data, small-medium payloads |
| `FlowStone.IO.S3` | Large files, data lake integration |
| `FlowStone.IO.Parquet` | Columnar analytics data |

### Execution Model

- **Oban running:** `materialize/2` enqueues a durable job, returns `{:ok, %Oban.Job{}}`
- **Oban not running:** `materialize/2` executes synchronously, returns `:ok` or `{:error, reason}`

This allows the same code to work in dev (synchronous) and production (queued).

## Features

### Lineage Tracking

Query what data produced what:

```elixir
# What did :report consume?
FlowStone.Lineage.upstream(:report, ~D[2025-01-15])
# => [%{asset: :cleaned, partition: "2025-01-15"}]

# What depends on :raw?
FlowStone.Lineage.downstream(:raw, ~D[2025-01-15])
# => [%{asset: :cleaned, partition: "2025-01-15"}]
```

### Approval Gates

Pause execution for human review:

```elixir
asset :high_value_trade do
  execute fn context, deps ->
    trade = compute_trade(deps)
    if trade.value > 1_000_000 do
      {:wait_for_approval, message: "Large trade requires sign-off", context: trade}
    else
      {:ok, trade}
    end
  end
end
```

### Scheduling

Cron-based scheduling for recurring materializations:

```elixir
FlowStone.schedule(:daily_report,
  cron: "0 6 * * *",  # 6 AM daily
  partition_fn: fn -> Date.utc_today() end
)
```

### Scatter (Dynamic Fan-Out)

Runtime-discovered parallel execution within FlowStone's asset-centric model:

```elixir
asset :scraped_article do
  depends_on [:source_urls]

  # Scatter function: transforms dependency data into scatter keys
  scatter fn %{source_urls: urls} ->
    Enum.map(urls, &%{url: &1})
  end

  scatter_options do
    max_concurrent 50
    rate_limit {10, :second}
    failure_threshold 0.02
  end

  execute fn ctx, _deps ->
    Scraper.fetch(ctx.scatter_key.url)
  end
end
```

### ItemReader (Streaming Scatter Inputs)

Read scatter items incrementally from external sources or custom readers:

```elixir
asset :processed_items do
  scatter_from :custom do
    init fn _config, _deps -> {:ok, %{items: [1, 2, 3], index: 0}} end
    read fn state, batch_size ->
      items = Enum.drop(state.items, state.index)
      batch = Enum.take(items, batch_size)
      new_state = %{state | index: state.index + length(batch)}
      if batch == [], do: {:ok, [], :halt}, else: {:ok, batch, new_state}
    end
  end

  item_selector fn item, _deps -> %{value: item} end

  scatter_options do
    batch_size 2
  end

  execute fn ctx, _deps ->
    {:ok, ctx.scatter_key["value"]}
  end
end
```

### ItemBatcher (Batch Scatter Execution)

Group scatter items into batches for efficient execution (similar to Step Functions ItemBatcher):

```elixir
asset :batched_processor do
  depends_on [:source_items]

  scatter fn %{source_items: items} ->
    Enum.map(items, &%{item_id: &1.id})
  end

  batch_options do
    max_items_per_batch 20
    batch_input fn deps -> %{total: length(deps.source_items)} end
    on_item_error :fail_batch
  end

  execute fn ctx, _deps ->
    # ctx.batch_items - list of items in this batch
    # ctx.batch_input - shared batch context
    # ctx.batch_index - zero-based batch index
    # ctx.batch_count - total number of batches
    sum = Enum.sum(Enum.map(ctx.batch_items, & &1["item_id"]))
    {:ok, %{batch_sum: sum}}
  end
end
```

### Signal Gate (Durable External Suspension)

Zero-resource waiting for external signals (webhooks, callbacks):

```elixir
asset :embedded_documents do
  execute fn ctx, deps ->
    task_id = ECS.start_task(deps.data)
    {:signal_gate, token: task_id, timeout: :timer.hours(1)}
  end

  on_signal fn _ctx, payload ->
    {:ok, payload.result}
  end

  on_timeout fn ctx ->
    {:error, :timeout}
  end
end
```

### Conditional Routing

Select a single branch at runtime and skip the rest:

```elixir
asset :router do
  depends_on [:input]

  route do
    choice :branch_a, when: fn %{input: %{mode: :a}} -> true end
    default :branch_b
  end
end

asset :branch_a do
  routed_from :router
  depends_on [:input]
  execute fn _, _ -> {:ok, :a} end
end

asset :branch_b do
  routed_from :router
  depends_on [:input]
  execute fn _, _ -> {:ok, :b} end
end

asset :merge do
  depends_on [:branch_a, :branch_b]
  optional_deps [:branch_a, :branch_b]
  execute fn _, deps -> {:ok, deps[:branch_a] || deps[:branch_b]} end
end
```

### Parallel Branches

Run heterogeneous branches in parallel and join results:

```elixir
asset :enrich do
  depends_on [:input]

  parallel do
    branch :maps, final: :generate_maps
    branch :news, final: :get_front_pages
  end

  parallel_options do
    failure_mode :partial
  end

  join fn branches, deps ->
    %{
      maps: branches.maps,
      news: branches.news,
      input: deps.input
    }
  end
end
```

### Rate Limiting

Distributed rate limiting for APIs and external services:

```elixir
# Check rate limit
case FlowStone.RateLimiter.check("api:openai", {60, :minute}) do
  :ok -> call_api()
  {:wait, ms} -> {:snooze, div(ms, 1000) + 1}
end

# Semaphore-based concurrency control
FlowStone.RateLimiter.with_slot("expensive:operation", 10, fn ->
  expensive_operation()
end)
```

### Telemetry

FlowStone emits telemetry events for observability:

- `[:flowstone, :materialization, :start | :stop | :exception]`
- `[:flowstone, :scatter, :start | :complete | :failed | :instance_complete | :instance_fail]`
- `[:flowstone, :signal_gate, :create | :signal | :timeout]`
- `[:flowstone, :route, :start | :stop | :error]`
- `[:flowstone, :parallel, :start | :stop | :error | :branch_start | :branch_complete | :branch_fail]`
- `[:flowstone, :rate_limit, :check | :wait | :slot_acquired | :slot_released]`

## Documentation

- **Design overview:** `docs/design/OVERVIEW.md`
- **Architecture decisions:** `docs/adr/README.md`
- **Comparison with Handoff:** `docs/20251215/flowstone-vs-handoff-comparison.md`
- **Rebuild analysis:** `docs/20251215/rebuild-analysis.md`
- **Examples:** `examples/README.md` (run all via `MIX_ENV=dev mix run examples/run_all.exs` or `MIX_ENV=dev bash examples/run_all.sh`)

## Contributing

Contributions are welcome. Please read the ADRs first to understand current decisions and constraints.

## License

MIT
