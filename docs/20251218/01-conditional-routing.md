# Design Doc: Conditional Routing

**Status:** Draft
**Author:** AI Assistant
**Date:** 2025-12-18
**FlowStone Version:** 0.4.0 (proposed)

## 1. Overview

### Problem Statement

FlowStone currently supports only linear, deterministic asset dependencies. An asset declares its upstream dependencies via `depends_on`, and the DAG is static at definition time. This means:

- Every declared dependency is always executed
- There's no way to conditionally skip assets based on runtime data
- Branching logic must be embedded within asset `execute_fn` functions, making pipelines harder to understand and monitor

AWS Step Functions provides `Choice` states that enable conditional branching based on runtime data. Your production state machine uses this pattern extensively:

```json
"Choice - Search Type": {
  "Type": "Choice",
  "Choices": [
    {
      "Variable": "$.state.search_type",
      "StringEquals": "mgrs",
      "Next": "Identify Region (MGRS)"
    }
  ],
  "Default": "Identify Region (Name)"
}
```

### Goals

1. Enable conditional asset execution based on runtime data
2. Support both "choose one of N" and "optional execution" patterns
3. Maintain DAG integrity and visualization capabilities
4. Preserve compile-time validation where possible
5. Integrate cleanly with existing FlowStone concepts (scatter, signal gates)

### Non-Goals

1. Full Step Functions ASL expression language compatibility
2. Dynamic asset creation at runtime
3. Loops or cycles in the DAG (remains acyclic)

## 2. Design

### 2.1 Core Concept: Route Function

Introduce a `route` directive that determines which downstream asset(s) to execute based on upstream data.

```elixir
defmodule ReportPipeline do
  use FlowStone.Pipeline

  asset :initial_state do
    execute fn _ctx, input ->
      {:ok, %{search_type: input.search_type, query: input.query}}
    end
  end

  # Router asset - no execute_fn, just routing logic
  asset :identify_region_router do
    depends_on [:initial_state]

    route fn %{initial_state: state} ->
      case state.search_type do
        "mgrs" -> :identify_region_mgrs
        _ -> :identify_region_name
      end
    end
  end

  asset :identify_region_mgrs do
    routed_from :identify_region_router
    execute fn ctx, deps -> ... end
  end

  asset :identify_region_name do
    routed_from :identify_region_router
    execute fn ctx, deps -> ... end
  end

  # Downstream can depend on either (they're mutually exclusive)
  asset :store_region do
    depends_on [:identify_region_mgrs, :identify_region_name]
    optional_deps [:identify_region_mgrs, :identify_region_name]
    execute fn ctx, deps ->
      # Only one will be present
      region = deps[:identify_region_mgrs] || deps[:identify_region_name]
      {:ok, store(region)}
    end
  end
end
```

### 2.2 Alternative: Inline Route Syntax

For simpler cases, allow inline routing without a separate router asset:

```elixir
asset :identify_region do
  depends_on [:initial_state]

  route fn %{initial_state: %{search_type: type}} ->
    case type do
      "mgrs" -> {:branch, :mgrs}
      _ -> {:branch, :name}
    end
  end

  branch :mgrs do
    execute fn ctx, deps ->
      Lambda.invoke("identify-region-mgrs", deps.initial_state)
    end
  end

  branch :name do
    execute fn ctx, deps ->
      Lambda.invoke("identify-region-name", deps.initial_state)
    end
  end
end
```

### 2.3 Route Return Values

The `route` function can return:

| Return Value | Behavior |
|-------------|----------|
| `:asset_name` | Execute single asset |
| `[:asset_a, :asset_b]` | Execute multiple assets (parallel) |
| `{:branch, :name}` | Execute inline branch |
| `nil` | Skip all routed assets |
| `{:error, reason}` | Fail the routing decision |

### 2.4 Asset Struct Changes

