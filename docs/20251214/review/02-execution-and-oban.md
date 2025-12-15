# Execution Model & Oban Integration Review

This document focuses on the materialization execution path, Oban job modeling, and dependency semantics.

## 1) Oban Args Serialization is a Production-Blocking Issue

### 1.1 Non-JSON Values in Job Args

`FlowStone.build_args/2` includes values that do not safely round-trip through JSON:

- atoms (e.g. registry name)
- keyword lists (e.g. `io` options), which are lists of tuples
- module names / process names for servers (`resource_server`, `lineage_server`, `materialization_store`)

See: `lib/flowstone.ex` (`build_args/2`).

**Why this is fundamental**
- Oban persists job `args` as JSON.
- Tuples and many runtime terms are not JSON encodable.
- Even when an atom is encodable, it round-trips as a string; the worker then treats it as an atom/pid name.

**Likely outcomes**
- Job insertion fails at runtime (JSON encoding/type casting failures).
- Or job inserts, but `perform/1` fails later due to invalid server names/options.

### 1.2 The Worker Assumes the Wrong Types

`FlowStone.Workers.AssetWorker.perform/1` expects:
- `"registry"` to be an atom/pid usable by `Agent.get/2` (`lib/flowstone/workers/asset_worker.ex`)
- `"io"` to be a keyword list suitable for `FlowStone.IO.*` calls

In a DB-backed Oban flow, those assumptions won’t hold.

### 1.3 Tests Don’t Catch It (Inline Mode Hides Round-Trip)

`config/test.exs` sets `Oban` to `testing: :inline`, and tests frequently pass atoms/keywords directly into the job args or through `FlowStone.materialize_async/2`.

This can mask issues that only appear when jobs are actually persisted and reloaded from the DB.

**Recommendation**
- Define a strict JSON schema for Oban args (strings, numbers, booleans, lists, maps).
- Avoid passing runtime server references and keyword lists through Oban.
- Add a test that round-trips `args` through JSON (or inserts + fetches a job from the DB) to validate production behavior.

## 2) Defaults are Overridden by `nil` in the Oban Path

`FlowStone.build_args/2` always includes keys like `"resource_server" => nil` unless the caller explicitly passes a value.

The worker forwards `resource_server: nil` into `Executor.materialize/2`, which causes this in `Executor`:

```elixir
resource_server = Keyword.get(opts, :resource_server, Application.get_env(..., FlowStone.Resources))
```

If `opts` contains `resource_server: nil`, the default is not applied and `Context.build/4` loads no resources.

See: `lib/flowstone.ex`, `lib/flowstone/workers/asset_worker.ex`, `lib/flowstone/executor.ex`, `lib/flowstone/context.ex`.

**Recommendation**
- Either omit absent keys from Oban args entirely, or treat `nil` as “unset” in `Executor` (e.g. `Keyword.get(opts, :resource_server) || default`).

## 3) Dependency Semantics are “Existence-Based” and Can Use Stale Data

### 3.1 Worker-Level Dependency Gate Uses `IO.exists?/3`

`AssetWorker.check_dependencies/4` snoozes until dependency outputs exist in storage (`lib/flowstone/workers/asset_worker.ex`).

**Risk**
- Existence ≠ correctness. It does not guarantee:
  - the dependency succeeded for the current run,
  - the dependency is up-to-date with upstream changes,
  - the dependency corresponds to the same `run_id`.

This can lead to **run inconsistency**: downstream assets may compute using old upstream data.

### 3.2 `materialize_all/2` Doesn’t Model Dependencies in the Queue

`FlowStone.materialize_all/2` enqueues assets (or runs them) based on a recursive dependency list, but it doesn’t establish hard job ordering. The system relies on the snooze loop to eventually converge.

See: `lib/flowstone.ex` (`materialize_all/2`, `dependencies_for/2`).

**Recommendation**
- Prefer a deterministic execution plan:
  - derive a topological order using `FlowStone.DAG.topological_names/1`,
  - enqueue jobs with explicit sequencing or job prerequisites (or a single “run coordinator” job).
- Gate dependencies on materialization records (success for a specific run/partition) rather than storage existence.

## 4) Backfill Concurrency is Inverted

In `FlowStone.backfill/2`:
- when Oban is running, it uses `Task.async_stream/3` to enqueue jobs concurrently.
- when Oban is not running (synchronous execution), it runs sequentially and ignores `max_parallel`.

See: `lib/flowstone.ex` (`backfill/2`).

**Recommendation**
- Parallelize the *actual work* (when running synchronously), not the enqueue loop.
- If Oban is the execution engine, just enqueue deterministically and let Oban handle concurrency via queues.

## 5) API Semantics are Confusing Around Sync vs Async

`FlowStone.materialize/2` is documented as synchronous, but it enqueues via Oban whenever Oban is running (`lib/flowstone.ex`).

**Impact**
- Callers can’t reason about whether a materialization has happened or only been queued.
- Return types are inconsistent (`:ok` vs `{:ok, %Oban.Job{}}`), which leaks execution-engine details into the API surface.

**Recommendation**
- Make the behavior explicit in naming and return values:
  - `materialize_sync/2` vs `materialize_async/2`, or
  - `materialize/2` always queues and returns a typed “run handle”.

## 6) “Unique Jobs” and Snoozing May Not Match Intended Semantics

`FlowStone.Workers.AssetWorker` uses `unique: [period: 60, fields: [:args]]` (`lib/flowstone/workers/asset_worker.ex`).

**Risks**
- Uniqueness is coupled to the full args payload; if args include `run_id` or IO configuration, deduplication may not align with “asset+partition” uniqueness.
- The dependency gate snoozes in fixed 30s increments and rechecks via storage (`IO.exists?/3`), potentially adding latency and load.

**Recommendation**
- Define uniqueness explicitly in terms of stable keys (e.g. `{asset_name, partition}`) and make it independent of incidental configuration.
- Use metadata-driven readiness checks (materialization status) rather than repeated storage reads where possible.
