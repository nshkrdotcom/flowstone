# Design Doc: Parallel Branches

**Status:** Draft
**Author:** AI Assistant
**Date:** 2025-12-18
**FlowStone Version:** 0.4.0 (proposed)

## 1. Overview

### Problem Statement

FlowStone's current parallel execution model is **dynamic fan-out via Scatter**: given runtime data, create N identical workers processing different inputs. This maps to Step Functions' `Map` state.

However, Step Functions also provides **static parallel branches via `Parallel` state**: execute N heterogeneous workflows concurrently and join their results. Your production state machine uses this extensively:

```json
"Get Data": {
  "Type": "Parallel",
  "Next": "Summarize Artifacts",
  "Branches": [
    {
      "StartAt": "Generate Maps",
      "States": { ... }
    },
    {
      "StartAt": "Get News Front Pages",
      "States": { ... }
    },
    {
      "StartAt": "Load Web Sources Configuration",
      "States": { ... }
    }
  ]
}
```

Key differences from Scatter:

| Scatter | Parallel Branches |
|---------|------------------|
| N instances of same logic | N different workflows |
| N determined at runtime | N fixed at definition |
| Same input schema | Different input schemas |
| Homogeneous results | Heterogeneous results |
| Single `gather` function | Typed `join` with named results |

### Goals

1. Enable static parallel execution of heterogeneous asset subgraphs
2. Support named branches with typed results
3. Provide a join point that receives all branch results
4. Maintain DAG visualization and lineage tracking
5. Allow nested parallelism (branches can contain parallel or scatter)
6. Enable partial failure handling per-branch

### Non-Goals

