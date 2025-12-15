# FlowStone Pluggable Executors

## Status

Proposed

## Context

FlowStone currently has execution strategy tightly coupled to the `AssetWorker` module, which:

1. Checks if Oban is running
2. Either enqueues an Oban job (distributed) or executes synchronously
3. Has hardcoded snooze/retry logic

This creates several issues:

- **Testing friction**: Tests must either start Oban or rely on fallback behavior
- **Inflexibility**: Cannot easily switch between execution strategies
- **Limited strategies**: Only Oban-distributed or synchronous available
- **Tight coupling**: Worker logic mixed with execution strategy

## Decision

Implement a **Pluggable Executor** pattern that separates execution strategy from asset definition and orchestration. Executors are behaviours that define how assets are scheduled and executed.

## Design

### Executor Behaviour

```elixir
defmodule FlowStone.Executor.Behaviour do
  @moduledoc """
  Behaviour for execution strategies.

  Executors determine HOW assets are executed:
  - Synchronously in the current process
  - Asynchronously via Task
  - Distributed via Oban job queue
  - Custom strategies (rate-limited, prioritized, etc.)
  """

  alias FlowStone.Executor.Job

  @type execution_result :: {:ok, term()} | {:error, term()}
  @type schedule_result :: {:ok, Job.t()} | {:error, term()}

  @doc """
  Execute an asset immediately and return the result.

  Used for synchronous execution or when the caller needs
  to wait for completion.
  """
  @callback execute(Job.t(), keyword()) :: execution_result()

  @doc """
  Schedule an asset for execution without waiting.

  Returns a job reference that can be used to track status.
  For synchronous executors, this executes immediately.
  """
  @callback schedule(Job.t(), keyword()) :: schedule_result()

  @doc """
  Check if a scheduled job has completed.

  Returns the current status and result if available.
  """
  @callback status(Job.t(), keyword()) ::
    {:pending, map()} | {:running, map()} | {:completed, term()} | {:failed, term()}

  @doc """
  Cancel a scheduled job if possible.

  Returns `:ok` if cancelled, `{:error, reason}` if not cancellable.
  """
  @callback cancel(Job.t(), keyword()) :: :ok | {:error, term()}

  @doc """
  Returns executor capabilities for introspection.
  """
  @callback capabilities() :: [atom()]

  @optional_callbacks [status: 2, cancel: 2, capabilities: 0]
end
```

### Job Struct

