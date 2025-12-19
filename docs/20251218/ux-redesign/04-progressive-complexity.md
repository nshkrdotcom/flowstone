# Progressive Complexity

**Status:** Design Proposal
**Date:** 2025-12-18

## Overview

FlowStone should support a smooth learning curve from simple scripts to production systems. Each level adds capabilities without requiring changes to previous code.

---

## Level 1: Hello World

**Goal:** Run something in under 2 minutes.

**Deps:**
```elixir
{:flowstone, "~> 1.0"}
```

**Config:** None

**Code:**
```elixir
defmodule MyPipeline do
  use FlowStone.Pipeline

  asset :greeting do
    execute fn _, _ -> {:ok, "Hello, World!"} end
  end
end

{:ok, "Hello, World!"} = FlowStone.run(MyPipeline, :greeting)
```

**What's happening:**
- In-memory storage
- Synchronous execution
- No persistence
- Result returned directly

---

## Level 2: Dependencies

**Goal:** Chain assets together.

```elixir
defmodule DataPipeline do
  use FlowStone.Pipeline

  asset :raw do
    execute fn _, _ ->
      {:ok, [1, 2, 3, 4, 5]}
    end
  end

  asset :doubled do
    depends_on [:raw]

    execute fn _, %{raw: numbers} ->
      {:ok, Enum.map(numbers, & &1 * 2)}
    end
  end

  asset :sum do
    depends_on [:doubled]

    execute fn _, %{doubled: numbers} ->
      {:ok, Enum.sum(numbers)}
    end
  end
end

# Run final asset - dependencies run automatically
{:ok, 30} = FlowStone.run(DataPipeline, :sum)

# View the graph
IO.puts FlowStone.graph(DataPipeline)
# raw
# └── doubled
#     └── sum
```

---

## Level 3: Partitions

**Goal:** Run the same pipeline for different time periods or segments.

```elixir
defmodule DailyMetrics do
  use FlowStone.Pipeline

  asset :events do
    execute fn ctx, _ ->
      date = ctx.partition
      {:ok, load_events_for_date(date)}
    end
  end

  asset :metrics do
    depends_on [:events]

    execute fn _, %{events: events} ->
      {:ok, calculate_metrics(events)}
    end
  end
end

# Run for specific date
{:ok, metrics} = FlowStone.run(DailyMetrics, :metrics,
  partition: ~D[2025-01-15]
)

# Run for multiple dates
{:ok, stats} = FlowStone.backfill(DailyMetrics, :metrics,
  partitions: Date.range(~D[2025-01-01], ~D[2025-01-31])
)
# => %{succeeded: 31, failed: 0}
```

---

## Level 4: Persistence

**Goal:** Store results in a database.

**Deps:**
```elixir
{:flowstone, "~> 1.0"},
{:ecto_sql, "~> 3.10"},
{:postgrex, ">= 0.0.0"}
```

**Config:**
```elixir
config :flowstone, repo: MyApp.Repo
```

**Code:**
```elixir
# Same pipeline as before - no code changes!
defmodule DailyMetrics do
  use FlowStone.Pipeline

  asset :events do
    execute fn ctx, _ ->
      {:ok, load_events_for_date(ctx.partition)}
    end
  end

  asset :metrics do
    depends_on [:events]
    execute fn _, %{events: events} ->
      {:ok, calculate_metrics(events)}
    end
  end
end

# Run it
{:ok, _} = FlowStone.run(DailyMetrics, :metrics, partition: ~D[2025-01-15])

# Results are now persisted! Retrieve later:
{:ok, metrics} = FlowStone.get(DailyMetrics, :metrics, partition: ~D[2025-01-15])

# Re-running skips if already computed (cached)
{:ok, _} = FlowStone.run(DailyMetrics, :metrics, partition: ~D[2025-01-15])
# ^ Instant - uses cached result

# Force re-computation
{:ok, _} = FlowStone.run(DailyMetrics, :metrics,
  partition: ~D[2025-01-15],
  force: true
)
```

---

## Level 5: Async Execution

**Goal:** Run long tasks in background with job queue.

**Config:** Same as Level 4 (repo enables Oban automatically)

```elixir
defmodule HeavyPipeline do
  use FlowStone.Pipeline

  asset :big_computation do
    execute fn _, _ ->
      # Takes 10 minutes
      result = heavy_computation()
      {:ok, result}
    end
  end
end

# Run async - returns immediately
{:ok, %Oban.Job{id: job_id}} = FlowStone.run(HeavyPipeline, :big_computation,
  async: true
)

# Check status
FlowStone.status(HeavyPipeline, :big_computation)
# => %{state: :running, ...}

# Wait and get result (blocks until complete)
{:ok, result} = FlowStone.await(HeavyPipeline, :big_computation, timeout: 600_000)

# Or poll status
case FlowStone.status(HeavyPipeline, :big_computation) do
  %{state: :completed} -> FlowStone.get(HeavyPipeline, :big_computation)
  %{state: :running} -> :still_running
  %{state: :failed, error: e} -> {:error, e}
end
```

