# FlowStone Design Overview

This document provides a high-level overview of FlowStone’s current architecture and primitives (v0.2.x). For detailed decisions and rationale, see `docs/adr/README.md`.

## Core Concepts

### 1) Assets

An **asset** is a named data artifact with explicit dependencies and an execution function.

Assets are defined in Elixir via `FlowStone.Pipeline`:

```elixir
defmodule MyApp.Pipeline do
  use FlowStone.Pipeline

  asset :raw_events do
    description "Raw events from source systems"
    execute fn _context, _deps -> {:ok, :raw} end
  end

  asset :daily_report do
    depends_on [:raw_events]
    execute fn _context, %{raw_events: events} -> {:ok, {:report, events}} end
  end
end
```

### 2) Materialization

**Materialization** computes and stores an asset’s value for a specific partition.

FlowStone records materialization metadata including:

- `status` (`:pending`, `:running`, `:success`, `:failed`, `:waiting_approval`)
- timing (`started_at`, `completed_at`, `duration_ms`)
- run correlation (`run_id`)

### 3) DAG (Directed Acyclic Graph)

FlowStone derives a DAG from each asset’s `depends_on` list and uses it to:

- detect cycles
- compute a topological ordering
- traverse dependency sets for `materialize_all/2`

Implementation: `lib/flowstone/dag.ex`.

### 4) Partitions

Partitions are first-class values in code (e.g. `Date`, `DateTime`, tuples), but are serialized to strings for:

- database storage
- Oban job args

FlowStone uses a tagged partition encoding to ensure unambiguous round-trips (see ADR-0003).

Implementation: `lib/flowstone/partition.ex`.

### 5) I/O Managers

I/O managers implement `FlowStone.IO.Manager` and are selected via:

- application config (`:flowstone, :io_managers`, `:default_io_manager`)
- call-time options (passed via `io:`)

Example:

```elixir
FlowStone.materialize(:daily_report,
  partition: ~D[2025-01-15],
  io: [io_manager: :memory, config: %{agent: MyApp.MemoryAgent}]
)
```

Implementation: `lib/flowstone/io.ex`, `lib/flowstone/io/manager.ex`.

### 6) Approvals (Checkpoints)

Assets may request approval by returning `{:wait_for_approval, attrs}` from `execute`.

FlowStone persists the approval request (Repo-backed when enabled, otherwise in-memory) and marks the materialization as `:waiting_approval`.

Current core does not include a built-in continuation/resume mechanism after approval; host applications can resume by re-materializing the asset or by implementing a continuation model.

Implementation: `lib/flowstone/materializer.ex`, `lib/flowstone/approvals.ex`.

### 7) Resources

Resources are injectable runtime dependencies managed by `FlowStone.Resources` (configured via `config :flowstone, :resources`).

`FlowStone.Context.build/4` injects a subset of resources based on `asset.requires`.

Implementation: `lib/flowstone/resources.ex`, `lib/flowstone/context.ex`.

### 8) Lineage and Audit

FlowStone records lineage edges after successful materialization and exposes query APIs for:

- upstream dependency trees
- downstream dependents
- impact analysis

Repo-backed lineage uses recursive CTEs with bounded depth; there is an in-memory fallback when a lineage server is running.

Implementation: `lib/flowstone/lineage_persistence.ex`.

Audit events can be recorded to `flowstone_audit_log` when Repo usage is enabled.

Implementation: `lib/flowstone/audit_log_context.ex`.

### 9) Scheduling and Sensors

FlowStone includes:

- a lightweight in-process scheduler for cron-like schedules (`FlowStone.Schedules.Scheduler`)
- a `FlowStone.Sensor` behaviour and generic polling worker (`FlowStone.Sensors.Worker`)

Schedules are stored in-memory by default and must be persisted/reloaded by the host app if durability is required.

Implementation: `lib/flowstone/schedules/scheduler.ex`, `lib/flowstone/sensors/worker.ex`.

## Architecture Layers

```
┌─────────────────────────────────────────────────────────┐
│                    Host Application                      │
│  (pipelines, resources, IO config, supervision, UI)      │
└────────────────────────────┬────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────┐
│                   FlowStone Core API                     │
│  materialize/2, materialize_all/2, backfill/2, schedule/2│
└────────────────────────────┬────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────┐
│                    Core Components                        │
│  DAG · Executor · Materializer · IO · Lineage · Approvals │
└────────────────────────────┬────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────┐
│                  Persistence / Execution                  │
│          PostgreSQL (Ecto) + Oban (jobs, retries)          │
└─────────────────────────────────────────────────────────┘
```

## Execution Flow (High Level)

1. Define assets in a pipeline module and register them into a registry.
2. Call `FlowStone.materialize/2` with an asset name and partition.
3. If Oban is running:
   - enqueue a job with JSON-safe args
   - store non-JSON runtime wiring in `FlowStone.RunConfig` keyed by `run_id`
4. The worker resolves the asset safely against the registry, loads dependencies, executes the asset, stores output via IO manager, and records metadata + lineage.

## Design Principles

1. **Assets, not tasks**: Data artifacts are the contract.
2. **Explicit dependencies**: Derived DAG, no hidden coupling.
3. **Safe persisted boundaries**: JSON-safe args, no unbounded atom creation.
4. **Testability**: injectable servers/resources and deterministic boundary tests.
5. **Observability**: telemetry events and optional audit log persistence.

## References

- `docs/adr/README.md`
