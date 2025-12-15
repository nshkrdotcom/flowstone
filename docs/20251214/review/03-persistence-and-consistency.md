# Persistence, Consistency & Data Model Review

This document focuses on correctness and durability of materialization/lineage/audit/approval persistence, and the consistency model across “store the output” vs “record the metadata”.

## 1) Materialization Records: Race Conditions and Missing Invariants

### 1.1 No Uniqueness Constraints

The materializations table has indexes but no unique constraint (migration: `priv/repo/migrations/0001_create_materializations.exs`).

The write path frequently does:
- `Repo.get_by(...)`
- then `Repo.insert()` if missing

See: `lib/flowstone/materializations.ex` (`update_record/4`).

**Risk**
- Concurrent workers can insert duplicates for the same `{asset_name, partition, run_id}`.
- Downstream “latest” queries may observe inconsistent results.

**Recommendation**
- Add a unique index on `{asset_name, partition, run_id}` (or whatever key defines identity).
- Use `insert_all ... on_conflict: ...` or `Repo.insert(..., on_conflict: ...)` patterns.

### 1.2 In-Memory `latest/3` is Incorrect

In store mode, `MaterializationStore.list/1` returns `Map.values/1`, which is not ordered. `MaterializationContext.latest/3` filters the list and takes `List.last/1`.

See: `lib/flowstone/materialization_store.ex`, `lib/flowstone/materialization_context.ex`.

**Risk**
- “Latest” is effectively random in the fallback store.
- `FlowStone.backfill/2` uses `latest/3` to decide whether to skip partitions, which can become nondeterministic.

**Recommendation**
- Store entries in an ordered structure (e.g. append-only list) or sort by `started_at/inserted_at`.

### 1.3 Repo-or-Fallback Semantics Aren’t Consistent

Repo usage is gated differently across modules:
- `FlowStone.Materializations` requires both `:start_repo` and a running Repo process (`lib/flowstone/materializations.ex`)
- `FlowStone.MaterializationContext` checks only whether the Repo process exists (`lib/flowstone/materialization_context.ex`)

**Impact**
- Two callers asking the “same question” (e.g. “what’s the latest materialization?”) can observe different persistence backends depending on which module/function is used.

**Recommendation**
- Centralize the “should we use Repo?” decision in a single module and reuse it consistently.

## 2) Output Storage and Metadata Writes are Not Transactionally Coupled

In `Executor.materialize/2` the flow is broadly:

1. record start
2. execute asset
3. store output via IO manager
4. record success
5. record lineage
6. audit log

See: `lib/flowstone/executor.ex`.

**Risks**
- If `IO.store/4` succeeds but `record_success/6` fails (DB outage), storage shows data exists while metadata shows “running”/missing.
- Several calls are written as `:ok = ...` so failures can crash the worker mid-flight, with partial side effects already committed.

**Recommendation**
- Define an explicit consistency model:
  - best-effort metadata (accept divergence), or
  - “metadata is authoritative” (then storage should be idempotent and only committed after metadata).
- Consider an `Ecto.Multi` for metadata operations, and treat storage as an external side effect with compensating actions.
- Avoid `:ok = ...` assertions for IO operations; return structured errors and record failures consistently.

### 2.1 Error Recording Can Duplicate Writes

`FlowStone.Materializer.execute/3` records errors via `FlowStone.ErrorRecorder.record/2`, which itself may write a materialization failure (`lib/flowstone/materializer.ex`, `lib/flowstone/error_recorder.ex`). `Executor.materialize/2` then also records failure in its error branch (`lib/flowstone/executor.ex`).

**Impact**
- Redundant/competing updates increase DB load and complicate debugging.
- With weak uniqueness constraints, redundant writes can also amplify race conditions.

**Recommendation**
- Decide on a single place responsible for recording materialization failure (Executor vs Materializer) and keep ErrorRecorder focused on logging/telemetry.

## 3) Approvals and Checkpoints are Not Integrated with Execution

`FlowStone.Materializer.execute/3` treats `{:wait_for_approval, attrs}` as an error (`FlowStone.Error.execution_error/4`) after creating an approval and marking the materialization as `:waiting_approval`.

See: `lib/flowstone/materializer.ex`, `lib/flowstone/error.ex`, `lib/flowstone/workers/asset_worker.ex`.

**Risk**
- `AssetWorker.perform/1` discards non-retryable errors. “Waiting approval” becomes a discarded job with no native resume mechanism.
- `flowstone_approvals.materialization_id` exists but is not wired from materializations to approvals (`priv/repo/migrations/0002_create_approvals.exs`).

**Recommendation**
- Model “waiting approval” as a first-class, retryable/snoozable job state:
  - return `{:snooze, ...}` until approved/rejected, or
  - split into two jobs: “request approval” and “continue after approval”.
- Link approvals to materialization records via `materialization_id` and/or `{run_id, asset, partition}`.

## 4) Lineage Recording is Partial and Potentially Unsafe

### 4.1 Atom Conversion from DB Values

`LineagePersistence.upstream/3` and `downstream/3` convert `asset_name` strings to atoms using `String.to_atom/1`.

See: `lib/flowstone/lineage_persistence.ex`.

**Risk**
- If untrusted data ever enters lineage tables, atom conversion can exhaust the VM atom table.

**Recommendation**
- Prefer keeping asset names as strings in lineage query results, or use `String.to_existing_atom/1` with a controlled set of registered assets.

### 4.2 `upstream_materialization_id` is Present but Unused

The schema and migration include `upstream_materialization_id`, but `record/5` doesn’t populate it.

See: `lib/flowstone/lineage/entry.ex`, `priv/repo/migrations/0003_create_lineage.exs`, `lib/flowstone/lineage_persistence.ex`.

**Recommendation**
- Either:
  - store and enforce the join to the upstream materialization record, or
  - remove the field until it is implemented to avoid a misleading schema.