```elixir
defstruct [
  # ... existing fields ...

  # Conditional routing
  :route_fn,           # fn(deps) -> atom | [atom] | {:branch, atom} | nil
  :routed_from,        # atom - the router asset this depends on
  :branches,           # %{atom => branch_config} for inline branches
  :optional_deps,      # [atom] - deps that may not be materialized
]
```

### 2.5 DAG Representation

Routed assets create "virtual edges" in the DAG that may or may not be traversed:

```
                    ┌─────────────────────┐
                    │   initial_state     │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │  identify_region    │
                    │     (router)        │
                    └──────────┬──────────┘
                               │
              ┌────────────────┼────────────────┐
              │ (if mgrs)      │                │ (if name)
              ▼                │                ▼
    ┌─────────────────┐        │      ┌─────────────────┐
    │ identify_mgrs   │        │      │ identify_name   │
    └────────┬────────┘        │      └────────┬────────┘
             │                 │               │
             └─────────────────┴───────────────┘
                               │
                    ┌──────────▼──────────┐
                    │    store_region     │
                    └─────────────────────┘
```

### 2.6 Execution Semantics

1. **Router Evaluation**: When a router asset is reached, its `route_fn` is called with resolved upstream dependencies
2. **Branch Selection**: The returned asset name(s) are validated against declared routed assets
3. **Selective Materialization**: Only selected branches are materialized
4. **Dependency Resolution**: Downstream assets with `optional_deps` receive `nil` for non-materialized branches
5. **Lineage Tracking**: Lineage records which branch was taken

### 2.7 Persistence Schema

```elixir
# New table: flowstone_route_decisions
defmodule FlowStone.Repo.Migrations.AddRouteDecisions do
  use Ecto.Migration

  def change do
    create table(:flowstone_route_decisions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :run_id, :uuid, null: false
      add :router_asset, :string, null: false
      add :partition, :string
      add :selected_branches, {:array, :string}, null: false
      add :available_branches, {:array, :string}, null: false
      add :route_input_hash, :string  # For debugging/replay
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create index(:flowstone_route_decisions, [:run_id])
    create index(:flowstone_route_decisions, [:router_asset, :partition])
  end
end
```

## 3. Implementation

### 3.1 DSL Macros

```elixir
# In FlowStone.Pipeline

defmacro route(fun) do
  quote do
    var!(current_asset) = %{var!(current_asset) | route_fn: unquote(fun)}
  end
end

defmacro routed_from(router_asset) do
  quote do
    var!(current_asset) = %{var!(current_asset) | routed_from: unquote(router_asset)}
  end
end

defmacro optional_deps(deps) when is_list(deps) do
  quote do
    var!(current_asset) = %{var!(current_asset) | optional_deps: unquote(deps)}
  end
end

defmacro branch(name, do: block) do
  quote do
    branch_config = %{name: unquote(name)}
    var!(current_branch) = branch_config
    unquote(block)

    existing_branches = var!(current_asset).branches || %{}
    var!(current_asset) = %{
      var!(current_asset) |
      branches: Map.put(existing_branches, unquote(name), var!(current_branch))
    }
  end
end
```

### 3.2 Router Module

