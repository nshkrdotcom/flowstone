# Getting Started with FlowStone

This guide walks you through building your first FlowStone pipeline.

## Prerequisites

- Elixir 1.15 or later
- PostgreSQL (optional, for persistence)

## Installation

Add FlowStone to your `mix.exs`:

```elixir
def deps do
  [
    {:flowstone, "~> 0.5.0"}
  ]
end
```

Run `mix deps.get` to fetch the dependency.

## Your First Pipeline

Create a simple pipeline that processes numbers:

```elixir
# lib/my_app/number_pipeline.ex
defmodule MyApp.NumberPipeline do
  use FlowStone.Pipeline

  asset :source_numbers do
    execute fn _, _ ->
      {:ok, [1, 2, 3, 4, 5]}
    end
  end

  asset :doubled do
    depends_on [:source_numbers]
    execute fn _, %{source_numbers: nums} ->
      {:ok, Enum.map(nums, &(&1 * 2))}
    end
  end

  asset :sum do
    depends_on [:doubled]
    execute fn _, %{doubled: nums} ->
      {:ok, Enum.sum(nums)}
    end
  end
end
```

## Running Assets

FlowStone's high-level API makes it simple to run assets:

```elixir
# Run an asset (dependencies are resolved automatically)
{:ok, 30} = FlowStone.run(MyApp.NumberPipeline, :sum)

# Check the result
{:ok, 30} = FlowStone.get(MyApp.NumberPipeline, :sum)

# Check if it exists
true = FlowStone.exists?(MyApp.NumberPipeline, :sum)
```

No explicit registration or server configuration needed. FlowStone automatically:
- Registers your pipeline
- Starts an in-memory storage agent
- Resolves and executes dependencies

## Understanding Dependencies

FlowStone builds a DAG (Directed Acyclic Graph) from your asset dependencies:

```
source_numbers
      │
      ▼
   doubled
      │
      ▼
     sum
```

When you run `:sum`, FlowStone:
1. Checks if `:source_numbers` is cached; if not, executes it
2. Checks if `:doubled` is cached; if not, executes it using `:source_numbers`
3. Executes `:sum` using `:doubled`
4. Caches and returns the result

## Working with Partitions

Partitions let you organize data by time or other dimensions:

```elixir
defmodule MyApp.DailyPipeline do
  use FlowStone.Pipeline

  asset :daily_data do
    execute fn ctx, _ ->
      # ctx.partition contains the partition value
      date = ctx.partition
      {:ok, fetch_data_for_date(date)}
    end
  end

  asset :daily_report do
    depends_on [:daily_data]
    execute fn ctx, %{daily_data: data} ->
      {:ok, generate_report(data, ctx.partition)}
    end
  end
end

# Run for specific dates
{:ok, _} = FlowStone.run(MyApp.DailyPipeline, :daily_report, partition: ~D[2025-01-15])
{:ok, _} = FlowStone.run(MyApp.DailyPipeline, :daily_report, partition: ~D[2025-01-16])

# Each partition is cached separately
{:ok, report_15} = FlowStone.get(MyApp.DailyPipeline, :daily_report, partition: ~D[2025-01-15])
{:ok, report_16} = FlowStone.get(MyApp.DailyPipeline, :daily_report, partition: ~D[2025-01-16])
```

## Backfilling Multiple Partitions

Process multiple partitions efficiently:

```elixir
# Backfill a month of data
{:ok, stats} = FlowStone.backfill(MyApp.DailyPipeline, :daily_report,
  partitions: Date.range(~D[2025-01-01], ~D[2025-01-31])
)

IO.puts("Succeeded: #{stats.succeeded}")
IO.puts("Failed: #{stats.failed}")
IO.puts("Skipped: #{stats.skipped}")

# Parallel backfill for faster processing
{:ok, stats} = FlowStone.backfill(MyApp.DailyPipeline, :daily_report,
  partitions: Date.range(~D[2025-01-01], ~D[2025-01-31]),
  parallel: 4
)
```

## Cache Management

FlowStone caches results to avoid re-computation:

```elixir
# First run executes the asset
{:ok, result1} = FlowStone.run(MyApp.NumberPipeline, :sum)

# Second run returns cached result
{:ok, result2} = FlowStone.run(MyApp.NumberPipeline, :sum)

# Force re-execution
{:ok, result3} = FlowStone.run(MyApp.NumberPipeline, :sum, force: true)

# Invalidate cache
{:ok, 1} = FlowStone.invalidate(MyApp.NumberPipeline, :sum)

# Next run will re-execute
{:ok, result4} = FlowStone.run(MyApp.NumberPipeline, :sum)
```

## Pipeline Introspection

Explore your pipeline structure:

```elixir
# List all assets
FlowStone.assets(MyApp.NumberPipeline)
# => [:source_numbers, :doubled, :sum]

# Get asset details
FlowStone.asset_info(MyApp.NumberPipeline, :doubled)
# => %{name: :doubled, depends_on: [:source_numbers]}

# Visualize the DAG
IO.puts(FlowStone.graph(MyApp.NumberPipeline))
# Prints ASCII art representation

# Get Mermaid diagram
mermaid = FlowStone.graph(MyApp.NumberPipeline, format: :mermaid)
```

## Pipeline Module Shortcuts

Each pipeline module gets convenience methods:

```elixir
# These are equivalent:
FlowStone.run(MyApp.NumberPipeline, :sum)
MyApp.NumberPipeline.run(:sum)

FlowStone.get(MyApp.NumberPipeline, :sum)
MyApp.NumberPipeline.get(:sum)

FlowStone.exists?(MyApp.NumberPipeline, :sum)
MyApp.NumberPipeline.exists?(:sum)

FlowStone.assets(MyApp.NumberPipeline)
MyApp.NumberPipeline.assets()
```

## DSL Shortcuts

### Short-Form Assets

For simple assets, use the short form:

```elixir
# Short form
asset :config, do: {:ok, %{batch_size: 100}}

# Equivalent long form
asset :config do
  execute fn _, _ -> {:ok, %{batch_size: 100}} end
end
```

### Implicit Result Wrapping

Skip the `{:ok, ...}` wrapper with `wrap_results: true`:

```elixir
defmodule MyApp.SimplePipeline do
  use FlowStone.Pipeline, wrap_results: true

  asset :numbers do
    execute fn _, _ -> [1, 2, 3, 4, 5] end  # Automatically wrapped
  end

  asset :doubled do
    depends_on [:numbers]
    execute fn _, %{numbers: nums} -> Enum.map(nums, &(&1 * 2)) end
  end
end
```

## Error Handling

FlowStone provides structured errors:

```elixir
# Unknown asset
{:error, %FlowStone.Error{type: :asset_not_found}} =
  FlowStone.run(MyApp.NumberPipeline, :unknown)

# Execution failure
{:error, %FlowStone.Error{type: :execution_error}} =
  FlowStone.run(MyApp.FailingPipeline, :will_fail)

# Dependency not ready (when using with_deps: false)
{:error, %FlowStone.Error{type: :dependency_not_ready}} =
  FlowStone.run(MyApp.NumberPipeline, :sum, with_deps: false)
```

## Next Steps

- [Configuration Guide](configuration.md) - Learn about persistence and advanced configuration
- [Testing Guide](testing.md) - Write tests for your pipelines
- Run examples from the `examples/` directory (e.g., `mix run examples/01_hello_world.exs`)
