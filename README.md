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

## Quick Start

**v0.5.2** adds maintenance and resilience improvements, building on the HTTP client from v0.5.1:

```elixir
defmodule MyApp.Pipeline do
  use FlowStone.Pipeline

  asset :greeting do
    execute fn _, _ -> {:ok, "Hello, World!"} end
  end

  asset :numbers do
    execute fn _, _ -> {:ok, [1, 2, 3, 4, 5]} end
  end

  asset :doubled do
    depends_on [:numbers]
    execute fn _, %{numbers: nums} -> {:ok, Enum.map(nums, &(&1 * 2))} end
  end

  asset :sum do
    depends_on [:doubled]
    execute fn _, %{doubled: nums} -> {:ok, Enum.sum(nums)} end
  end
end

# Run with automatic dependency resolution
{:ok, 30} = FlowStone.run(MyApp.Pipeline, :sum)

# Check if a result exists
true = FlowStone.exists?(MyApp.Pipeline, :sum)

# Retrieve cached result
{:ok, 30} = FlowStone.get(MyApp.Pipeline, :sum)
```

No explicit registration, no server configuration needed. FlowStone auto-registers pipelines and uses in-memory storage by default.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:flowstone, "~> 0.5.2"}
  ]
end
```

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

**Rule of thumb:** If your data needs to survive a restart and you care about lineage, use FlowStone. If you need fast ephemeral computation across nodes with resource awareness, use Handoff.

## High-Level API

The v0.5.0 API is pipeline-centric and works with zero configuration:

### Running Assets

```elixir
# Run an asset (resolves dependencies automatically)
{:ok, result} = FlowStone.run(MyPipeline, :asset_name)

# Run with a specific partition
{:ok, result} = FlowStone.run(MyPipeline, :daily_report, partition: ~D[2025-01-15])

# Force re-execution (ignore cache)
{:ok, result} = FlowStone.run(MyPipeline, :asset_name, force: true)

# Run without dependencies (fails if deps not already materialized)
{:ok, result} = FlowStone.run(MyPipeline, :asset_name, with_deps: false)
```

### Retrieving Results

```elixir
# Get cached result
{:ok, result} = FlowStone.get(MyPipeline, :asset_name)
{:error, :not_found} = FlowStone.get(MyPipeline, :never_run)

# Check if result exists
true = FlowStone.exists?(MyPipeline, :asset_name)

# Get execution status
%{state: :completed, partition: :default} = FlowStone.status(MyPipeline, :asset_name)
```

### Cache Management

```elixir
# Invalidate cached result
{:ok, 1} = FlowStone.invalidate(MyPipeline, :asset_name)

# Invalidate specific partition
{:ok, 1} = FlowStone.invalidate(MyPipeline, :asset_name, partition: ~D[2025-01-15])
```

### Backfilling

```elixir
# Process multiple partitions
{:ok, stats} = FlowStone.backfill(MyPipeline, :daily_report,
  partitions: Date.range(~D[2025-01-01], ~D[2025-01-31])
)

# Parallel backfill
{:ok, stats} = FlowStone.backfill(MyPipeline, :daily_report,
  partitions: [:a, :b, :c, :d],
  parallel: 4
)

# stats => %{succeeded: 31, failed: 0, skipped: 0}
```

### Introspection

```elixir
# List all assets
[:greeting, :numbers, :doubled, :sum] = FlowStone.assets(MyPipeline)

# Get asset details
%{name: :doubled, depends_on: [:numbers]} = FlowStone.asset_info(MyPipeline, :doubled)

# Get DAG visualization
FlowStone.graph(MyPipeline)              # ASCII art
FlowStone.graph(MyPipeline, format: :mermaid)  # Mermaid diagram
```

### Pipeline Module Shortcuts

Pipelines also get convenience methods:

```elixir
defmodule MyApp.Pipeline do
  use FlowStone.Pipeline
  # ...
end

# These work on the pipeline module directly
{:ok, result} = MyApp.Pipeline.run(:sum)
{:ok, result} = MyApp.Pipeline.get(:sum)
true = MyApp.Pipeline.exists?(:sum)
[:greeting, :numbers, :doubled, :sum] = MyApp.Pipeline.assets()
```

## Configuration

FlowStone works with zero configuration, but can be customized:

```elixir
# config/config.exs

# Add persistence (auto-enables Postgres storage and lineage)
config :flowstone, repo: MyApp.Repo

