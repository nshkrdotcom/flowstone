# FlowStone Architectural Critique

**Author:** Claude Opus 4.5
**Date:** 2025-12-22

---

## 1. Supervision Tree Design

### Issue: Flat Supervision Without Restart Strategies

The application supervision tree (`application.ex`) uses a flat `one_for_one` strategy:

```elixir
# lib/flowstone/application.ex:21
Supervisor.start_link(children, strategy: :one_for_one, name: FlowStone.Supervisor)
```

**Problems:**
1. No hierarchical supervision - all services are peers
2. No distinction between critical and optional services
3. Repo failure affects nothing; Resources failure affects nothing else

**Recommendation:** Consider a tiered supervision tree:
```
FlowStone.Supervisor (rest_for_one)
├── Core (one_for_one)
│   ├── Repo
│   └── RunConfig
├── Services (one_for_one)
│   ├── Resources
│   └── MaterializationStore
└── Workers (one_for_one)
    └── Oban
```

**Severity:** Low - Current design works, but lacks resilience sophistication

---

## 2. Registry Design - Agent vs Registry Module

### Issue: Using Agent Instead of Elixir Registry

The `FlowStone.Registry` module uses a simple Agent:

```elixir
# lib/flowstone/registry.ex:8-10
def start_link(opts \\ []) do
  name = Keyword.get(opts, :name, __MODULE__)
  Agent.start_link(fn -> %{} end, name: name)
end
```

**Problems:**
1. **No concurrent read optimization** - Agent serializes all operations
2. **No ETS backing** - Each read blocks
3. **No key-based partitioning** - Single process bottleneck

**Comparison with Elixir's Registry:**
- `Registry` uses ETS with `:read_concurrency` for O(1) lookups
- `Agent` requires message passing for every operation

**Impact:** With large pipelines or high-frequency asset lookups, this could become a bottleneck.

**Recommendation:** Consider using ETS directly or Elixir's `Registry` module with `:unique` keys.

**Severity:** Low - Unlikely to be a bottleneck in practice

---

## 3. IO Manager Resolution

### Issue: Runtime Manager Resolution Every Call

Every IO operation resolves the manager dynamically:

```elixir
# lib/flowstone/io.ex:69-79
defp resolve_manager(opts) do
  managers = Application.get_env(:flowstone, :io_managers, %{})
  default = Application.get_env(:flowstone, :default_io_manager, :memory)
  key = Keyword.get(opts, :io_manager, default)
  config = Keyword.get(opts, :config, %{})

  manager =
    Map.fetch!(managers, key)
    |> ensure_loaded()

  {manager, config}
end
```

**Problems:**
1. **Application.get_env on every IO call** - Reads from ETS but still overhead
2. **Code.ensure_loaded every time** - Redundant after first call
3. **No caching** - Same resolution happens repeatedly

**Mitigation:** Application config is relatively fast, and `ensure_loaded` is idempotent.

**Recommendation:** Consider compile-time module resolution or process-level caching.

**Severity:** Low - Micro-optimization

---

## 4. Context Building

### Issue: Context Struct vs Map Inconsistency

`Context.build/4` creates a struct, but asset fields access it as a map:

```elixir
# Asset execution uses Map.get patterns:
Map.get(asset, :routed_from)
Map.get(asset, :route_fn)
Map.get(asset, :parallel_branches, %{})
```

While Context is properly typed:
```elixir
%Context{run_id: ..., partition: ..., ...}
```

**Observation:** Assets themselves are structs (`%FlowStone.Asset{}`), but are consistently accessed with `Map.get/3` rather than pattern matching or direct field access.

**Impact:**
- Loses compile-time guarantees
- No dialyzer warnings for typos in field names
- Indicates possible schema drift between struct definition and usage

**Severity:** Low - Style issue, not functional

---

## 5. DAG Cycle Detection

### Issue: Exception-Based Control Flow

