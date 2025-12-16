# ADR-0007: Scheduling and Sensor Framework

## Status
Accepted

## Context

Production workflows need to run:

- On a schedule (cron-like)
- In response to external events (new file, webhook, DB change)
- With dynamic partition generation (today’s date, current hour, etc.)

FlowStone should provide primitives for scheduling and polling sensors without forcing a single “ops model” (single-node vs clustered, library-only vs full platform).

## Decision

### 1. Lightweight In-Process Scheduler for Cron-Like Schedules

FlowStone includes:

- `FlowStone.Schedule` (schedule struct)
- `FlowStone.ScheduleStore` (in-memory registry)
- `FlowStone.Schedules.Scheduler` (GenServer that computes next run via `Crontab` and calls `FlowStone.materialize/2`)

This scheduler is appropriate for development and single-node deployments. For production-grade, multi-node cron semantics, host applications may prefer Oban Cron (or an external scheduler) and treat FlowStone’s `schedule/2` as a configuration source.

Implementation:
- `lib/flowstone/schedule.ex`
- `lib/flowstone/schedule_store.ex`
- `lib/flowstone/schedules/scheduler.ex`

### 2. Sensor Behaviour + Generic Polling Worker

FlowStone defines a `FlowStone.Sensor` behaviour:

- `init/1` returns initial sensor state
- `poll/1` returns `{:trigger, partition, new_state}` / `{:no_trigger, new_state}` / `{:error, reason, new_state}`

FlowStone also includes a generic polling worker `FlowStone.Sensors.Worker` that:

- calls `sensor.module.poll(state)` on an interval
- invokes `sensor.on_trigger.(partition)` on triggers
- broadcasts sensor triggers on PubSub topic `"sensors"` when a PubSub server is configured

Sensors are configured as maps/structs containing:

- `:name` (identifier)
- `:module` (implements `FlowStone.Sensor`)
- `:config` (passed to `init/1`)
- `:poll_interval` (ms)
- `:on_trigger` (function)
- `:pubsub` (optional pubsub server name/pid)

Implementation:
- `lib/flowstone/sensor.ex`
- `lib/flowstone/sensors/worker.ex`
- `lib/flowstone/sensors/s3_file_arrival.ex` (example sensor)

## Consequences

### Positive

1. Scheduling and sensors are available as library primitives.
2. Host applications can choose between lightweight in-process scheduling and Oban Cron/external schedulers.
3. Sensors remain testable via injected functions and supervised workers.

### Negative

1. `ScheduleStore` is in-memory; schedules do not persist across restarts unless the host application persists and reloads them.
2. Sensor polling is inherently “pull-based” and can introduce latency/load.

## References

- `lib/flowstone/schedule.ex`
- `lib/flowstone/schedules/scheduler.ex`
- `lib/flowstone/sensor.ex`
- `lib/flowstone/sensors/worker.ex`
