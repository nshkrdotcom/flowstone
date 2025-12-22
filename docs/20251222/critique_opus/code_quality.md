# FlowStone Code Quality Critique

**Author:** Claude Opus 4.5
**Date:** 2025-12-22

---

## 1. Error Wrapping Duplication

### Issue: Multiple `wrap/1` Functions

The codebase has several nearly identical `wrap/1` private functions:

```elixir
# lib/flowstone/materializer.ex:417-419
defp wrap(reason) when is_binary(reason), do: %RuntimeError{message: reason}
defp wrap(reason) when is_atom(reason), do: %RuntimeError{message: Atom.to_string(reason)}
defp wrap(reason), do: %RuntimeError{message: inspect(reason)}

# lib/flowstone/executor.ex:250-252
defp wrap(reason) when is_binary(reason), do: %RuntimeError{message: reason}
defp wrap(reason) when is_atom(reason), do: %RuntimeError{message: Atom.to_string(reason)}
defp wrap(reason), do: %RuntimeError{message: inspect(reason)}

# lib/flowstone/scatter.ex:855-860
defp wrap_reason(reason) when is_binary(reason), do: %RuntimeError{message: reason}
defp wrap_reason(reason) when is_atom(reason), do: %RuntimeError{message: Atom.to_string(reason)}
defp wrap_reason(reason), do: %RuntimeError{message: inspect(reason)}
```

**Problems:**
1. Code duplication across three modules
2. No single source of truth for error wrapping
3. Risk of divergence during maintenance

**Recommendation:** Extract to `FlowStone.Error.wrap_reason/1`.

**Severity:** Low - Duplication but stable

---

## 2. Inconsistent Option Handling

### Issue: Mixed Keyword/Map Patterns

Some modules use keyword lists, others use maps for options:

```elixir
# Keyword pattern (scatter.ex)
Keyword.fetch!(opts, :scatter_keys)
Keyword.get(opts, :batch_options)

# Map pattern (api.ex)
Keyword.get(opts, :partition, @default_partition)

# Direct struct access (scatter/options.ex)
scatter_opts.max_concurrent
```

**Observation:** This is largely consistent within modules, but API boundaries could be cleaner.

**Recommendation:** Define explicit typespecs and consider using structs for complex option sets.

**Severity:** Low - Style preference

---

## 3. Long Parameter Lists

### Issue: Functions with 6+ Parameters

Several internal functions have lengthy parameter lists:

```elixir
# lib/flowstone/scatter.ex:437-447
defp stream_inline(
       reader_mod,
       state,
       config,
       %{item_selector_fn: item_selector} = asset,
       deps,
       barrier,
       scatter_opts,
       opts
     )
```

**Problems:**
1. Harder to read and maintain
2. Easy to pass arguments in wrong order
3. Indicates possible missing abstraction

**Recommendation:** Consider a context struct:
```elixir
defp stream_inline(%StreamContext{} = ctx)
```

**Severity:** Low - Internal functions, well-tested

---

## 4. Magic Strings

### Issue: Hardcoded String Constants

Various string constants are hardcoded:

```elixir
# lib/flowstone/io/postgres.ex:99-100
defp default_table(asset) when is_atom(asset), do: "flowstone_#{asset}"

# lib/flowstone/workers/asset_worker.ex:37-38
run_id = Map.fetch!(args, "run_id")
use_repo = Map.get(args, "use_repo", true)
```

**Observation:** These are mostly intentional design choices (table naming, JSON keys).

**Recommendation:** Consider module attributes for frequently used strings:
```elixir
@run_id_key "run_id"
@use_repo_key "use_repo"
```

**Severity:** Low - Not a significant issue

---

## 5. Telemetry Event Naming

### Issue: Inconsistent Event Structure

Telemetry events have varying structures:

```elixir
# Some use [:flowstone, :module, :event]
[:flowstone, :io, :load, :start]
[:flowstone, :io, :load, :stop]

# Some use [:flowstone, :concept, :event]
[:flowstone, :route, :start]
[:flowstone, :materialization, :start]

# Some use [:flowstone, :concept, :sub_event]
[:flowstone, :scatter, :batch_start]
[:flowstone, :scatter, :batch_complete]
```

**Problems:**
1. No consistent naming convention
2. Harder to set up catch-all handlers
3. Documentation overhead

**Recommendation:** Standardize on `[:flowstone, <domain>, <action>]` pattern.