```elixir
defmodule FlowStone.Executor.Job do
  @moduledoc """
  Represents an execution job for an asset.

  This struct contains all information needed to execute an asset,
  independent of the execution strategy used.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          asset_name: atom(),
          partition: term(),
          run_id: String.t(),
          io_opts: keyword(),
          hooks: [module()],
          hooks_config: map(),
          use_repo: boolean(),
          resource_server: atom(),
          lineage_server: atom(),
          materialization_store: atom(),
          priority: integer(),
          scheduled_at: DateTime.t(),
          metadata: map()
        }

  defstruct [
    :id,
    :asset_name,
    :partition,
    :run_id,
    :io_opts,
    :hooks,
    :hooks_config,
    :use_repo,
    :resource_server,
    :lineage_server,
    :materialization_store,
    :scheduled_at,
    priority: 0,
    metadata: %{}
  ]

  @doc """
  Build a job from materialization options.
  """
  @spec build(atom(), keyword()) :: t()
  def build(asset_name, opts) do
    %__MODULE__{
      id: Keyword.get_lazy(opts, :job_id, fn -> Ecto.UUID.generate() end),
      asset_name: asset_name,
      partition: Keyword.fetch!(opts, :partition),
      run_id: Keyword.get_lazy(opts, :run_id, fn -> Ecto.UUID.generate() end),
      io_opts: Keyword.get(opts, :io, []),
      hooks: Keyword.get(opts, :hooks),
      hooks_config: Keyword.get(opts, :hooks_config, %{}),
      use_repo: Keyword.get(opts, :use_repo, true),
      resource_server: get_server(opts, :resource_server, :resources_server, FlowStone.Resources),
      lineage_server: get_server(opts, :lineage_server, :lineage_server, FlowStone.Lineage),
      materialization_store: get_server(opts, :materialization_store, :materialization_store, FlowStone.MaterializationStore),
      priority: Keyword.get(opts, :priority, 0),
      scheduled_at: DateTime.utc_now(),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp get_server(opts, key, env_key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when not is_nil(value) -> value
      _ -> Application.get_env(:flowstone, env_key, default)
    end
  end

  @doc """
  Convert job to JSON-safe map for Oban args.
  """
  @spec to_json_args(t()) :: map()
  def to_json_args(%__MODULE__{} = job) do
    %{
      "id" => job.id,
      "asset_name" => Atom.to_string(job.asset_name),
      "partition" => FlowStone.Partition.serialize(job.partition),
      "run_id" => job.run_id,
      "priority" => job.priority
    }
  end

  @doc """
  Restore job from JSON args (requires RunConfig lookup for non-JSON fields).
  """
  @spec from_json_args(map(), map()) :: t()
  def from_json_args(args, run_config) do
    %__MODULE__{
      id: args["id"],
      asset_name: String.to_existing_atom(args["asset_name"]),
      partition: FlowStone.Partition.deserialize(args["partition"]),
      run_id: args["run_id"],
      priority: args["priority"] || 0,
      io_opts: Map.get(run_config, :io_opts, []),
      hooks: Map.get(run_config, :hooks),
      hooks_config: Map.get(run_config, :hooks_config, %{}),
      use_repo: Map.get(run_config, :use_repo, true),
      resource_server: Map.get(run_config, :resource_server, FlowStone.Resources),
      lineage_server: Map.get(run_config, :lineage_server, FlowStone.Lineage),
      materialization_store: Map.get(run_config, :materialization_store, FlowStone.MaterializationStore),
      scheduled_at: DateTime.utc_now()
    }
  end
end
```

### Executor Implementations

#### Synchronous Executor

```elixir
defmodule FlowStone.Executor.Sync do
  @moduledoc """
  Synchronous executor that runs assets in the current process.

  Best for:
  - Testing
  - Debugging
  - Simple scripts
  - When you need the result immediately

  ## Options

  - `:timeout` - Maximum execution time in milliseconds (default: 30_000)
  """

  @behaviour FlowStone.Executor.Behaviour

  alias FlowStone.Executor.Job
  alias FlowStone.Hook.Pipeline
  alias FlowStone.Hooks

  @default_timeout 30_000

  @impl true
  def execute(%Job{} = job, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    task = Task.async(fn -> do_execute(job) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :execution_timeout}
    end
  end

  @impl true
  def schedule(%Job{} = job, opts \\ []) do
    # Synchronous executor runs immediately
    case execute(job, opts) do
      {:ok, _result} -> {:ok, %{job | metadata: Map.put(job.metadata, :status, :completed)}}
      {:error, _} = err -> err
    end
  end

  @impl true
  def status(%Job{} = job, _opts) do
    # Sync jobs are always completed or failed immediately
    case Map.get(job.metadata, :status) do
      :completed -> {:completed, Map.get(job.metadata, :result)}
      :failed -> {:failed, Map.get(job.metadata, :error)}
      _ -> {:completed, nil}
    end
  end

  @impl true
  def cancel(_job, _opts) do
    {:error, :not_cancellable}
  end

  @impl true
  def capabilities do
    [:sync, :immediate, :blocking]
  end

  defp do_execute(%Job{} = job) do
    hooks = job.hooks || Hooks.default()

    with {:ok, ctx} <- build_context(job) do
      Pipeline.run(hooks, ctx)
    end
  end

  defp build_context(job) do
    alias FlowStone.{Registry, Error}
    alias FlowStone.Hook.Context

    with {:ok, asset} <- Registry.fetch(job.asset_name),
         {:ok, deps} <- load_dependencies(asset, job) do
      {:ok, %Context{
        asset: asset,
        partition: job.partition,
        run_id: job.run_id,
        dependencies: deps,
        io_opts: job.io_opts,
        use_repo: job.use_repo,
        resource_server: job.resource_server,
        lineage_server: job.lineage_server,
        materialization_store: job.materialization_store,
        started_at: System.monotonic_time(:millisecond),
        hooks_config: job.hooks_config
      }}
    end
  end

  defp load_dependencies(asset, job) do
    deps = Map.get(asset, :depends_on, [])

    results =
      Enum.reduce_while(deps, %{}, fn dep, acc ->
        case FlowStone.IO.load(dep, job.partition, job.io_opts) do
          {:ok, data} -> {:cont, Map.put(acc, dep, data)}
          {:error, _} -> {:halt, {:missing, dep}}
        end
      end)

    case results do
      {:missing, dep} -> {:error, FlowStone.Error.dependency_not_ready(asset.name, [dep])}
      map when is_map(map) -> {:ok, map}
    end
  end
end
```