---

## Level 6: Scatter/Gather (Fan-out)

**Goal:** Process a list of items in parallel.

```elixir
defmodule ImagePipeline do
  use FlowStone.Pipeline

  asset :image_urls do
    execute fn _, _ ->
      {:ok, fetch_image_urls()}  # Returns 1000 URLs
    end
  end

  asset :processed_images do
    depends_on [:image_urls]

    # Fan out: one execution per URL
    scatter fn %{image_urls: urls} ->
      Enum.map(urls, &%{url: &1})
    end

    # Each scatter instance processes one image
    execute fn ctx, _ ->
      url = ctx.scatter_key.url
      {:ok, download_and_process(url)}
    end

    # Collect all results
    gather fn results ->
      {:ok, Map.values(results)}
    end
  end
end

# Runs 1000 parallel processes automatically
{:ok, _} = FlowStone.run(ImagePipeline, :processed_images, async: true)

# Monitor progress
FlowStone.status(ImagePipeline, :processed_images)
# => %{
#   state: :running,
#   scatter: %{total: 1000, completed: 450, failed: 2, pending: 548}
# }
```

**With batching:**
```elixir
asset :processed_images do
  depends_on [:image_urls]

  scatter fn %{image_urls: urls} ->
    Enum.map(urls, &%{url: &1})
  end

  # Process in batches of 10
  batch size: 10

  execute fn ctx, _ ->
    # ctx.batch_items contains 10 items
    results = Enum.map(ctx.batch_items, &process_image/1)
    {:ok, results}
  end

  gather fn results ->
    {:ok, List.flatten(Map.values(results))}
  end
end
```

---

## Level 7: External Data Sources

**Goal:** Stream items from S3, DynamoDB, or Postgres.

```elixir
defmodule DocumentPipeline do
  use FlowStone.Pipeline

  asset :processed_docs do
    # Stream documents from S3 (no need to load all into memory)
    scatter_from :s3 do
      bucket "my-documents"
      prefix "inbox/"
      suffix ".pdf"
    end

    scatter_options do
      max_concurrent 50
      rate_limit {100, :second}
    end

    execute fn ctx, _ ->
      s3_key = ctx.scatter_key.key
      {:ok, process_document(s3_key)}
    end

    gather fn results ->
      {:ok, summarize(results)}
    end
  end
end
```

**From DynamoDB:**
```elixir
scatter_from :dynamodb do
  table "documents"
  index "status-index"
  key_condition "status = :status"
  expression_values %{":status" => "pending"}
end
```

**From Postgres:**
```elixir
scatter_from :postgres do
  query "SELECT id, data FROM documents WHERE status = $1"
  params ["pending"]
end
```

---

## Level 8: Conditional Routing

**Goal:** Dynamic branching based on data.

```elixir
defmodule OrderPipeline do
  use FlowStone.Pipeline

  asset :order do
    execute fn _, _ ->
      {:ok, fetch_order()}
    end
  end

  asset :routed_order do
    depends_on [:order]

    route fn %{order: order} ->
      cond do
        order.total > 10_000 -> :high_value
        order.is_subscription -> :subscription
        true -> :standard
      end
    end

    branch :high_value do
      execute fn _, %{order: order} ->
        {:ok, process_high_value(order)}
      end
    end

    branch :subscription do
      execute fn _, %{order: order} ->
        {:ok, process_subscription(order)}
      end
    end

    branch :standard do
      execute fn _, %{order: order} ->
        {:ok, process_standard(order)}
      end
    end
  end
end
```

---

## Level 9: Parallel Branches

**Goal:** Run independent branches concurrently, join results.

```elixir
defmodule EnrichmentPipeline do
  use FlowStone.Pipeline

  asset :customer do
    execute fn _, _ -> {:ok, fetch_customer()} end
  end

  asset :enriched_customer do
    depends_on [:customer]

    parallel do
      branch :credit_score do
        execute fn _, %{customer: c} ->
          {:ok, fetch_credit_score(c.id)}
        end
      end

      branch :fraud_check do
        execute fn _, %{customer: c} ->
          {:ok, run_fraud_check(c.id)}
        end
      end

      branch :preferences do
        execute fn _, %{customer: c} ->
          {:ok, fetch_preferences(c.id)}
        end
      end
    end

    join fn %{credit_score: cs, fraud_check: fc, preferences: p}, %{customer: c} ->
      {:ok, Map.merge(c, %{
        credit_score: cs,
        fraud_status: fc,
        preferences: p
      })}
    end
  end
end
```