# Or configure explicitly
config :flowstone,
  repo: MyApp.Repo,
  storage: :postgres,    # :memory (default), :postgres, :s3, :parquet
  lineage: true,         # auto-enabled when repo is set
  async_default: false   # use sync execution by default
```

See the [Configuration Guide](guides/configuration.md) for details.

### Distributed Deployment

FlowStone uses node-local ETS for runtime configuration (`FlowStone.RunConfig`). In multi-node Oban deployments:

**Limitation:** Custom runtime options passed to `FlowStone.materialize/2` (like `:io`, `:registry`) will not propagate to jobs executed on different nodes.

**Recommendations for multi-node deployments:**

1. **Use application config** for IO managers, registries, and resource servers:
   ```elixir
   # config/runtime.exs - these settings are available on all nodes
   config :flowstone,
     io_managers: %{postgres: FlowStone.IO.Postgres},
     default_io_manager: :postgres
   ```

2. **Use Oban's queue affinity** if you need node-specific behavior

3. **Monitor fallback events** via telemetry:
   ```elixir
   :telemetry.attach("run-config-monitor", [:flowstone, :run_config, :fallback], fn event, _, meta, _ ->
     Logger.warning("RunConfig fallback on #{meta.node} for run_id: #{meta.run_id}")
   end, nil)
   ```

For single-node deployments, runtime options work as expected.

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

### Short-Form Assets

For simple assets, use the short form:

```elixir
# Short form - value is returned directly
asset :config, do: {:ok, %{batch_size: 100}}

# Equivalent to:
asset :config do
  execute fn _, _ -> {:ok, %{batch_size: 100}} end
end
```

### Implicit Result Wrapping

With `wrap_results: true`, you can skip the `{:ok, ...}` wrapper:

```elixir
defmodule MyApp.Pipeline do
  use FlowStone.Pipeline, wrap_results: true

  asset :numbers do
    execute fn _, _ -> [1, 2, 3, 4, 5] end  # Automatically wrapped as {:ok, [1, 2, 3, 4, 5]}
  end

  asset :doubled do
    depends_on [:numbers]
    execute fn _, %{numbers: nums} -> Enum.map(nums, &(&1 * 2)) end
  end
end
```

### Partitions

FlowStone supports partition-aware execution for time-series and dimensional data:

```elixir
# Date partitions
{:ok, _} = FlowStone.run(MyPipeline, :report, partition: ~D[2025-01-15])

# DateTime partitions
{:ok, _} = FlowStone.run(MyPipeline, :hourly_stats, partition: ~U[2025-01-15 14:00:00Z])

# Custom partitions (atoms, tuples)
{:ok, _} = FlowStone.run(MyPipeline, :regional_report, partition: {:us_east, ~D[2025-01-15]})
```

Access the partition in your execute function:

```elixir
asset :daily_data do
  execute fn ctx, _ ->
    date = ctx.partition
    {:ok, fetch_data_for_date(date)}
  end
end
```

### I/O Managers

Pluggable storage backends for asset data:

| Manager | Use Case |
|---------|----------|
| `FlowStone.IO.Memory` | Development, testing (default) |
| `FlowStone.IO.Postgres` | Structured data, small-medium payloads |
| `FlowStone.IO.S3` | Large files, data lake integration |
| `FlowStone.IO.Parquet` | Columnar analytics data |

## Advanced Features

### Scatter (Dynamic Fan-Out)

Runtime-discovered parallel execution:

```elixir
asset :scraped_article do
  depends_on [:source_urls]

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

Read scatter items incrementally from external sources:

```elixir
asset :processed_items do
  scatter_from :custom do
    init fn _config, _deps -> {:ok, %{items: fetch_items(), index: 0}} end
    read fn state, batch_size ->
      batch = Enum.slice(state.items, state.index, batch_size)
      new_state = %{state | index: state.index + length(batch)}
      if batch == [], do: {:ok, [], :halt}, else: {:ok, batch, new_state}
    end
  end

  execute fn ctx, _deps ->
    {:ok, process_item(ctx.scatter_key)}
  end
end
```

### ItemBatcher (Batch Scatter Execution)

Group scatter items into batches for efficient execution:

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

Select a single branch at runtime:

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
    %{maps: branches.maps, news: branches.news, input: deps.input}
  end
end
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

### HTTP Client Resource

Built-in HTTP client for REST API integrations with retry, rate limiting, and telemetry:

```elixir
# Register an HTTP client as a resource
FlowStone.Resources.register(:api, FlowStone.HTTP.Client,
  base_url: "https://api.example.com",
  timeout: 30_000,
  headers: %{"Authorization" => "Bearer #{token}"},
  retry: %{max_attempts: 3, base_delay_ms: 1000}
)

# Use in assets
asset :fetch_user do
  requires [:api]

  execute fn ctx, _deps ->
    client = ctx.resources[:api]

    case FlowStone.HTTP.Client.get(client, "/users/#{ctx.partition.user_id}") do
      {:ok, %{status: 200, body: user}} -> {:ok, user}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end
end

# POST with idempotency key (safe retries)
asset :create_order do
  requires [:api]

  execute fn ctx, deps ->
    idempotency_key = "#{ctx.run_id}-#{ctx.partition}"

    FlowStone.HTTP.Client.post(ctx.resources[:api], "/orders", deps.order_data,
      idempotency_key: idempotency_key
    )
  end
end
```

The HTTP client automatically:
- Retries on 5xx errors and transport failures
- Respects `Retry-After` headers on 429 rate limit responses
- Uses exponential backoff with jitter
- Emits telemetry events for monitoring

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

## Testing

FlowStone provides test helpers for isolated pipeline testing:

```elixir
defmodule MyApp.PipelineTest do
  use FlowStone.TestCase, isolation: :full_isolation

  test "runs asset with mocked dependencies" do
    {:ok, result} = run_asset(MyPipeline, :doubled, with_deps: %{numbers: [1, 2, 3]})
    assert result == [2, 4, 6]
  end

  test "asserts asset existence" do
    {:ok, _} = FlowStone.run(MyPipeline, :greeting)
    assert_asset_exists(MyPipeline, :greeting)
  end
end
```

See the [Testing Guide](guides/testing.md) for more patterns.

## Telemetry

FlowStone emits telemetry events for observability:

- `[:flowstone, :materialization, :start | :stop | :exception]`
- `[:flowstone, :scatter, :start | :complete | :failed | :instance_complete | :instance_fail]`
- `[:flowstone, :signal_gate, :create | :signal | :timeout]`
- `[:flowstone, :route, :start | :stop | :error]`
- `[:flowstone, :parallel, :start | :stop | :error | :branch_start | :branch_complete | :branch_fail]`
- `[:flowstone, :http, :request, :start | :stop | :error]`
- `[:flowstone, :rate_limit, :check | :wait | :slot_acquired | :slot_released]`
- `[:flowstone, :run_config, :fallback]` - Emitted when RunConfig falls back to app config (distributed mode)
- `[:flowstone, :resources, :setup_failed]` - Emitted when a resource fails to initialize
- `[:flowstone, :route_decisions, :cleanup]` - Emitted when route decisions are cleaned up

## Low-Level API

For advanced use cases, the low-level API provides full control:

```elixir
# Manual registration with explicit options
{:ok, _} = FlowStone.Registry.start_link(name: MyRegistry)
{:ok, _} = FlowStone.IO.Memory.start_link(name: MyMemory)

FlowStone.register(MyApp.Pipeline, registry: MyRegistry)

# Configure I/O manually
io = [config: %{agent: MyMemory}]

# Materialize with explicit options
FlowStone.materialize(:report,
  partition: ~D[2025-01-15],
  registry: MyRegistry,
  io: io
)

# Materialize with all dependencies
FlowStone.materialize_all(:report,
  partition: ~D[2025-01-15],
  registry: MyRegistry,
  io: io
)
```

## Documentation

### Guides

- [Getting Started](guides/getting-started.md) - Step-by-step introduction
- [Configuration](guides/configuration.md) - Configuration options and patterns
- [Testing](guides/testing.md) - Testing patterns and helpers

### Reference

- **Design overview:** `docs/design/OVERVIEW.md`
- **Architecture decisions:** `docs/adr/README.md`
- **Comparison with Handoff:** `docs/scratch/20251215/flowstone-vs-handoff-comparison.md`
- **Examples:** `examples/` directory

### Examples

Run the examples:

```bash
# Individual examples
mix run examples/01_hello_world.exs
mix run examples/02_dependencies.exs
mix run examples/03_partitions.exs
mix run examples/04_backfill.exs
```

## Status

FlowStone is in **alpha**. Core execution, persistence primitives, and safety hardening are implemented. The v0.5.2 release adds maintenance and resilience improvements including route decision cleanup, resilient resource initialization, and improved documentation for distributed deployments.

## Contributing

Contributions are welcome. Please read the ADRs first to understand current decisions and constraints.

## License

MIT