#### Task Async Executor

```elixir
defmodule FlowStone.Executor.TaskAsync do
  @moduledoc """
  Asynchronous executor using Elixir Tasks.

  Runs assets in separate processes but within the same node.
  Does not persist jobs - if the node crashes, pending jobs are lost.

  Best for:
  - Development
  - Parallelizing local work
  - When persistence isn't needed

  ## Options

  - `:max_concurrency` - Maximum concurrent tasks (default: System.schedulers_online())
  - `:timeout` - Per-task timeout in milliseconds (default: 60_000)
  - `:supervisor` - Task.Supervisor to use (default: starts inline)
  """

  @behaviour FlowStone.Executor.Behaviour

  alias FlowStone.Executor.{Job, Sync}

  @default_timeout 60_000

  # ETS table for tracking running tasks
  @task_table __MODULE__.Tasks

  @impl true
  def execute(%Job{} = job, opts \\ []) do
    # For single execution, delegate to sync executor in a task
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    supervisor = Keyword.get(opts, :supervisor)

    task =
      if supervisor do
        Task.Supervisor.async_nolink(supervisor, fn -> Sync.execute(job, opts) end)
      else
        Task.async(fn -> Sync.execute(job, opts) end)
      end

    track_task(job.id, task)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        untrack_task(job.id)
        result

      nil ->
        untrack_task(job.id)
        {:error, :execution_timeout}
    end
  end

  @impl true
  def schedule(%Job{} = job, opts \\ []) do
    supervisor = Keyword.get(opts, :supervisor)

    task =
      if supervisor do
        Task.Supervisor.async_nolink(supervisor, fn -> Sync.execute(job, opts) end)
      else
        Task.async(fn -> Sync.execute(job, opts) end)
      end

    track_task(job.id, task)
    {:ok, %{job | metadata: Map.put(job.metadata, :task_ref, task.ref)}}
  end

  @impl true
  def status(%Job{} = job, _opts) do
    case get_task(job.id) do
      nil ->
        {:completed, nil}

      task ->
        case Task.yield(task, 0) do
          nil -> {:running, %{task_ref: task.ref}}
          {:ok, {:ok, result}} -> {:completed, result}
          {:ok, {:error, reason}} -> {:failed, reason}
          {:exit, reason} -> {:failed, {:exit, reason}}
        end
    end
  end

  @impl true
  def cancel(%Job{} = job, _opts) do
    case get_task(job.id) do
      nil ->
        {:error, :not_found}

      task ->
        Task.shutdown(task, :brutal_kill)
        untrack_task(job.id)
        :ok
    end
  end

  @impl true
  def capabilities do
    [:async, :parallel, :local_only, :non_persistent]
  end

  # Task tracking helpers (uses process dictionary for simplicity)
  # Production would use ETS or Registry

  defp track_task(job_id, task) do
    Process.put({:flowstone_task, job_id}, task)
  end

  defp get_task(job_id) do
    Process.get({:flowstone_task, job_id})
  end

  defp untrack_task(job_id) do
    Process.delete({:flowstone_task, job_id})
  end
end
```

#### Oban Executor

