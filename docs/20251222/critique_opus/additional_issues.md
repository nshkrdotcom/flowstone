# FlowStone Additional Issues

**Author:** Claude Opus 4.5
**Date:** 2025-12-22

Issues not covered in the g3p critique.

---

## 1. Persistent Term Usage

### Issue: Pipeline Assets in Persistent Term

Assets are stored in persistent_term at compile time:

```elixir
# lib/flowstone/pipeline.ex:130-137
def __after_compile__(env, _bytecode) do
  assets =
    env.module
    |> Module.get_attribute(:flowstone_assets)
    |> Enum.reverse()

  :persistent_term.put({env.module, :flowstone_assets}, assets)
end
```

**Concerns:**

1. **Memory pressure** - persistent_term values are never garbage collected
2. **Hot code reload** - Old assets remain until explicit cleanup
3. **Test pollution** - Compiled test pipelines persist across test runs

**Mitigation:** In practice, pipeline modules are finite and small. The data (asset definitions) is tiny.

**Risk scenario:** In development with frequent recompiles of many pipelines, memory could grow.

**Recommendation:** Consider cleanup hook or periodic persistent_term audit.

**Severity:** Low - Unlikely to be an issue in practice

---

## 2. Backfill Parallelism Unbounded

### Issue: Task.async_stream Without Memory Limits

The backfill function spawns parallel tasks:

```elixir
# lib/flowstone/api.ex:264-273
if parallel > 1 do
  to_run
  |> Task.async_stream(
    fn partition ->
      run(pipeline, asset_name, Keyword.put(opts, :partition, partition))
    end,
    max_concurrency: parallel,
    timeout: :infinity
  )
```

**Problems:**

1. **`timeout: :infinity`** - No protection against runaway tasks
2. **No memory backpressure** - Large result sets held in memory
3. **User-controlled `parallel`** - Could be set very high

**Scenario:** `parallel: 100` with slow assets creates 100 concurrent processes indefinitely.

**Recommendation:**
1. Add sensible timeout default (e.g., 30 minutes per partition)
2. Cap `parallel` to a maximum (e.g., System.schedulers_online * 2)
3. Consider streaming results instead of collecting

**Severity:** Medium - Could cause resource exhaustion

---

## 3. Missing Retry Configuration

### Issue: Fixed Retry Parameters in AssetWorker

Retry behavior is hardcoded:

```elixir
# lib/flowstone/workers/asset_worker.ex:20-23
use Oban.Worker,
  queue: :assets,
  max_attempts: 5,
  unique: [period: 60, fields: [:args], keys: [:asset_name, :partition, :run_id]]
```

**Problems:**

1. **5 attempts** may not be appropriate for all assets
2. **60-second uniqueness** may be too short or too long
3. **No per-asset configuration**

**Recommendation:** Allow asset-level retry configuration:

```elixir
asset :flaky_external_call do
  max_attempts 10
  retry_backoff :exponential
  execute fn _, _ -> ... end
end
```

**Severity:** Medium - Limits operational flexibility

---

## 4. JSON Encoding Assumptions

### Issue: Jason.encode! Without Error Handling

Several places use `Jason.encode!`:

```elixir
# lib/flowstone/io/postgres.ex:105
_ -> Jason.encode!(data)
```

**Problems:**

1. Raises on unencodable terms (functions, PIDs, references)
2. No graceful degradation
3. User data could contain unencodable values

**Scenario:** User's asset returns `%{callback: fn -> ... end}` - crash on store.

**Recommendation:** Wrap in try/rescue with informative error:

```elixir
defp encode(data, config) do
  case config[:format] do
    :binary -> :erlang.term_to_binary(data)
    _ ->
      case Jason.encode(data) do
        {:ok, json} -> json
        {:error, _} ->
          raise FlowStone.Error.validation_error(:io, "Data not JSON-encodable")
      end
  end
end
```

**Severity:** Medium - Could cause confusing crashes

---

## 5. Signal Gate Token Collision

### Issue: No Token Uniqueness Enforcement

Signal gates use tokens provided by users:

```elixir
# Usage pattern:
{:signal_gate, token: task_id, timeout: :timer.hours(1)}
```

**Problems:**

1. **No uniqueness validation** - Same token could be reused
2. **No namespace isolation** - Different runs could collide
3. **Token format not validated** - Could be empty string, nil

**Scenario:** Two concurrent runs use same `task_id` format - signals mis-routed.

**Recommendation:**
1. Auto-prefix tokens with `run_id`
2. Validate token format (non-empty, reasonable length)
3. Add uniqueness constraint in persistence layer

