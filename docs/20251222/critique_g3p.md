# FlowStone Codebase Critique

**Author:** GPT-4 (g3p)
**Date:** 2025-12-22

## 1. RunConfig ETS Limitation

### Issue
`FlowStone.RunConfig` uses node-local ETS storage (`@table_name :flowstone_run_config`). In a distributed Oban deployment where jobs can be picked up by any node, runtime configuration stored on Node A will not be available to workers executing on Node B.

### Impact
- Custom `io:` options, registries, and resource servers passed to `materialize/2` will not propagate to jobs on other nodes
- Workers fall back to application config, potentially using different settings

### Recommendation
Document this limitation clearly and consider distributed alternatives (Redis, database-backed config, or Oban's node affinity features).

---

## 2. Resources Startup Resilience

### Issue
`FlowStone.Resources.init/1` raises an exception if any configured resource fails to set up:

```elixir
case module.setup(config) do
  {:ok, resource} ->
    Map.put(acc, name, %{resource: resource, module: module})
  {:error, reason} ->
    raise "Failed to setup resource #{inspect(name)}: #{inspect(reason)}"
end
```

### Impact
A single failing resource (unavailable database, unreachable API) crashes the entire Resources GenServer, causing supervisor restart loops.

### Recommendation
Handle failures gracefully - log the error, mark the resource as unavailable, and continue startup with remaining resources.

---

## 3. Global Named Processes for Tests

### Issue
Pipeline process names are globally deterministic based on the pipeline module name:

```elixir
defp registry_for_pipeline(pipeline) do
  Module.concat(pipeline, FlowStone.Registry)
end

defp io_agent_for_pipeline(pipeline) do
  Module.concat(pipeline, FlowStone.IO.Memory)
end
```

### Impact
Tests for the same pipeline module cannot run with `async: true` because they share the same named processes.

### Recommendation
Accept an optional context_id parameter to generate unique process names for test isolation.

---

## 4. Materializer Complexity ("God Function")

### Issue
`FlowStone.Materializer.execute/3` handles multiple execution paths in a single function:
- Parallel asset detection
- Router asset execution
- Routed asset execution
- Normal execution

Plus sub-branches for routing rules, route functions, fallback policies, and decision caching.

### Impact
High cyclomatic complexity makes the module harder to test and maintain.

### Recommendation
Consider extracting separate modules or using protocol-based dispatch for different asset types.

---

## 5. Scatter Module Bloat

### Issue
`scatter.ex` is ~1158 lines mixing multiple concerns:
- Barrier lifecycle management
- Result persistence
- Inline and distributed streaming
- Batch processing
- Telemetry emission
- ItemReader orchestration

### Impact
Large modules are harder to navigate and modify without introducing bugs.

### Recommendation
Extract into submodules: `Scatter.Barrier`, `Scatter.Stream`, `Scatter.Batch`, etc.

---

## 6. Dynamic DSL Keyword Checking

### Issue
`short_form?/1` in `Pipeline` uses a hardcoded list of DSL keywords:

```elixir
{call, _, _}
when call in [
       :depends_on,
       :execute,
       :description,
       # ... more keywords
       :batch_options
     ] ->
  false
```

### Impact
Adding new DSL macros requires updating this list manually, which is error-prone.

### Recommendation
Consider using module attributes or compile-time reflection to build the list automatically.

---

## 7. Inconsistent IO Key Normalization

### Issue
Key normalization responsibility is split between the IO dispatcher and individual implementations. Both `Memory` and `Postgres` call `Partition.serialize/1`, but it's not clear from the interface contract.

### Impact
Adding new IO managers requires understanding the normalization pattern by reading existing implementations.

### Recommendation
Document the contract clearly or centralize normalization in the IO dispatcher.

---

## 8. Oban Job Args Schema

### Issue
`AssetWorker.perform/2` uses manual `Map.fetch!` and `Map.get` without schema validation:

```elixir
run_id = Map.fetch!(args, "run_id")
use_repo = Map.get(args, "use_repo", true)
```

### Impact
Invalid job args cause runtime crashes rather than clear validation errors.

### Recommendation
Consider using an Ecto embedded schema or NimbleOptions for args validation.

---

## 9. Security Notes (Positive)

### Strengths
The codebase demonstrates good security practices:

1. **SQL injection prevention** - Postgres IO validates identifiers:
   ```elixir
   @identifier_pattern ~r/^[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)?$/
   ```

2. **Safe binary decoding**:
   ```elixir
   :erlang.binary_to_term(data, [:safe])
   ```

3. **Atom creation protection** - Uses `String.to_existing_atom/1` throughout

These patterns should be maintained and documented as security requirements.

---

## Summary

| Area | Severity | Effort |
|------|----------|--------|
| RunConfig ETS | High | Medium |
| Resources resilience | Medium | Low |
| Test process naming | Low-Medium | Medium |
| Materializer complexity | Medium | High |
| Scatter bloat | Medium | High |
| DSL keyword list | Low | Low |
| IO normalization | Low | Low |
| Job args schema | Low | Medium |
| Security | Positive | N/A |