```elixir
defmodule FlowStone.Executor.Oban do
  @moduledoc """
  Distributed executor using Oban job queue.

  Provides persistent, distributed execution with:
  - Job persistence across restarts
  - Automatic retries with backoff
  - Multi-node distribution
  - Priority queues
  - Unique job constraints

  Best for:
  - Production workloads
  - Distributed systems
  - When jobs must survive restarts
  - Rate-limited execution

  ## Options

  - `:queue` - Oban queue name (default: :assets)
  - `:max_attempts` - Maximum retry attempts (default: 3)
  - `:priority` - Job priority 0-3 (default: from job.priority)
  - `:scheduled_at` - Schedule for future execution
  - `:unique` - Unique constraint options
  """

  @behaviour FlowStone.Executor.Behaviour

  alias FlowStone.Executor.Job
  alias FlowStone.RunConfig

  @default_queue :assets
  @default_max_attempts 3

  @impl true
  def execute(%Job{} = job, opts \\ []) do
    # For immediate execution, check if Oban is available
    if oban_running?() do
      # Enqueue and wait for result
      case schedule(job, opts) do
        {:ok, oban_job} ->
          wait_for_completion(oban_job, opts)

        error ->
          error
      end
    else
      # Fallback to sync execution
      FlowStone.Executor.Sync.execute(job, opts)
    end
  end

  @impl true
  def schedule(%Job{} = job, opts \\ []) do
    if oban_running?() do
      queue = Keyword.get(opts, :queue, @default_queue)
      max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)
      priority = Keyword.get(opts, :priority, job.priority)
      scheduled_at = Keyword.get(opts, :scheduled_at)
      unique = Keyword.get(opts, :unique)

      # Store non-JSON-safe data in RunConfig
      :ok = RunConfig.put(job.run_id, build_run_config(job))

      # Build Oban job with JSON-safe args
      worker_opts =
        [
          queue: queue,
          max_attempts: max_attempts,
          priority: priority
        ]
        |> maybe_add(:scheduled_at, scheduled_at)
        |> maybe_add(:unique, unique)

      case Oban.insert(FlowStone.Workers.AssetWorker.new(Job.to_json_args(job), worker_opts)) do
        {:ok, oban_job} ->
          {:ok, %{job | metadata: Map.put(job.metadata, :oban_job_id, oban_job.id)}}

        {:error, reason} ->
          {:error, {:oban_insert_failed, reason}}
      end
    else
      {:error, :oban_not_running}
    end
  end

  @impl true
  def status(%Job{} = job, _opts) do
    oban_job_id = Map.get(job.metadata, :oban_job_id)

    if oban_job_id do
      case Oban.Job |> Oban.Repo.get(oban_job_id) do
        nil ->
          {:completed, nil}

        %{state: "completed"} ->
          {:completed, nil}

        %{state: "available"} ->
          {:pending, %{}}

        %{state: "executing"} ->
          {:running, %{}}

        %{state: "scheduled", scheduled_at: scheduled_at} ->
          {:pending, %{scheduled_at: scheduled_at}}

        %{state: "retryable", errors: errors} ->
          {:pending, %{retry_count: length(errors)}}

        %{state: "discarded", errors: errors} ->
          {:failed, List.last(errors)}

        %{state: "cancelled"} ->
          {:failed, :cancelled}
      end
    else
      {:completed, nil}
    end
  end

  @impl true
  def cancel(%Job{} = job, _opts) do
    oban_job_id = Map.get(job.metadata, :oban_job_id)

    if oban_job_id do
      case Oban.cancel_job(oban_job_id) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :no_oban_job}
    end
  end

  @impl true
  def capabilities do
    [:async, :distributed, :persistent, :retryable, :schedulable, :prioritized]
  end

  # Private helpers

  defp oban_running? do
    case Process.whereis(Oban) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp build_run_config(job) do
    %{
      io_opts: job.io_opts,
      hooks: job.hooks,
      hooks_config: job.hooks_config,
      use_repo: job.use_repo,
      resource_server: job.resource_server,
      lineage_server: job.lineage_server,
      materialization_store: job.materialization_store
    }
  end

  defp wait_for_completion(_oban_job, _opts) do
    # For now, Oban jobs don't block - return immediately
    # Future: implement pub/sub or polling for result
    {:ok, :scheduled}
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end
```