---

## Level 10: Approvals & Webhooks

**Goal:** Human-in-the-loop and external callbacks.

```elixir
defmodule DeployPipeline do
  use FlowStone.Pipeline

  asset :build do
    execute fn _, _ ->
      {:ok, run_build()}
    end
  end

  asset :deploy_staging do
    depends_on [:build]

    execute fn _, %{build: build} ->
      {:ok, deploy_to_staging(build)}
    end
  end

  asset :approve_production do
    depends_on [:deploy_staging]

    approval do
      message "Approve deployment to production?"
      timeout 24, :hours
      notify :slack, channel: "#deploys"
    end
  end

  asset :deploy_production do
    depends_on [:approve_production]

    execute fn _, %{build: build} ->
      {:ok, deploy_to_production(build)}
    end
  end
end

# Start pipeline - pauses at approval
FlowStone.run(DeployPipeline, :deploy_production, async: true)

# Later: approve via API or UI
FlowStone.approve(DeployPipeline, :approve_production, approved_by: "alice@example.com")
```

**Signal Gate (webhooks):**
```elixir
asset :external_processing do
  execute fn _, %{data: data} ->
    # Start external job, return signal gate
    task_id = ExternalAPI.start_job(data)
    {:signal_gate, token: task_id, timeout: :timer.hours(1)}
  end

  on_signal fn _ctx, payload ->
    # Called when webhook received
    {:ok, payload.result}
  end
end
```

---

## Level 11: AI Integration

**Goal:** Add AI-powered processing.

**Deps:**
```elixir
{:flowstone, "~> 1.0"},
{:flowstone_ai, "~> 1.0"}
```

**Config:**
```elixir
config :flowstone, repo: MyApp.Repo

config :flowstone_ai,
  provider: :anthropic,
  api_key: System.get_env("ANTHROPIC_API_KEY")
```

```elixir
defmodule FeedbackPipeline do
  use FlowStone.Pipeline
  use FlowStone.AI

  asset :feedback do
    execute fn _, _ -> {:ok, fetch_feedback()} end
  end

  asset :classified do
    depends_on [:feedback]

    execute fn ctx, %{feedback: items} ->
      FlowStone.AI.classify_each(ctx.ai, items,
        text: & &1.comment,
        labels: ["bug", "feature", "praise", "question"]
      )
    end
  end

  asset :summarized do
    depends_on [:classified]

    execute fn ctx, %{classified: items} ->
      bugs = Enum.filter(items, & &1.classification == "bug")

      FlowStone.AI.generate(ctx.ai,
        "Summarize these bug reports: #{inspect(bugs)}"
      )
    end
  end
end
```

---

## Level 12: Scheduling

**Goal:** Run pipelines on a schedule.

```elixir
defmodule ScheduledPipeline do
  use FlowStone.Pipeline

  # Run daily at 2am UTC
  schedule "0 2 * * *"

  # Partition based on schedule time
  partition fn scheduled_at ->
    Date.to_string(DateTime.to_date(scheduled_at))
  end

  asset :daily_report do
    execute fn ctx, _ ->
      {:ok, generate_report(ctx.partition)}
    end
  end
end
```

**Or via API:**
```elixir
FlowStone.schedule(MyPipeline, :asset,
  cron: "0 2 * * *",
  partition: fn time -> Date.to_string(time) end
)
```

---

## Complexity Summary

| Level | Feature | Config | New Concepts |
|-------|---------|--------|--------------|
| 1 | Hello World | None | `asset`, `execute` |
| 2 | Dependencies | None | `depends_on` |
| 3 | Partitions | None | `ctx.partition` |
| 4 | Persistence | `repo:` | Caching, `get/3` |
| 5 | Async | (same) | `async: true`, `status/3` |
| 6 | Scatter | (same) | `scatter`, `gather` |
| 7 | External Sources | (same) | `scatter_from` |
| 8 | Routing | (same) | `route`, `branch` |
| 9 | Parallel | (same) | `parallel`, `join` |
| 10 | Approvals | (same) | `approval`, `signal_gate` |
| 11 | AI | `flowstone_ai` | `use FlowStone.AI` |
| 12 | Scheduling | (same) | `schedule` |

Each level builds on the previous without requiring rewrites of existing code.