**Severity:** Low - Cosmetic, but affects observability

---

## 6. Deep Nesting

### Issue: Deeply Nested Conditionals

Some functions have deep nesting:

```elixir
# lib/flowstone/materializer.ex - handle_route_selection has multiple levels
defp handle_route_selection(asset, context, selection, available_branches) do
  case normalize_selection(selection, available_branches) do
    {:ok, selection} ->
      persist_route_decision(asset, context, selection, available_branches, %{})
    {:error, reason} ->
      handle_route_error(asset, context, reason)
  end
end

defp handle_route_evaluation_error(asset, context, reason, available_branches) do
  case Map.get(asset, :route_error_policy, :fail) do
    :fail ->
      handle_route_error(asset, context, reason)
    {:fallback, fallback} ->
      apply_fallback(asset, context, fallback, available_branches, reason)
    other ->
      handle_route_error(asset, context, {:invalid_on_error, other})
  end
end
```

**Observation:** The nesting is reasonable given the complexity, and function extraction helps.

**Severity:** Low - Already well-structured

---

## 7. Boolean Parameter Anti-Pattern

### Issue: Boolean Flags in Function Signatures

Several functions accept boolean flags:

```elixir
# lib/flowstone/executor.ex:21
use_repo = Keyword.get(opts, :use_repo, true)

# lib/flowstone/scatter.ex:313
if oban_running?() and Keyword.get(opts, :enqueue_reader, true) do
```

**Problems:**
1. `materialize(asset, use_repo: true)` vs `materialize(asset, use_repo: false)` - what's the difference?
2. Callsites become unclear without checking documentation

**Alternative:** Explicit modes or separate functions:
```elixir
materialize_with_persistence(asset, opts)
materialize_memory_only(asset, opts)
```

**Severity:** Low - Well-documented in specs

---

## 8. Spec Coverage

### Issue: Incomplete Typespecs

Some public functions lack typespecs:

```elixir
# lib/flowstone/registry.ex - No specs
def register_assets(assets, opts \\ []) when is_list(assets)
def fetch(name, opts \\ [])
def list(opts \\ [])

# lib/flowstone/api.ex - Has specs
@spec run(module(), atom(), keyword()) :: {:ok, term()} | {:error, term()}
```

**Impact:**
- Dialyzer cannot catch type errors
- Documentation is incomplete
- IDE support reduced

**Recommendation:** Add typespecs to all public functions.

**Severity:** Medium - Affects maintainability

---

## 9. Module Documentation

### Issue: Inconsistent @moduledoc Quality

Documentation quality varies:

**Good:**
```elixir
# lib/flowstone/scatter.ex
@moduledoc """
Core Scatter functionality for dynamic fan-out.

Scatter enables runtime-discovered parallel execution...
## Overview
## Example
"""
```

**Minimal:**
```elixir
# lib/flowstone/registry.ex
@moduledoc """
In-memory registry for asset definitions.
"""
```

**Recommendation:** Standardize on Overview + Example + Key Functions format.

**Severity:** Low - Documentation debt

---

## 10. Dead Code Suspicion

### Issue: Unused Return Values

Some function calls don't use their return values:

```elixir
# lib/flowstone/io.ex:82-84
defp ensure_loaded(module) when is_atom(module) do
  _ = Code.ensure_loaded(module)  # Good - explicitly ignored
  module
end

# lib/flowstone/io/postgres.ex:62-67
def delete(asset, partition, config) do
  with ... do
    Repo.query("DELETE FROM #{table} WHERE #{partition_col} = $1", [...])
    :ok  # Query result ignored
  end
end
```

**Observation:** Most ignored values are intentional, but the Postgres delete doesn't handle query errors.

**Recommendation:** Check if `{:error, reason}` should propagate from delete.

**Severity:** Low - Mostly intentional

---

## Summary

| Issue | Severity | Effort | Priority |
|-------|----------|--------|----------|
| Missing typespecs | Medium | Medium | P2 |
| Error wrapping duplication | Low | Low | P3 |
| Long parameter lists | Low | Medium | P4 |
| Telemetry naming | Low | Medium | P4 |
| Magic strings | Low | Low | P5 |
| Boolean parameters | Low | High | P5 |
| Module documentation | Low | Medium | P4 |
| Deep nesting | Low | N/A | - |
| Inconsistent options | Low | High | P5 |
| Dead code | Low | Low | P4 |