#### Serial Executor (for Debugging)

```elixir
defmodule FlowStone.Executor.Serial do
  @moduledoc """
  Serial executor that runs assets one at a time with verbose logging.

  Best for:
  - Debugging execution order
  - Understanding data flow
  - Step-by-step verification

  ## Options

  - `:verbose` - Enable detailed logging (default: true)
  - `:pause_between` - Milliseconds to pause between steps (default: 0)
  - `:on_step` - Callback function called before each step
  """

  @behaviour FlowStone.Executor.Behaviour

  alias FlowStone.Executor.{Job, Sync}
  require Logger

  @impl true
  def execute(%Job{} = job, opts \\ []) do
    verbose = Keyword.get(opts, :verbose, true)
    pause = Keyword.get(opts, :pause_between, 0)
    on_step = Keyword.get(opts, :on_step)

    if verbose do
      Logger.debug("[FlowStone.Serial] Starting: #{job.asset_name}")
      Logger.debug("[FlowStone.Serial] Partition: #{inspect(job.partition)}")
      Logger.debug("[FlowStone.Serial] Run ID: #{job.run_id}")
    end

    if on_step, do: on_step.(:before, job)

    if pause > 0 do
      if verbose, do: Logger.debug("[FlowStone.Serial] Pausing #{pause}ms...")
      Process.sleep(pause)
    end

    start = System.monotonic_time(:millisecond)
    result = Sync.execute(job, opts)
    duration = System.monotonic_time(:millisecond) - start

    if verbose do
      case result do
        {:ok, _} ->
          Logger.debug("[FlowStone.Serial] Completed: #{job.asset_name} (#{duration}ms)")

        {:error, reason} ->
          Logger.error("[FlowStone.Serial] Failed: #{job.asset_name} - #{inspect(reason)}")
      end
    end

    if on_step, do: on_step.(:after, job, result)

    result
  end

  @impl true
  def schedule(%Job{} = job, opts \\ []) do
    case execute(job, opts) do
      {:ok, _} -> {:ok, job}
      error -> error
    end
  end

  @impl true
  def capabilities do
    [:sync, :debugging, :verbose, :single_threaded]
  end
end
```

### Executor Selection

```elixir
defmodule FlowStone.Executor.Selector do
  @moduledoc """
  Selects appropriate executor based on context and configuration.
  """

  alias FlowStone.Executor.{Oban, TaskAsync, Sync, Serial}

  @type strategy :: :auto | :sync | :async | :oban | :serial | module()

  @doc """
  Select executor based on strategy option.

  ## Strategies

  - `:auto` - Oban if available, otherwise Sync (default)
  - `:sync` - Always synchronous
  - `:async` - Task-based async
  - `:oban` - Always Oban (fails if unavailable)
  - `:serial` - Serial with logging
  - `module` - Custom executor module
  """
  @spec select(strategy()) :: module()
  def select(:auto) do
    if oban_available?(), do: Oban, else: Sync
  end

  def select(:sync), do: Sync
  def select(:async), do: TaskAsync
  def select(:oban), do: Oban
  def select(:serial), do: Serial
  def select(module) when is_atom(module), do: module

  @doc """
  Select executor for testing (never uses Oban).
  """
  @spec for_testing() :: module()
  def for_testing, do: Sync

  @doc """
  Select executor for production (prefers Oban).
  """
  @spec for_production() :: module()
  def for_production do
    if oban_available?(), do: Oban, else: TaskAsync
  end

  defp oban_available? do
    match?({:ok, _}, Application.fetch_env(:flowstone, Oban)) and
      Process.whereis(Oban) != nil
  end
end
```

### Integration with Main API

