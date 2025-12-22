# FlowStone Testing Critique

**Author:** Claude Opus 4.5
**Date:** 2025-12-22

---

## 1. Test Coverage by Module

### Observation: Good Coverage of Core Modules

The test suite includes 48 test files covering:

- Core: `executor_test`, `materializer_test`, `registry_test`, `pipeline_test`
- IO: `io_memory_test`, `io_postgres_test`, `io_managers_test`
- Workers: `asset_worker_test`, `scatter_batch_worker_test`
- Features: `scatter_test`, `routing_test`, `parallel_branches_test`, `signal_gate_test`
- API: `api_test`, `flowstone_test`

### Missing Test Coverage

Based on module inspection, these areas may lack dedicated tests:

1. **RunConfig** - No `run_config_test.exs` found
2. **DAG** - No `dag_test.exs` found (though tested indirectly via pipeline_test)
3. **Error** - No `error_test.exs` found
4. **ItemReader implementations** - Only `item_reader_test.exs`, unclear if S3/DynamoDB covered

**Recommendation:** Add explicit unit tests for RunConfig, DAG, and Error modules.

**Severity:** Medium - Core infrastructure should have explicit tests

---

## 2. Async Test Limitations

### Issue: Same-Pipeline Async Conflicts

As noted in the g3p critique, tests for the same pipeline module cannot safely run with `async: true`:

```elixir
# lib/flowstone/api.ex:540-545
defp registry_for_pipeline(pipeline) do
  Module.concat(pipeline, FlowStone.Registry)
end
```

### Workarounds

**Current pattern:** Tests likely use:
1. Different pipeline modules per test
2. `async: false` for shared pipelines
3. Test isolation via `FlowStone.Test` helpers

**Improvement opportunity:** Accept optional `context_id` to generate unique process names:

```elixir
def run(pipeline, asset_name, opts \\ []) do
  context_id = Keyword.get(opts, :context_id)
  registry = registry_for_pipeline(pipeline, context_id)
  # ...
end

defp registry_for_pipeline(pipeline, nil) do
  Module.concat(pipeline, FlowStone.Registry)
end

defp registry_for_pipeline(pipeline, context_id) do
  Module.concat([pipeline, FlowStone.Registry, String.to_atom(context_id)])
end
```

**Severity:** Medium - Affects test performance

---

## 3. Database Test Isolation

### Issue: Ecto Sandbox Complexity

Tests requiring database access must use Ecto sandbox:

```elixir
# Likely pattern in test_helper.exs
Ecto.Adapters.SQL.Sandbox.mode(FlowStone.Repo, :manual)
```

**Considerations:**
1. Scatter tests create barriers and results in DB
2. Oban tests need job persistence
3. Materialization tests need record storage

**Risk:** Tests that don't properly set up sandbox may leak data or deadlock.

**Recommendation:** Document sandbox requirements in test module docs.

**Severity:** Low - Standard Elixir testing challenge

---

## 4. Oban Testing Mode

### Issue: Oban Integration Testing

Oban jobs require special handling in tests:

```elixir
# Oban provides testing mode
config :flowstone, Oban, testing: :inline
```

**Testing modes:**
1. `:inline` - Jobs execute synchronously during test
2. `:manual` - Jobs must be explicitly performed
3. `:disabled` - No job processing

**Observation:** The codebase handles Oban presence gracefully:

```elixir
# lib/flowstone/scatter.ex:846-848
defp oban_running? do
  Process.whereis(Oban.Registry) != nil and Process.whereis(Oban.Config) != nil
end
```

**Recommendation:** Ensure test documentation explains Oban testing modes.

**Severity:** Low - Handled appropriately

---

## 5. Mock/Stub Patterns

### Issue: Resources Mock/Override Pattern

Resources module provides an override mechanism:

```elixir
# lib/flowstone/resources.ex:32-34
def override(map, server \\ __MODULE__) when is_map(map) do
  GenServer.cast(server, {:override, map})
end
```

**Usage:** Tests can inject mock resources:
```elixir
FlowStone.Resources.override(%{
  http_client: MockHTTPClient,
  database: MockDatabase
})
```

**Concern:** `cast` means override is async - no guarantee it completes before test runs.