```elixir
defmodule FlowStone.Router do
  @moduledoc """
  Evaluates route functions and records routing decisions.
  """

  alias FlowStone.{Asset, Repo}
  alias FlowStone.Router.Decision

  @doc """
  Evaluate a router asset and determine which branches to execute.
  """
  @spec evaluate(Asset.t(), map(), keyword()) ::
    {:ok, [atom()]} | {:error, term()}
  def evaluate(%Asset{route_fn: route_fn} = asset, deps, opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    partition = Keyword.get(opts, :partition)

    case safe_call(route_fn, deps) do
      {:ok, result} ->
        branches = normalize_branches(result, asset)
        record_decision(run_id, asset, partition, branches)
        {:ok, branches}

      {:error, reason} ->
        {:error, {:route_failed, asset.name, reason}}
    end
  end

  defp normalize_branches(nil, _asset), do: []
  defp normalize_branches(atom, _asset) when is_atom(atom), do: [atom]
  defp normalize_branches(list, _asset) when is_list(list), do: list
  defp normalize_branches({:branch, name}, asset) do
    if Map.has_key?(asset.branches || %{}, name) do
      [{:inline, asset.name, name}]
    else
      raise "Unknown branch #{inspect(name)} in asset #{asset.name}"
    end
  end

  defp safe_call(fun, deps) do
    {:ok, fun.(deps)}
  rescue
    e -> {:error, e}
  end

  defp record_decision(run_id, asset, partition, branches) do
    available = get_available_branches(asset)

    %Decision{}
    |> Decision.changeset(%{
      run_id: run_id,
      router_asset: to_string(asset.name),
      partition: partition && FlowStone.Partition.serialize(partition),
      selected_branches: Enum.map(branches, &to_string/1),
      available_branches: Enum.map(available, &to_string/1)
    })
    |> Repo.insert!()
  end
end
```

### 3.3 Executor Integration

The `FlowStone.Executor` must be modified to:

1. Detect router assets (assets with `route_fn`)
2. Evaluate the route function before proceeding
3. Only materialize selected branches
4. Pass `nil` for optional dependencies that weren't materialized

```elixir
defmodule FlowStone.Executor do
  # ... existing code ...

  defp execute_asset(%Asset{route_fn: route_fn} = asset, deps, opts)
       when not is_nil(route_fn) do
    # This is a router asset
    case Router.evaluate(asset, deps, opts) do
      {:ok, branches} ->
        # Materialize selected branches
        results = Enum.map(branches, fn branch ->
          case branch do
            {:inline, _asset, branch_name} ->
              execute_inline_branch(asset, branch_name, deps, opts)
            asset_name ->
              FlowStone.materialize(asset_name, opts)
          end
        end)

        {:ok, %{selected: branches, results: results}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

### 3.4 DAG Validation

At compile/registration time, validate:

1. All `routed_from` references point to assets with `route_fn`
2. Route functions can only return known routed assets
3. No circular routing (A routes to B which routes to A)
4. Optional deps match routed asset alternatives

```elixir
defmodule FlowStone.DAG do
  # ... existing code ...

  def validate_routing(assets) do
    routers = Enum.filter(assets, & &1.route_fn)
    routed = Enum.filter(assets, & &1.routed_from)

    # Check all routed_from references are valid
    router_names = MapSet.new(routers, & &1.name)

    for asset <- routed do
      unless MapSet.member?(router_names, asset.routed_from) do
        raise "Asset #{asset.name} declares routed_from #{asset.routed_from}, " <>
              "but that asset is not a router"
      end
    end

    :ok
  end
end
```

## 4. Examples

### 4.1 Simple Branch (Your Search Type Pattern)

```elixir
defmodule ReportPipeline do
  use FlowStone.Pipeline

  asset :format_input do
    execute fn _ctx, input ->
      {:ok, %{
        search_type: input["search_type"],
        query: input["query"],
        report_id: input["report_id"]
      }}
    end
  end

  asset :identify_region do
    depends_on [:format_input]

    route fn %{format_input: %{search_type: type}} ->
      case type do
        "mgrs" -> :identify_region_mgrs
        _ -> :identify_region_name
      end
    end
  end

  asset :identify_region_mgrs do
    routed_from :identify_region
    depends_on [:format_input]

    execute fn _ctx, %{format_input: input} ->
      AWS.Lambda.invoke("identify-region-mgrs", %{
        mgrs: input.query,
        report_id: input.report_id
      })
    end
  end

  asset :identify_region_name do
    routed_from :identify_region
    depends_on [:format_input]

    execute fn _ctx, %{format_input: input} ->
      AWS.Lambda.invoke("identify-region-name", %{
        query: input.query
      })
    end
  end

  asset :store_region do
    depends_on [:identify_region_mgrs, :identify_region_name]
    optional_deps [:identify_region_mgrs, :identify_region_name]

    execute fn _ctx, deps ->
      region = deps[:identify_region_mgrs] || deps[:identify_region_name]
      AWS.DynamoDB.put_item("report-region", region)
    end
  end