```elixir
defmodule FlowStone do
  @moduledoc """
  Main API with executor support.
  """

  alias FlowStone.Executor.{Job, Selector}

  @doc """
  Materialize an asset with configurable execution strategy.

  ## Options

  - `:partition` - Required partition value
  - `:executor` - Execution strategy (default: :auto)
    - `:auto` - Oban if available, otherwise sync
    - `:sync` - Synchronous execution
    - `:async` - Task-based parallel
    - `:oban` - Oban job queue
    - `:serial` - Serial with logging
    - `module` - Custom executor
  - `:executor_opts` - Options passed to executor

  ## Examples

      # Default (auto-selects based on environment)
      FlowStone.materialize(:my_asset, partition: ~D[2024-01-01])

      # Force synchronous
      FlowStone.materialize(:my_asset, partition: ~D[2024-01-01], executor: :sync)

      # Oban with custom queue
      FlowStone.materialize(:my_asset,
        partition: ~D[2024-01-01],
        executor: :oban,
        executor_opts: [queue: :high_priority, max_attempts: 5]
      )

      # Debug with serial executor
      FlowStone.materialize(:my_asset,
        partition: ~D[2024-01-01],
        executor: :serial,
        executor_opts: [verbose: true, pause_between: 1000]
      )
  """
  @spec materialize(atom(), keyword()) :: {:ok, term()} | {:error, term()}
  def materialize(asset_name, opts) do
    strategy = Keyword.get(opts, :executor, :auto)
    executor_opts = Keyword.get(opts, :executor_opts, [])

    executor = Selector.select(strategy)
    job = Job.build(asset_name, opts)

    executor.execute(job, executor_opts)
  end

  @doc """
  Schedule an asset for execution without waiting.

  Returns a job that can be used to check status or cancel.
  """
  @spec schedule(atom(), keyword()) :: {:ok, Job.t()} | {:error, term()}
  def schedule(asset_name, opts) do
    strategy = Keyword.get(opts, :executor, :auto)
    executor_opts = Keyword.get(opts, :executor_opts, [])

    executor = Selector.select(strategy)
    job = Job.build(asset_name, opts)

    executor.schedule(job, executor_opts)
  end

  @doc """
  Check the status of a scheduled job.
  """
  @spec job_status(Job.t(), keyword()) ::
    {:pending, map()} | {:running, map()} | {:completed, term()} | {:failed, term()}
  def job_status(%Job{} = job, opts \\ []) do
    strategy = Keyword.get(opts, :executor, :auto)
    executor = Selector.select(strategy)

    if function_exported?(executor, :status, 2) do
      executor.status(job, opts)
    else
      {:error, :status_not_supported}
    end
  end

  @doc """
  Cancel a scheduled job.
  """
  @spec cancel_job(Job.t(), keyword()) :: :ok | {:error, term()}
  def cancel_job(%Job{} = job, opts \\ []) do
    strategy = Keyword.get(opts, :executor, :auto)
    executor = Selector.select(strategy)

    if function_exported?(executor, :cancel, 2) do
      executor.cancel(job, opts)
    else
      {:error, :cancel_not_supported}
    end
  end
end
```

### Backfill with Executor Support

```elixir
defmodule FlowStone.Backfill do
  @moduledoc """
  Backfill operations with executor support.
  """

  alias FlowStone.Executor.{Job, Selector}

  @doc """
  Backfill an asset across multiple partitions.

  ## Options

  - `:partitions` - List of partitions to materialize
  - `:executor` - Execution strategy
  - `:max_concurrency` - Max parallel executions (for async/oban)
  - `:on_progress` - Callback for progress updates

  ## Examples

      FlowStone.backfill(:daily_report,
        partitions: Date.range(~D[2024-01-01], ~D[2024-01-31]),
        executor: :oban,
        executor_opts: [queue: :backfill, max_attempts: 2]
      )
  """
  @spec run(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(asset_name, opts) do
    partitions = Keyword.fetch!(opts, :partitions) |> Enum.to_list()
    strategy = Keyword.get(opts, :executor, :auto)
    executor_opts = Keyword.get(opts, :executor_opts, [])
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())
    on_progress = Keyword.get(opts, :on_progress, fn _, _ -> :ok end)

    executor = Selector.select(strategy)

    results =
      partitions
      |> Task.async_stream(
        fn partition ->
          job = Job.build(asset_name, Keyword.put(opts, :partition, partition))
          result = executor.execute(job, executor_opts)
          on_progress.(partition, result)
          {partition, result}
        end,
        max_concurrency: max_concurrency,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    {successes, failures} =
      Enum.split_with(results, fn {_, result} -> match?({:ok, _}, result) end)

    {:ok, %{
      total: length(partitions),
      succeeded: length(successes),
      failed: length(failures),
      results: Map.new(results)
    }}
  end
end
```

