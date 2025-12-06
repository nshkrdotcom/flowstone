# FlowStone Live Examples Guide

This document outlines a suite of end-to-end examples you can run in a single development environment to validate FlowStone features as they evolve. Each example is self-contained and intended to be executed live (e.g., in `iex -S mix`). Adapt paths and module names as needed.

## 0) Prerequisites
- PostgreSQL reachable at the credentials in `config/dev.exs` (defaults to `localhost/postgres:postgres`).
- One-time setup:
  ```bash
  MIX_ENV=dev mix deps.get
  MIX_ENV=dev mix ecto.create
  MIX_ENV=dev mix ecto.migrate
  ```
- Start the app with Oban enabled (for async paths, checkpoints, scheduling):
  ```bash
  MIX_ENV=dev mix run --no-halt
  ```
  or enter `iex -S mix` for interactive runs.
- To run the bundled examples: `MIX_ENV=dev mix run examples/run_all.exs`

## 1) Core Asset Execution
Create a pipeline module under `dev/` (or in `iex`) to validate registration, dependency resolution, and synchronous execution.
```elixir
defmodule Examples.CorePipeline do
  use FlowStone.Pipeline

  asset :source do
    execute fn _, _ -> {:ok, "hello"} end
  end

  asset :echo do
    depends_on([:source])
    execute fn _, %{source: msg} -> {:ok, String.upcase(msg)} end
  end
end
```
Run:
```elixir
{:ok, _} = start_supervised({FlowStone.Registry, name: :dev_registry})
{:ok, _} = start_supervised({FlowStone.IO.Memory, name: :dev_io})
FlowStone.register(Examples.CorePipeline, registry: :dev_registry)

FlowStone.materialize(:echo,
  partition: :p1,
  registry: :dev_registry,
  io: [config: %{agent: :dev_io}],
  resource_server: nil
)
FlowStone.IO.load(:echo, :p1, config: %{agent: :dev_io})
```
Expected: `{:ok, "HELLO"}` stored and returned.

## 2) Partitioning & Backfill
Validate partition metadata, partition_fn, and backfill skipping logic.
```elixir
defmodule Examples.PartitionedPipeline do
  use FlowStone.Pipeline

  asset :daily_metric do
    partitioned_by :date
    partition fn _opts -> Date.range(~D[2024-01-01], ~D[2024-01-03]) end
    execute fn ctx, _ -> {:ok, {:value, ctx.partition}} end
  end
end
```
Run:
```elixir
FlowStone.register(Examples.PartitionedPipeline, registry: :dev_registry)
{:ok, result} =
  FlowStone.backfill(:daily_metric,
    registry: :dev_registry,
    io: [config: %{agent: :dev_io}],
    resource_server: nil,
    materialization_store: FlowStone.MaterializationStore,
    use_repo: false,
    max_parallel: 2
  )
result.partitions  # expect three dates
result.skipped     # expect [] on first run
```
Re-run without `:force` to confirm previously successful partitions are skipped; add `force: true` to rerun all.

## 3) Async Materialization (Oban)
Confirm async path when Oban is running.
```elixir
FlowStone.materialize_async(:echo,
  partition: :p2,
  registry: :dev_registry,
  io: [config: %{agent: :dev_io}],
  resource_server: nil
)
FlowStone.ObanHelpers.drain()
FlowStone.IO.load(:echo, :p2, config: %{agent: :dev_io})
```
Expected: returns either `:ok` (inline) or `{:ok, %Oban.Job{}}` and stores data after draining.

## 4) Checkpoints & Approvals
Demonstrate `{:wait_for_approval, attrs}` and approval lifecycle.
```elixir
defmodule Examples.ApprovalPipeline do
  use FlowStone.Pipeline

  asset :gated do
    execute fn _ctx, _deps ->
      {:wait_for_approval, %{message: "Proceed?", context: %{reason: "demo"}}}
    end
  end
end

FlowStone.register(Examples.ApprovalPipeline, registry: :dev_registry)
FlowStone.materialize(:gated,
  partition: :p3,
  registry: :dev_registry,
  io: [config: %{agent: :dev_io}],
  resource_server: nil
)
# Approval is stored (Repo) and timeout job enqueued on checkpoints queue
FlowStone.Approvals.list_pending()
[#FlowStone.Approval{id: id} | _] = FlowStone.Approvals.list_pending()
FlowStone.Approvals.approve(id, by: "user@example.com")
```
Expected: materialization status moves to `waiting_approval`, approval status becomes `:approved`, telemetry emits checkpoint events, and timeout worker would mark expired if left pending.