**Severity:** Medium - Could cause incorrect behavior

---

## 6. Partition Serialization Limits

### Issue: Complex Partitions May Fail

Partition serialization handles basic types:

```elixir
# Assumed based on usage:
# Partition.serialize handles atoms, dates, datetimes, tuples, strings
```

**Untested scenarios:**
1. Deeply nested tuples
2. Very long strings
3. Unicode edge cases
4. Tuple with non-serializable elements

**Recommendation:** Document partition type limitations and add validation.

**Severity:** Low - Most uses are simple dates/atoms

---

## 7. Circular Dependency in Application

### Issue: Module Dependencies

The application startup has implicit dependencies:

```elixir
# lib/flowstone/application.ex
children =
  [FlowStone.RunConfig]
  |> maybe_add_repo()       # Some modules need Repo
  |> maybe_add_resources()  # Resources need Repo for some adapters
  |> maybe_add_oban()       # Oban needs Repo
```

**Concern:** If Resources tries to set up a database resource, but Repo isn't started yet, it fails.

**Mitigation:** The ordering handles this (Repo added before Resources).

**Observation:** Order matters but isn't documented or enforced.

**Recommendation:** Document startup order requirements.

**Severity:** Low - Current ordering is correct

---

## 8. Memory IO Agent Naming

### Issue: Atom Table Growth

Memory IO creates named agents:

```elixir
# lib/flowstone/api.ex:544-546
defp io_agent_for_pipeline(pipeline) do
  Module.concat(pipeline, FlowStone.IO.Memory)
end
```

**Problem:** Each unique pipeline module creates a new atom.

**Scenario:** In a system generating dynamic pipeline modules, atom table could grow.

**Mitigation:** Pipeline modules are typically defined at compile time, not dynamically.

**Recommendation:** Document that dynamic pipeline generation is not supported.

**Severity:** Low - Unlikely usage pattern

---

## 9. Lineage Recording Failures Silent

### Issue: Lineage Errors Not Propagated

Lineage recording happens after success:

```elixir
# lib/flowstone/executor.ex:59
record_lineage(asset.name, partition, run_id, deps, lineage_server, use_repo)
{:ok, result}
```

**If lineage recording fails:**
1. The error is swallowed
2. Asset appears successful
3. Lineage data incomplete

**Recommendation:** Log lineage failures, optionally make configurable whether to fail the asset.

**Severity:** Low - Lineage is supplementary data

---

## 10. Route Decision Garbage

### Issue: RouteDecisions Accumulate

Route decisions are persisted but never cleaned up:

```elixir
# From materializer.ex - decisions are recorded
RouteDecisions.record(
  context.run_id,
  asset.name,
  context.partition,
  selection,
  available_branches,
  metadata: metadata
)
```

**Problem:** Database table grows indefinitely with old run decisions.

**Recommendation:**
1. Add TTL-based cleanup job
2. Or clean up when run completes
3. Or make persistence optional

**Severity:** Medium - Database bloat over time

---

## 11. Missing Health Checks

### Issue: No Built-in Health Endpoint

`health_test.exs` exists, but unclear what it tests.

**For production deployment:**
1. Is Repo connected?
2. Is Oban processing?
3. Are Resources healthy?
4. Is RunConfig ETS accessible?

**Recommendation:** Add `FlowStone.Health.check/0` returning structured health status.

**Severity:** Low - Operational concern

---

## 12. Scatter Key Size Limits

### Issue: No Validation of Scatter Key Size

Scatter keys are stored in database:

```elixir
# lib/flowstone/scatter.ex:232-236
%{
  scatter_key_hash: hash,
  scatter_key: key,  # Could be arbitrarily large
  ...
}
```

**Scenario:** User returns large maps as scatter keys - database bloat.

**Recommendation:** Warn or error if scatter key exceeds size threshold.

**Severity:** Low - User education issue

---

## Summary

| Issue | Severity | Effort | Priority |
|-------|----------|--------|----------|
| RouteDecisions garbage | Medium | Medium | P2 |
| Backfill parallelism | Medium | Low | P2 |
| Missing retry config | Medium | Medium | P2 |
| JSON encoding crashes | Medium | Low | P2 |
| Signal gate token collision | Medium | Medium | P3 |
| Lineage failure handling | Low | Low | P3 |
| Persistent term usage | Low | Low | P4 |
| Partition limits docs | Low | Low | P4 |
| Application order docs | Low | Low | P5 |
| Memory IO atom growth | Low | Low | P5 |
| Health checks | Low | Medium | P3 |
| Scatter key size | Low | Low | P4 |