**Recommendation:** Consider `call` for synchronous override, or add `await_override/1`.

**Severity:** Low - Likely not a practical issue given test sequencing

---

## 6. Scatter Test Complexity

### Issue: Scatter Requires Full Integration

Testing scatter functionality requires:
1. Database for barriers and results
2. Optionally Oban for job processing
3. ItemReader implementations (if testing distributed mode)
4. Telemetry handlers (if verifying events)

**Impact:**
- Scatter tests are inherently integration tests
- Unit testing scatter logic requires extensive mocking
- Test setup is complex

**Recommendation:**
1. Extract pure functions for unit testing (batching, key normalization)
2. Document integration test requirements
3. Consider test fixtures for common barrier setups

**Severity:** Medium - Testing friction for contributors

---

## 7. Pipeline DSL Testing

### Issue: Compile-Time vs Runtime Testing

Pipeline DSL operates at compile time:

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

**Testing challenges:**
1. DSL errors occur at compile time
2. Cannot easily test macro expansion programmatically
3. `persistent_term` persists across tests

**Current approach:** Define test pipelines and verify behavior:

```elixir
# test/flowstone/pipeline_test.exs likely contains:
defmodule TestPipeline do
  use FlowStone.Pipeline
  asset :test, do: {:ok, "value"}
end

test "runs pipeline" do
  assert {:ok, "value"} = TestPipeline.run(:test)
end
```

**Recommendation:** Add tests for invalid DSL usage (cycle detection, missing deps).

**Severity:** Low - Compile-time validation catches most issues

---

## 8. Error Path Testing

### Issue: Error Handling Coverage

The Error module provides structured errors:

```elixir
# lib/flowstone/error.ex
def execution_error(asset, partition, exception, stacktrace)
def dependency_not_ready(asset, missing)
def dependency_failed(asset, dep, reason)
```

**Testing considerations:**
1. Each error constructor should be tested
2. Error propagation through layers should be verified
3. `retryable` flag affects Oban behavior

**Unknown:** Without examining test files, unclear if error paths are comprehensively tested.

**Recommendation:** Ensure each Error constructor has unit tests.

**Severity:** Medium - Error handling is critical for production

---

## 9. Telemetry Event Testing

### Issue: Telemetry Verification

The codebase emits many telemetry events:

```elixir
[:flowstone, :io, :load, :start]
[:flowstone, :materialization, :start]
[:flowstone, :scatter, :complete]
```

**Testing approach:**
```elixir
# Install handler before test
:telemetry.attach("test-handler", [:flowstone, :io, :load, :stop], fn event, measurements, meta, _ ->
  send(self(), {:telemetry, event, measurements, meta})
end, nil)

# Verify event received
assert_receive {:telemetry, [:flowstone, :io, :load, :stop], %{duration: _}, %{asset: :test}}
```

**Observation:** `io_telemetry_test.exs` and `materialization_telemetry_test.exs` exist.

**Recommendation:** Ensure telemetry tests don't interfere with each other (unique handler IDs).

**Severity:** Low - Appears to be handled

---

## 10. Property-Based Testing Opportunity

### Observation: No Property-Based Tests

The codebase appears to use ExUnit exclusively. Property-based testing could benefit:

1. **Partition serialization** - Round-trip properties
2. **DAG validation** - Arbitrary dependency graphs
3. **Scatter key normalization** - Arbitrary input maps
4. **IO operations** - Store/load round-trips

**Recommendation:** Consider adding StreamData for critical paths.

**Severity:** Low - Nice-to-have enhancement

---

## Summary

| Issue | Severity | Effort | Priority |
|-------|----------|--------|----------|
| Missing RunConfig/DAG/Error tests | Medium | Low | P2 |
| Scatter test complexity | Medium | Medium | P3 |
| Error path coverage | Medium | Medium | P2 |
| Async test limitations | Medium | Medium | P3 |
| Resources override async | Low | Low | P4 |
| Database test isolation docs | Low | Low | P4 |
| DSL edge case testing | Low | Medium | P4 |
| Property-based testing | Low | Medium | P5 |
| Telemetry test isolation | Low | Low | P4 |
| Oban testing docs | Low | Low | P5 |