1. Replace Scatter for dynamic fan-out (they're complementary)
2. Support cross-branch dependencies (branches are independent)
3. Streaming results (all branches must complete before join)

## 2. Design

### 2.1 Core Concept: Parallel Block

Introduce a `parallel` block that defines named branches executing concurrently:

```elixir
defmodule ReportPipeline do
  use FlowStone.Pipeline

  asset :region do
    execute fn _ctx, input -> identify_region(input) end
  end

  asset :get_data do
    depends_on [:region]

    parallel do
      branch :maps do
        asset :main_map do
          execute fn ctx, %{region: r} ->
            Lambda.invoke("get-main-maps", %{region_id: r.id})
          end
        end
      end

      branch :news do
        asset :front_pages do
          execute fn ctx, %{region: r} ->
            Lambda.invoke("get-front-page-news", %{country: r.country_code})
          end
        end
      end

      branch :web_sources do
        asset :load_sources do
          execute fn ctx, %{region: r} -> load_sources(r) end
        end

        asset :process_keywords do
          depends_on [:load_sources]
          execute fn ctx, deps -> process(deps.load_sources) end
        end
      end
    end

    join fn branches ->
      %{
        maps: branches.maps.main_map,
        news: branches.news.front_pages,
        sources: branches.web_sources.process_keywords
      }
    end
  end

  asset :summarize do
    depends_on [:get_data]
    execute fn _ctx, %{get_data: data} ->
      # data is the joined result
      summarize(data.maps, data.news, data.sources)
    end
  end
end
```

### 2.2 Execution Model

```
                    ┌─────────────────────┐
                    │       region        │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │      get_data       │
                    │   (parallel start)  │
                    └──────────┬──────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
        ▼                      ▼                      ▼
  ┌───────────┐         ┌───────────┐         ┌───────────┐
  │   :maps   │         │   :news   │         │:web_srcs  │
  ├───────────┤         ├───────────┤         ├───────────┤
  │ main_map  │         │front_pages│         │load_srcs  │
  └─────┬─────┘         └─────┬─────┘         └─────┬─────┘
        │                     │                     │
        │                     │               ┌─────▼─────┐
        │                     │               │proc_keywds│
        │                     │               └─────┬─────┘
        │                     │                     │
        └──────────────────────┴─────────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │      get_data       │
                    │    (join point)     │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │     summarize       │
                    └─────────────────────┘
```

### 2.3 Branch Semantics

Each branch:
- Has a unique name within the parallel block
- Contains one or more assets (mini-pipeline)
- Has access to parent asset's dependencies
- Produces a result (output of its terminal asset)
- Executes independently of other branches

### 2.4 Join Semantics

The `join` function:
- Receives a map of `branch_name => branch_result`
- Each `branch_result` is a map of `asset_name => materialized_value`
- Returns the final value for the parallel asset
- Only called when ALL branches complete successfully (by default)

### 2.5 Asset Struct Changes

```elixir
defstruct [
  # ... existing fields ...

  # Parallel branches
  :parallel_branches,    # %{atom => ParallelBranch.t}
  :join_fn,              # fn(branch_results) -> term
  :parallel_options,     # %{failure_mode: :all_or_nothing | :partial, ...}
]

defmodule FlowStone.ParallelBranch do
  defstruct [
    :name,
    :assets,           # [Asset.t] - ordered list of assets in branch
    :terminal_asset,   # atom - the final asset whose result is the branch result
    :timeout,          # per-branch timeout
    :required,         # boolean - must this branch succeed?
  ]
end
```

### 2.6 Persistence Schema

```elixir
# New table: flowstone_parallel_executions
defmodule FlowStone.Repo.Migrations.AddParallelExecutions do
  use Ecto.Migration

  def change do
    create table(:flowstone_parallel_executions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :run_id, :uuid, null: false
      add :parent_asset, :string, null: false
      add :partition, :string
      add :status, :string, null: false  # executing, completed, partial_failure, failed
      add :branch_count, :integer, null: false
      add :completed_count, :integer, default: 0
      add :failed_count, :integer, default: 0
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create table(:flowstone_parallel_branches, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :execution_id, references(:flowstone_parallel_executions, type: :uuid),
          null: false
      add :branch_name, :string, null: false
      add :status, :string, null: false  # pending, executing, completed, failed
      add :result, :binary  # compressed result
      add :error, :map
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:flowstone_parallel_executions, [:run_id])
    create index(:flowstone_parallel_branches, [:execution_id])
    create unique_index(:flowstone_parallel_branches, [:execution_id, :branch_name])
  end
end
```

## 3. Implementation

### 3.1 DSL Macros

```elixir
defmodule FlowStone.Pipeline do
  # ... existing macros ...

  @doc """
  Define a parallel execution block with named branches.
  """
  defmacro parallel(do: block) do
    quote do
      var!(parallel_branches) = %{}
      var!(in_parallel) = true
      unquote(block)
      var!(in_parallel) = false

      var!(current_asset) = %{
        var!(current_asset) |
        parallel_branches: var!(parallel_branches)
      }
    end
  end

  @doc """
  Define a branch within a parallel block.
  """
  defmacro branch(name, do: block) do
    quote do
      unless var!(in_parallel) do
        raise CompileError,
          description: "branch must be inside a parallel block"
      end

      var!(branch_assets) = []
      var!(current_branch_name) = unquote(name)
      unquote(block)

      branch = %FlowStone.ParallelBranch{
        name: unquote(name),
        assets: Enum.reverse(var!(branch_assets)),
        terminal_asset: List.first(var!(branch_assets)).name,
        required: true
      }

      var!(parallel_branches) = Map.put(
        var!(parallel_branches),
        unquote(name),
        branch
      )
    end
  end

  @doc """
  Define the join function for parallel results.
  """
  defmacro join(fun) do
    quote do
      var!(current_asset) = %{var!(current_asset) | join_fn: unquote(fun)}
    end
  end

  @doc """
  Configure parallel execution options.
  """
  defmacro parallel_options(do: block) do
    quote do
      var!(parallel_opts) = %{failure_mode: :all_or_nothing}
      unquote(block)
      var!(current_asset) = %{
        var!(current_asset) |
        parallel_options: var!(parallel_opts)
      }
    end
  end

  # Inside a branch, `asset` creates branch-scoped assets
  # We need to modify the asset macro to check context
end
```

### 3.2 Parallel Executor

```elixir
defmodule FlowStone.Parallel do
  @moduledoc """
  Executes parallel branches and coordinates join.
  """

  alias FlowStone.{Asset, Repo, Partition}
  alias FlowStone.Parallel.{Execution, Branch}

  @doc """
  Execute a parallel asset's branches concurrently.
  """
  @spec execute(Asset.t(), map(), keyword()) ::
    {:ok, term()} | {:error, term()}
  def execute(%Asset{parallel_branches: branches, join_fn: join_fn} = asset, deps, opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    partition = Keyword.get(opts, :partition)
    parallel_opts = asset.parallel_options || %{}

    # Create execution record
    {:ok, execution} = create_execution(run_id, asset, partition, branches)

    # Launch all branches concurrently
    tasks = for {name, branch} <- branches do
      Task.async(fn ->
        execute_branch(execution.id, name, branch, deps, opts)
      end)
    end

    # Collect results with timeout
    timeout = parallel_opts[:timeout] || :timer.minutes(30)
    results = Task.await_many(tasks, timeout)

    # Process results
    process_results(execution, branches, results, join_fn, parallel_opts)
  end

  defp execute_branch(execution_id, name, branch, parent_deps, opts) do
    mark_branch_started(execution_id, name)

    try do
      # Execute assets in branch sequentially
      result = Enum.reduce_while(branch.assets, parent_deps, fn asset, acc_deps ->
        case FlowStone.Materializer.execute(asset, acc_deps, opts) do
          {:ok, value} ->
            {:cont, Map.put(acc_deps, asset.name, value)}
          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

      case result do
        {:error, reason} ->
          mark_branch_failed(execution_id, name, reason)
          {:error, name, reason}
        deps ->
          # Get terminal asset result
          terminal_result = Map.get(deps, branch.terminal_asset)
          mark_branch_completed(execution_id, name, terminal_result)
          {:ok, name, %{result: terminal_result, deps: deps}}
      end
    rescue
      e ->
        mark_branch_failed(execution_id, name, e)
        {:error, name, e}
    end
  end

  defp process_results(execution, branches, results, join_fn, opts) do
    failure_mode = opts[:failure_mode] || :all_or_nothing

    {successes, failures} = Enum.split_with(results, fn
      {:ok, _, _} -> true
      {:error, _, _} -> false
    end)

    cond do
      # All succeeded
      Enum.empty?(failures) ->
        branch_results = Map.new(successes, fn {:ok, name, data} ->
          {name, data.result}
        end)
        joined = join_fn.(branch_results)
        finalize_execution(execution, :completed)
        {:ok, joined}

      # Some failed but partial is allowed
      failure_mode == :partial and has_required_branches?(successes, branches) ->
        branch_results = Map.new(successes, fn {:ok, name, data} ->
          {name, data.result}
        end)
        # Include nil for failed branches
        branch_results = Enum.reduce(failures, branch_results, fn {:error, name, _}, acc ->
          Map.put(acc, name, nil)
        end)
        joined = join_fn.(branch_results)
        finalize_execution(execution, :partial_failure)
        {:ok, joined}

      # Failures not tolerated
      true ->
        [{:error, name, reason} | _] = failures
        finalize_execution(execution, :failed)
        {:error, {:branch_failed, name, reason}}
    end
  end

  defp has_required_branches?(successes, branches) do
    success_names = MapSet.new(successes, fn {:ok, name, _} -> name end)

    branches
    |> Enum.filter(fn {_, branch} -> branch.required end)
    |> Enum.all?(fn {name, _} -> MapSet.member?(success_names, name) end)
  end

  # Persistence helpers
  defp create_execution(run_id, asset, partition, branches) do
    %Execution{}
    |> Execution.changeset(%{
      run_id: run_id,
      parent_asset: to_string(asset.name),
      partition: partition && Partition.serialize(partition),
      status: :executing,
      branch_count: map_size(branches)
    })
    |> Repo.insert()
  end
end
```

### 3.3 Oban Worker Integration

For async execution, branches become Oban jobs:

```elixir
defmodule FlowStone.Workers.ParallelBranchWorker do
  use Oban.Worker,
    queue: :parallel_branches,
    max_attempts: 3

  alias FlowStone.Parallel

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{
      "execution_id" => execution_id,
      "branch_name" => branch_name,
      "branch_config" => branch_config,
      "parent_deps" => parent_deps,
      "run_id" => run_id
    } = args

    # Reconstruct branch from config
    branch = deserialize_branch(branch_config)
    deps = deserialize_deps(parent_deps)
    opts = [run_id: run_id]

    case Parallel.execute_branch(execution_id, branch_name, branch, deps, opts) do
      {:ok, _, _} -> :ok
      {:error, _, reason} -> {:error, reason}
    end
  end
end
```

### 3.4 Join Coordination

When running async (Oban), we need a coordinator to detect completion:

```elixir
defmodule FlowStone.Workers.ParallelJoinWorker do
  use Oban.Worker,
    queue: :parallel_joins,
    max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"execution_id" => execution_id}}) do
    case Parallel.check_completion(execution_id) do
      {:complete, results} ->
        Parallel.execute_join(execution_id, results)
        :ok
      :pending ->
        # Re-schedule check
        {:snooze, 5}
      {:failed, reason} ->
        {:error, reason}
    end
  end
end
```

### 3.5 DAG Integration

Parallel branches create "compound nodes" in the DAG:

```elixir
defmodule FlowStone.DAG do
  # ... existing code ...

  def expand_parallel_assets(assets) do
    Enum.flat_map(assets, fn asset ->
      case asset.parallel_branches do
        nil ->
          [asset]
        branches ->
          # Create virtual assets for visualization
          branch_assets = for {name, branch} <- branches do
            Enum.map(branch.assets, fn ba ->
              %{ba | name: :"#{asset.name}__#{name}__#{ba.name}"}
            end)
          end

          [asset | List.flatten(branch_assets)]
      end
    end)
  end
end
```

## 4. Examples

### 4.1 Your "Get Data" Pattern

```elixir
defmodule ReportPipeline do
  use FlowStone.Pipeline

  asset :store_region do
    depends_on [:identify_region]
    execute fn _ctx, deps ->
      DynamoDB.put_item("report-region", deps.identify_region)
    end
  end

  asset :get_data do
    depends_on [:store_region]

    parallel do
      branch :maps do
        asset :generate_maps do
          parallel do
            branch :main_map do
              asset :get_main_map do
                execute fn ctx, %{store_region: region} ->
                  Lambda.invoke("get-main-maps", %{region_id: region.id})
                end
              end
            end
            # Could add more map types here
          end

          join fn maps -> maps end
        end
      end

      branch :news do
        asset :get_front_pages do
          execute fn ctx, %{store_region: region} ->
            Lambda.invoke("get-front-page-news", %{
              country_code: region.country_code,
              report_id: ctx.run_config.report_id
            })
          end
        end
      end

      branch :web_sources do
        asset :load_config do
          parallel do
            branch :region_sources do
              asset :check_dynamo do
                execute fn ctx, %{store_region: r} ->
                  DynamoDB.get_item("web-sources-by-region", r.region_id)
                end
              end
              # ... more assets for source discovery
            end

            branch :global_sources do
              asset :load_global do
                execute fn _ctx, _deps ->
                  DynamoDB.scan("web-sources-global")
                end
              end
            end

            branch :keywords do
              asset :load_keywords do
                execute fn _ctx, _deps ->
                  DynamoDB.get_item("search-configuration", "Keywords")
                end
              end
            end
          end

          join fn branches ->
            %{
              by_region: branches.region_sources,
              global: branches.global_sources,
              keywords: branches.keywords
            }
          end
        end

        asset :process_keywords do
          depends_on [:load_config]
          execute fn ctx, deps ->
            process_all_keywords(deps.load_config)
          end
        end
      end
    end

    join fn branches ->
      %{
        maps: branches.maps,
        news: branches.news,
        web_sources: branches.web_sources
      }
    end
  end

  asset :summarize do
    depends_on [:get_data]
    execute fn ctx, %{get_data: data} ->
      # All three branches' results available
      create_summary(data.maps, data.news, data.web_sources)
    end
  end
end
```

### 4.2 With Failure Handling

```elixir
asset :fetch_external_data do
  depends_on [:config]

  parallel do
    branch :primary_api do
      asset :call_primary do
        execute fn _ctx, _deps -> API.call_primary() end
      end
    end

    branch :backup_api do
      asset :call_backup do
        execute fn _ctx, _deps -> API.call_backup() end
      end
    end

    branch :cache do
      asset :check_cache do
        execute fn _ctx, _deps -> Cache.get(:external_data) end
      end
    end
  end

  parallel_options do
    failure_mode :partial
    timeout :timer.minutes(5)
  end

  join fn branches ->
    # Use first available result
    branches.primary_api || branches.backup_api || branches.cache ||
      raise "All data sources failed"
  end
end
```

### 4.3 Nested Parallel and Scatter

```elixir
asset :process_all_regions do
  depends_on [:region_list]

  # Scatter over regions
  scatter fn %{region_list: regions} ->
    Enum.map(regions, &%{region_id: &1})
  end

  scatter_options do
    max_concurrent 10
  end

  # Each scattered instance runs parallel branches
  execute fn ctx, _deps ->
    region_id = ctx.scatter_key.region_id

    # Could use parallel here for per-region work
    # But typically you'd extract to a separate asset
    process_region(region_id)
  end
end
```

## 5. Comparison with Scatter

| Aspect | Scatter | Parallel Branches |
|--------|---------|------------------|
| **Fan-out type** | Dynamic (runtime N) | Static (compile-time N) |
| **Worker logic** | Identical | Different per branch |
| **Data shape** | Homogeneous | Heterogeneous |
| **Join function** | `gather fn` | `join fn` |
| **Result type** | `%{key => result}` | `%{branch => result}` |
| **Use case** | Process list of items | Concurrent independent work |
| **Failure handling** | `failure_threshold` | `failure_mode` |
| **Nesting** | Scatter can contain parallel | Parallel can contain scatter |

**When to use Scatter:**
- Processing N similar items (URLs, records, files)
- N determined at runtime from data
- Same logic, different inputs

**When to use Parallel:**
- Multiple independent workflows
- Different logic per branch
- Fixed structure known at definition

## 6. Telemetry

```elixir
# Parallel execution lifecycle
[:flowstone, :parallel, :start]      # measurements: %{branch_count: N}
[:flowstone, :parallel, :stop]       # measurements: %{duration_ms: _, completed: _, failed: _}
[:flowstone, :parallel, :error]

# Per-branch events
[:flowstone, :parallel, :branch_start]
[:flowstone, :parallel, :branch_complete]
[:flowstone, :parallel, :branch_fail]

# Metadata includes:
# - parent_asset: atom
# - branch_name: atom (for branch events)
# - run_id: uuid
# - execution_id: uuid
```

## 7. Open Questions

1. **Should branches inherit parent's `depends_on`?**
   - Current design: Yes, parent deps are available to all branch assets
   - Alternative: Branches must explicitly declare dependencies

2. **How to handle branch-local state?**
   - Current: Each branch is independent
   - Alternative: Allow cross-branch references (complex)

3. **Async execution coordination:**
   - Current: Join worker polls for completion
   - Alternative: Use database triggers or Oban Pro's `Workflow`

4. **Timeout semantics:**
   - Per-branch timeout vs overall parallel timeout?
   - What happens to running branches when one times out?

5. **Result storage:**
   - Store intermediate branch results? (useful for debugging)
   - Only store final joined result? (simpler)

## 8. Migration from Step Functions

| Step Functions | FlowStone |
|---------------|-----------|
| `Parallel` state | `parallel do ... end` |
| `Branches[]` | `branch :name do ... end` |
| Branch `States` | Assets within branch |
| Result merging | `join fn` |
| `ResultPath` | Join function return |

### Example Conversion

**Step Functions:**
```json
{
  "Type": "Parallel",
  "Branches": [
    {
      "StartAt": "A",
      "States": {
        "A": { "Type": "Task", "Resource": "arn:...", "End": true }
      }
    },
    {
      "StartAt": "B",
      "States": {
        "B": { "Type": "Task", "Resource": "arn:...", "End": true }
      }
    }
  ],
  "Next": "C"
}
```

**FlowStone:**
```elixir
asset :parallel_work do
  parallel do
    branch :a do
      asset :task_a do
        execute fn _, _ -> invoke_lambda_a() end
      end
    end

    branch :b do
      asset :task_b do
        execute fn _, _ -> invoke_lambda_b() end
      end
    end
  end

  join fn %{a: a_result, b: b_result} ->
    %{a: a_result, b: b_result}
  end
end

asset :c do
  depends_on [:parallel_work]
  execute fn _, deps -> process(deps.parallel_work) end
end
```

## 9. Appendix: Full DSL Grammar Extension

```
parallel_block ::=
  parallel do
    branch_definition+
  end
  [parallel_options do ... end]
  join fn

branch_definition ::=
  branch name do
    asset_definition+
  end

parallel_options ::=
  failure_mode (:all_or_nothing | :partial)
  timeout milliseconds

join_fn ::= fn(branch_results) -> term
  where branch_results :: %{branch_name => branch_terminal_result}
```