The DAG cycle detection uses exceptions for control flow:

```elixir
# lib/flowstone/dag.ex:74-79
defp detect_cycle(edges) do
  topological_names(%{edges: edges})
  :ok
rescue
  ArgumentError -> {:error, {:cycle, []}}
end
```

And the visit function raises:
```elixir
# lib/flowstone/dag.ex:55-56
cond do
  Map.has_key?(visiting, node) ->
    raise ArgumentError, "cycle detected involving #{inspect(node)}"
```

**Problems:**
1. Exception-based control flow is an anti-pattern in Elixir
2. Empty cycle list loses diagnostic information
3. Performance overhead of stack trace capture

**Recommendation:** Refactor to return `{:error, {:cycle, path}}` through the recursion.

**Severity:** Low - Works correctly but not idiomatic

---

## 6. Scatter/Barrier Atomicity

### Issue: Transaction Scope in Scatter Operations

Scatter barrier operations wrap individual steps in transactions, but the overall flow isn't atomic:

```elixir
# lib/flowstone/scatter.ex:73-79
defp create_standard_barrier(scatter_keys, opts) do
  with {:ok, barrier} <- start_barrier(Keyword.put(opts, :emit_start, false)),
       {:ok, _count} <- insert_results(barrier.id, scatter_keys) do
    updated = Repo.get!(Barrier, barrier.id)
    emit_telemetry(:start, updated)
    {:ok, updated}
  end
end
```

Each of `start_barrier` and `insert_results` has its own transaction, but failure between them could leave orphaned barriers.

**Impact:**
- Barrier created but results not inserted = stuck barrier
- Recovery requires manual cleanup

**Recommendation:** Wrap entire barrier creation in a single transaction.

**Severity:** Medium - Could cause inconsistent state on failure

---

## 7. Parallel Execution Model

### Issue: No Backpressure for Scatter Jobs

When enqueuing scatter jobs, all jobs are inserted at once:

```elixir
# lib/flowstone/scatter.ex:830-843
defp enqueue_scatter_jobs(barrier, asset, scatter_keys, scatter_opts) do
  Enum.each(scatter_keys, fn scatter_key ->
    args = %{...}
    ScatterWorker.new(args, queue: scatter_opts.queue, priority: scatter_opts.priority)
    |> Oban.insert()
  end)
  :ok
end
```

**Problems:**
1. 100,000 scatter keys = 100,000 Oban jobs inserted synchronously
2. No batching of job insertion
3. Memory pressure during large scatters

**Mitigation:** Oban handles this reasonably well, but the initial insert is a chokepoint.

**Recommendation:** Use `Oban.insert_all/2` with chunking for large scatter operations.

**Severity:** Medium - Could cause timeouts on large scatters

---

## 8. Missing Graceful Shutdown

### Issue: No Shutdown Handling

The application has no graceful shutdown hooks:

```elixir
# lib/flowstone/application.ex - No stop/1 callback
# No Application.stop callback defined
```

**Problems:**
1. In-flight Oban jobs may be interrupted
2. Partial materializations not cleaned up
3. RunConfig entries orphaned

**Recommendation:** Implement proper shutdown sequencing:
```elixir
@impl true
def stop(_state) do
  # Wait for in-flight jobs
  # Clean up RunConfig entries
  # Close resources gracefully
end
```

**Severity:** Low - OTP handles basics, but explicit cleanup is better

---

## Summary

| Issue | Severity | Effort | Priority |
|-------|----------|--------|----------|
| Scatter transaction scope | Medium | Medium | P2 |
| Scatter job backpressure | Medium | Low | P2 |
| Supervision tree design | Low | High | P4 |
| Registry implementation | Low | Medium | P4 |
| IO manager resolution | Low | Low | P5 |
| DAG exception control flow | Low | Low | P4 |
| Graceful shutdown | Low | Medium | P3 |
| Context/Asset map access | Low | High | P5 |