## 5) Scheduling (Cron)
Validate cron scheduling with dynamic partitions.
```elixir
:ok =
  FlowStone.schedule(:echo,
    cron: "* * * * *",
    partition: fn -> Date.utc_today() end,
    store: FlowStone.ScheduleStore,
    registry: :dev_registry,
    io: [config: %{agent: :dev_io}],
    resource_server: nil,
    use_repo: false
  )
{:ok, sched} = start_supervised({FlowStone.Schedules.Scheduler, store: FlowStone.ScheduleStore})
# Trigger immediately for demo
schedule = hd(FlowStone.list_schedules(store: FlowStone.ScheduleStore))
FlowStone.Schedules.Scheduler.run_now(schedule, sched)
FlowStone.ObanHelpers.drain()
FlowStone.IO.load(:echo, Date.utc_today(), config: %{agent: :dev_io})
```

## 6) Health, Telemetry, Metrics
- Health: `FlowStone.Health.status()` returns statuses for repo/oban/resources.
- Telemetry: attach handlers to `FlowStone.Telemetry.events/0` to observe materialization and checkpoint events.
- Metrics: with `TelemetryMetricsPrometheus.Core` available, start the exporter and scrape `flowstone.materialization.*`, `flowstone.io.*`, and `flowstone.checkpoint.*` metrics.

## 7) Lineage
Ensure lineage is recorded when using Repo or the in-memory Lineage server.
```elixir
FlowStone.Lineage.upstream(:echo, :p1, FlowStone.Lineage)
FlowStone.Lineage.downstream(:source, :p1, FlowStone.Lineage)
FlowStone.LineagePersistence.impact(:echo, :p1, use_repo: false, server: FlowStone.Lineage)
```

## 8) Sensors (Mock S3)
Use the S3FileArrival sensor with a mock list function to trigger materialization:
```elixir
sensor = %{
  name: :file_sensor,
  module: FlowStone.Sensors.S3FileArrival,
  config: %{bucket: "demo", prefix: "incoming/", list_fun: fn _, _ -> {:ok, MapSet.new(["incoming/2024-01-01/data.csv"])} end,
            partition_fn: fn key -> key |> String.split("/") |> Enum.at(1) |> Date.from_iso8601!() end},
  poll_interval: 10,
  on_trigger: fn partition ->
    FlowStone.materialize_async(:sensor_asset,
      partition: partition,
      registry: :dev_registry,
      io: [config: %{agent: :dev_io}],
      resource_server: nil,
      use_repo: false
    )
  end,
  pubsub: FlowStone.PubSub.Server
}
{:ok, pid} = FlowStone.Sensors.Worker.start_link(sensor)
send(pid, :poll)
FlowStone.ObanHelpers.drain()
FlowStone.IO.load(:sensor_asset, ~D[2024-01-01], config: %{agent: :dev_io})
```

## 9) External IO (Postgres)
Demonstrate storing composite partitions via Postgres IO:
```elixir
alias FlowStone.Repo
Repo.query!("CREATE TABLE IF NOT EXISTS flowstone_pg_example (partition text PRIMARY KEY, data bytea, updated_at timestamp)")

partition = {:tenant_1, "west"}
io_opts = [io_manager: :postgres, config: %{table: "flowstone_pg_example", format: :binary}]
FlowStone.materialize(:pg_asset,
  partition: partition,
  registry: :dev_registry,
  io: io_opts,
  resource_server: nil
)
FlowStone.ObanHelpers.drain()
FlowStone.IO.load(:pg_asset, partition, io_opts)
```

## 10) Failure Modes
Simulate errors and inspect materialization records:
```elixir
run_id = Ecto.UUID.generate()
FlowStone.materialize(:flaky,
  partition: :will_fail,
  registry: :dev_registry,
  io: [config: %{agent: :dev_io}],
  resource_server: nil,
  materialization_store: FlowStone.MaterializationStore,
  use_repo: false,
  run_id: run_id
)
FlowStone.ObanHelpers.drain()
FlowStone.MaterializationStore.get(:flaky, :will_fail, run_id, FlowStone.MaterializationStore)
```

## 11) Suggested Directory Layout for Examples
- `dev/core_pipeline.ex`: core dependency + sync execution.
- `dev/partitioned_pipeline.ex`: partition_fn and backfill coverage.
- `dev/approval_pipeline.ex`: checkpoint/approval flow.
- `dev/schedule_demo.ex`: cron scheduling example.
- `dev/sensor_demo.ex`: S3FileArrival (or other) sensor trigger.
- `dev/postgres_demo.ex`: Postgres IO manager + composite partitions.
- `dev/README.md`: quickstart steps above with `iex` snippets.

Keep examples minimal, runnable in `iex -S mix`, and prefer `FlowStone.IO.Memory` for storage. Each example should be verifiable via `FlowStone.IO.load/3`, approval status checks, or telemetry handlers, without external services beyond Postgres and Oban.***
