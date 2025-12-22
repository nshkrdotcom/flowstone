Here is a review of the codebase identifying architectural risks, design shortcomings, and refactoring opportunities.

### 1. Critical Architectural Limitations

#### Distributed Execution vs. `RunConfig`
The reliance on `FlowStone.RunConfig` (backed by local ETS) to pass runtime configuration (mock servers, dynamic IO options) to Oban workers is a significant limitation for distributed deployments.

*   **The Issue:** `RunConfig` stores configuration in the memory of the node that enqueues the job. If the Oban worker runs on a different node, `RunConfig.get(run_id)` will return `nil`. The worker logic currently falls back to application-wide defaults (`config.exs`), meaning runtime overrides passed to `FlowStone.run/3` are lost in a multi-node cluster.
*   **Impact:** Users cannot use dynamic dependency injection (e.g., `resource_server: Pid<0.150.0>`) or dynamic IO paths in production if they run multiple nodes, unless they ensure sticky routing.
*   **Recommendation:**
    *   **Serialize Safe Config:** Move as much configuration as possible into the Oban job `args` (serialized JSON).
    *   **Distributed Registry:** For non-serializable runtime config (like PIDs in tests), the current ETS solution forces tests to run on the same node as the worker. This is acceptable for testing but risky for production features relying on it.

#### `FlowStone.Materializer` Complexity ("God Module")
`FlowStone.Materializer.execute/3` has become a bottleneck for extensibility. It contains explicit conditional logic for every asset type:

```elixir
cond do
  parallel_asset?(asset) -> {:parallel_pending, :parallel}
  router_asset?(asset) -> execute_router(asset, context, deps)
  routed_asset?(asset) -> execute_routed(asset, context, deps)
  true -> execute_normal(asset, context, deps)
end
```

*   **The Issue:** Adding a new asset type (e.g., `sensor`, `iterator`) requires modifying the core Materializer and adding more private dispatch functions.
*   **Refactoring Opportunity:** Implement a **Strategy Pattern**. Define a protocol or behaviour `FlowStone.AssetStrategy` with an `execute/3` function.
    *   `FlowStone.Assets.StandardStrategy`
    *   `FlowStone.Assets.RouterStrategy`
    *   `FlowStone.Assets.ParallelStrategy`
    The Asset struct can store the strategy module, allowing the Materializer to simply call `asset.strategy.execute(...)`.

### 2. Concurrency & Testing Model

#### Global Process Naming Collision
`FlowStone.API.ensure_pipeline_registered/1` derives process names deterministically from the pipeline module:

```elixir
defp registry_for_pipeline(pipeline), do: Module.concat(pipeline, FlowStone.Registry)
```

*   **The Issue:** If two async tests try to run `FlowStone.run(MyPipeline, ...)` simultaneously, they race to start/access the *same* global name (`MyPipeline.FlowStone.Registry`).
*   **Impact:** Developers cannot run tests with `async: true` if they use the same Pipeline module in multiple tests, slowing down test suites.
*   **Recommendation:** `FlowStone.run/3` and `ensure_pipeline_registered` should accept a `context_id` or `name_suffix` option. The `FlowStone.Test` helpers already generate a unique `test_id`; this should be propagated to suffix the generated process names, creating fully isolated environments per test process.

### 3. Module Cohesion

#### `FlowStone.Scatter` Bloat
The `FlowStone.Scatter` module is violating the Single Responsibility Principle. It currently handles:
1.  **Persistence**: `create_barrier`, `insert_results`, `complete`, `fail`.
2.  **Orchestration**: `run_inline_reader`, `stream_distributed`.
3.  **Batching Logic**: `create_batched_barrier`.
4.  **Error Handling**: `reader_error`, `wrap_reason`.

*   **Refactoring Opportunity:** Split this module:
    *   `FlowStone.Scatter.Persistence`: Handle all Ecto/Repo interactions (Barrier/Result schemas).
    *   `FlowStone.Scatter.Orchestrator`: Handle the logic of streaming readers, batching context, and job enqueueing.
    *   `FlowStone.Scatter`: Keep the public API surface here, delegating to the above.

#### Pipeline DSL Parsing Fragility
In `lib/flowstone/pipeline.ex`, the `short_form?` check relies on a hardcoded allow-list of function names to distinguish between a block containing DSL calls and a block returning a value:

```elixir
when call in [:depends_on, :execute, :description, :partition, ...]
```

*   **Risk:** Every time a new macro is added (like `batch_options`), this list must be manually updated. If missed, valid DSL syntax might be misinterpreted as a short-form return value (or vice-versa).
*   **Recommendation:** Inspect the AST for the structure rather than specific function names, or enforce a stricter syntax distinction (e.g., specific macro for short-form like `asset :name, value: ...` vs `asset :name, do: ...`).

### 4. Implementation Details & Safety

#### RunConfig Lifecycle Race Condition
`FlowStone.RunConfig` cleans up entries after 1 hour.
*   **Risk:** If a queue is backed up and a job sits in Oban for > 1 hour, it will wake up, fail to find its runtime config (registry names, IO mocks), and fall back to app defaults. This could lead to confusing failures in production under load.
*   **Recommendation:** If runtime config is missing, the worker currently logs telemetry and proceeds. It might be safer to `discard` or `snooze` if specific required keys (like a custom registry) are missing, rather than attempting to run against the default global registry which might not contain the dynamic assets.

#### HTTP Client Header Normalization
In `FlowStone.HTTP.Client`, header normalization converts keys to lowercase strings.
*   **Cleanup:** `Req` already handles case-insensitive headers. Manually normalizing them and storing them in a map might discard multi-value headers if not handled carefully (though `Req` usually handles this). Ensure `Map.new` doesn't clobber multiple headers with the same key if the API requires them.

### 5. Summary of Cleanups

| Severity | Component | Issue | Recommendation |
| :--- | :--- | :--- | :--- |
| **High** | `FlowStone.API` | Deterministic process naming prevents async testing | Add `name_suffix` to `run/3` options for isolation. |
| **Medium** | `FlowStone.Materializer` | Complex conditional logic for asset types | Implement Strategy pattern for asset execution. |
| **Medium** | `FlowStone.Scatter` | Module mixes persistence and orchestration | Extract `Scatter.Persistence` module. |
| **Medium** | `FlowStone.Pipeline` | Fragile DSL parsing (hardcoded list) | Refactor `short_form?` detection logic. |
| **Medium** | `FlowStone.RunConfig` | Node-local storage breaks distributed Oban | Document limitation clearly; prefer serializing config to Args where possible. |