## Usage Examples

### Basic Execution

```elixir
# Auto-select executor (Oban in prod, Sync in test)
FlowStone.materialize(:extract_data, partition: ~D[2024-01-01])

# Force synchronous for debugging
FlowStone.materialize(:extract_data,
  partition: ~D[2024-01-01],
  executor: :sync
)

# Use Oban with custom options
FlowStone.materialize(:extract_data,
  partition: ~D[2024-01-01],
  executor: :oban,
  executor_opts: [
    queue: :high_priority,
    max_attempts: 5,
    priority: 0
  ]
)
```

### Debugging with Serial Executor

```elixir
FlowStone.materialize(:transform_data,
  partition: ~D[2024-01-01],
  executor: :serial,
  executor_opts: [
    verbose: true,
    pause_between: 500,
    on_step: fn phase, job ->
      IO.puts("#{phase}: #{job.asset_name}")
    end
  ]
)
```

### Schedule for Later

```elixir
{:ok, job} = FlowStone.schedule(:nightly_report,
  partition: ~D[2024-01-01],
  executor: :oban,
  executor_opts: [scheduled_at: ~U[2024-01-02 02:00:00Z]]
)

# Check status later
FlowStone.job_status(job)
# => {:pending, %{scheduled_at: ~U[2024-01-02 02:00:00Z]}}

# Cancel if needed
FlowStone.cancel_job(job)
```

### Custom Executor

```elixir
defmodule MyApp.RateLimitedExecutor do
  @behaviour FlowStone.Executor.Behaviour

  alias FlowStone.Executor.{Job, Sync}

  @impl true
  def execute(%Job{} = job, opts) do
    bucket = "asset:#{job.asset_name}"

    case Hammer.check_rate(bucket, 60_000, 10) do
      {:allow, _} -> Sync.execute(job, opts)
      {:deny, _} -> {:error, :rate_limited}
    end
  end

  @impl true
  def schedule(job, opts), do: execute(job, opts)

  @impl true
  def capabilities, do: [:sync, :rate_limited]
end

# Use custom executor
FlowStone.materialize(:api_fetch,
  partition: ~D[2024-01-01],
  executor: MyApp.RateLimitedExecutor
)
```

## Migration Path

1. **Phase 1**: Implement `FlowStone.Executor.Behaviour` and `Job` struct
2. **Phase 2**: Implement `Sync` executor (simplest)
3. **Phase 3**: Implement `Oban` executor (wrap existing `AssetWorker`)
4. **Phase 4**: Implement `TaskAsync` and `Serial` executors
5. **Phase 5**: Add `Selector` and integrate with main API
6. **Phase 6**: Update `Backfill` to use executors
7. **Phase 7**: Deprecate direct `AssetWorker` usage

## File Structure

```
lib/flowstone/
├── executor/
│   ├── behaviour.ex         # Executor behaviour
│   ├── job.ex               # Job struct
│   ├── selector.ex          # Strategy selection
│   ├── sync.ex              # Synchronous executor
│   ├── task_async.ex        # Task-based async
│   ├── oban.ex              # Oban distributed
│   └── serial.ex            # Debug serial
└── backfill.ex              # Updated with executor support
```

## Consequences

### Positive

- **Flexibility**: Easy to switch execution strategies
- **Testability**: Use Sync executor in tests, no Oban needed
- **Debuggability**: Serial executor for step-by-step verification
- **Extensibility**: Custom executors for rate limiting, circuit breaking, etc.
- **Separation**: Execution strategy decoupled from asset definition

### Negative

- **Indirection**: Additional abstraction layer
- **Complexity**: More modules to maintain
- **Migration**: Existing code using `AssetWorker` directly needs updates

### Neutral

- **API Change**: New `:executor` option, backward compatible with defaults