end
```

### 4.2 Environment-Based Routing (Progress Updates)

```elixir
asset :check_environment do
  depends_on [:state]

  route fn %{state: %{environment: env}} ->
    if env in ["staging", "production"] do
      :send_progress_update
    else
      nil  # Skip in development
    end
  end
end

asset :send_progress_update do
  routed_from :check_environment
  depends_on [:state]

  execute fn _ctx, %{state: state} ->
    AWS.Lambda.invoke("send-progress-update", %{
      report_id: state.report_id,
      status: "gathering"
    })
  end
end

asset :fetch_artifacts do
  # This runs regardless of whether progress update was sent
  depends_on [:check_environment]
  optional_deps [:send_progress_update]

  execute fn _ctx, deps ->
    # Continue with fetching...
  end
end
```

### 4.3 Multi-Way Branch

```elixir
asset :data_source_router do
  depends_on [:config]

  route fn %{config: %{source: source}} ->
    case source do
      "s3" -> :load_from_s3
      "postgres" -> :load_from_postgres
      "api" -> :load_from_api
      _ -> {:error, "Unknown source: #{source}"}
    end
  end
end
```

## 5. Migration Path

### From Step Functions

| Step Functions | FlowStone |
|---------------|-----------|
| `Choice` state | `route fn` |
| `Choices[].Variable` | Pattern match on deps |
| `Choices[].StringEquals` | `==` comparison |
| `Choices[].NumericGreaterThan` | `>` comparison |
| `Default` | Final clause in `case`/`cond` |

### Conversion Example

**Step Functions:**
```json
{
  "Type": "Choice",
  "Choices": [
    {
      "Variable": "$.state.search_type",
      "StringEquals": "mgrs",
      "Next": "Identify Region (MGRS)"
    }
  ],
  "Default": "Identify Region (Name)"
}
```

**FlowStone:**
```elixir
route fn %{state: %{search_type: type}} ->
  case type do
    "mgrs" -> :identify_region_mgrs
    _ -> :identify_region_name
  end
end
```

## 6. Telemetry

```elixir
# Route evaluation
[:flowstone, :route, :start]
[:flowstone, :route, :stop]    # measurements: %{duration_ms: _}
[:flowstone, :route, :error]

# Metadata includes:
# - router_asset: atom
# - selected_branches: [atom]
# - run_id: uuid
# - partition: term
```

## 7. Open Questions

1. **Should inline branches share the parent asset's name for lineage?**
   - Option A: Yes, `{:identify_region, :mgrs}`
   - Option B: No, generate unique names like `:identify_region__mgrs`

2. **How to handle routing errors?**
   - Option A: Fail the entire run
   - Option B: Allow fallback/default branch
   - Option C: Configurable per-router

3. **Should we support computed branch names?**
   - e.g., `route fn deps -> String.to_existing_atom("process_#{deps.type}")`
   - Risk: unbounded atom creation

4. **Integration with Scatter?**
   - Can a router asset also scatter? (Probably no - pick one)
   - Can a scattered instance do routing? (Yes, each instance routes independently)

## 8. Appendix: Full DSL Grammar

```
asset_definition ::=
  asset name do
    [description text]
    [depends_on [atom, ...]]
    [optional_deps [atom, ...]]
    [routed_from atom]
    [route fn]
    [branch name do ... end]*
    [execute fn]
    [scatter fn]
    [scatter_options do ... end]
    [gather fn]
    [on_signal fn]
    [on_timeout fn]
  end

route_fn ::= fn(deps) ->
  atom                    # single branch
  | [atom, ...]           # multiple branches (parallel)
  | {:branch, atom}       # inline branch
  | nil                   # skip all
  | {:error, term}        # routing error
```
