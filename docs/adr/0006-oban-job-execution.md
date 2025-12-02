# ADR-0006: Oban-Based Job Execution

## Status
Accepted

## Context

Asset materialization needs reliable, distributed execution with:
- At-least-once delivery
- Automatic retries with backoff
- Scheduled execution (cron)
- Prioritization and rate limiting
- Observability (telemetry, logging)

We need a job execution layer that integrates with BEAM's fault tolerance model.

## Decision

### 1. Use Oban for All Materialization Jobs

**Oban** (~> 2.18) provides:
- PostgreSQL-backed job queue (same DB as metadata)
- Automatic retries with configurable backoff
- Cron scheduling via Oban Pro/plugins
- Telemetry events for observability
- Unique jobs to prevent duplicate execution

### 2. Asset Worker Implementation

```elixir
defmodule FlowStone.Workers.AssetWorker do
  use Oban.Worker,
    queue: :assets,
    max_attempts: 3,
    priority: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{
      "asset_name" => asset_name,
      "partition" => partition,
      "run_id" => run_id,
      "force" => force
    } = args

    asset = String.to_existing_atom(asset_name)
    partition = deserialize_partition(partition)

    with :ok <- check_dependencies_ready(asset, partition),
         {:ok, deps} <- load_dependencies(asset, partition),
         {:ok, context} <- build_context(asset, partition, run_id),
         {:ok, result} <- execute_asset(asset, context, deps),
         :ok <- store_result(asset, partition, result, context) do
      record_success(asset, partition, context)
      :ok
    else
      {:error, :dependencies_not_ready} ->
        # Snooze and retry later
        {:snooze, 30}

      {:error, reason} = error ->
        record_failure(asset, partition, run_id, reason)
        error
    end
  end

  defp check_dependencies_ready(asset, partition) do
    deps = FlowStone.Asset.dependencies(asset)

    missing =
      Enum.filter(deps, fn dep ->
        not FlowStone.Materialization.exists?(dep, partition)
      end)

    case missing do
      [] -> :ok
      _ -> {:error, :dependencies_not_ready}
    end
  end

  defp load_dependencies(asset, partition) do
    deps = FlowStone.Asset.dependencies(asset)

    results =
      Enum.reduce_while(deps, {:ok, %{}}, fn dep, {:ok, acc} ->
        case FlowStone.IO.load(dep, partition) do
          {:ok, data} -> {:cont, {:ok, Map.put(acc, dep, data)}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    results
  end

  defp build_context(asset, partition, run_id) do
    {:ok, %FlowStone.Context{
      asset: asset,
      partition: partition,
      run_id: run_id,
      resources: FlowStone.Resources.load(),
      started_at: DateTime.utc_now()
    }}
  end

  defp execute_asset(asset, context, deps) do
    execute_fn = FlowStone.Asset.execute_fn(asset)

    try do
      case execute_fn.(context, deps) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_return, other}}
      end
    rescue
      exception ->
        {:error, {:exception, Exception.format(:error, exception, __STACKTRACE__)}}
    end
  end
end
```

### 3. Queue Configuration

```elixir
# config/config.exs
config :flowstone, Oban,
  repo: FlowStone.Repo,
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron, crontab: []}
  ],
  queues: [
    assets: 10,           # Standard asset materialization
    priority: 5,          # High-priority assets
    backfill: 20,         # Parallel backfill processing
    checkpoints: 2,       # Checkpoint timeout handling
    sensors: 3            # Sensor polling
  ]
```

### 4. Materialization API

```elixir
defmodule FlowStone do
  @doc "Materialize a single asset"
  def materialize(asset, opts \\ []) do
    partition = Keyword.fetch!(opts, :partition)
    force = Keyword.get(opts, :force, false)
    wait = Keyword.get(opts, :wait, false)

    run_id = Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0)

    job_args = %{
      asset_name: Atom.to_string(asset),
      partition: serialize_partition(partition),
      run_id: run_id,
      force: force
    }

    job = FlowStone.Workers.AssetWorker.new(job_args)

    case Oban.insert(job) do
      {:ok, %Oban.Job{id: job_id}} when wait ->
        wait_for_completion(job_id)

      {:ok, %Oban.Job{}} ->
        {:ok, %{run_id: run_id, status: :queued}}

      {:error, _} = error ->
        error
    end
  end

  @doc "Materialize asset with all dependencies"
  def materialize_all(asset, opts \\ []) do
    partition = Keyword.fetch!(opts, :partition)
    run_id = Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0)

    # Build execution plan from DAG
    execution_order = FlowStone.DAG.execution_order(asset)

    # Queue all assets in order
    jobs =
      Enum.map(execution_order, fn dep_asset ->
        %{
          asset_name: Atom.to_string(dep_asset),
          partition: serialize_partition(partition),
          run_id: run_id,
          force: false
        }
        |> FlowStone.Workers.AssetWorker.new()
      end)

    Oban.insert_all(jobs)
    {:ok, %{run_id: run_id, assets: execution_order, status: :queued}}
  end

  @doc "Backfill historical partitions"
  def backfill(asset, opts \\ []) do
    partitions = Keyword.fetch!(opts, :partitions)
    max_parallel = Keyword.get(opts, :max_parallel, 10)
    run_id = Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0)

    # Queue all partitions with priority limiting
    jobs =
      partitions
      |> Enum.map(fn partition ->
        %{
          asset_name: Atom.to_string(asset),
          partition: serialize_partition(partition),
          run_id: run_id,
          force: true
        }
        |> FlowStone.Workers.AssetWorker.new(queue: :backfill)
      end)

    # Insert in batches to respect max_parallel
    jobs
    |> Enum.chunk_every(max_parallel)
    |> Enum.each(&Oban.insert_all/1)

    {:ok, %{run_id: run_id, partitions: length(partitions), status: :queued}}
  end
end
```

### 5. Retry Strategy

```elixir
defmodule FlowStone.Workers.AssetWorker do
  use Oban.Worker,
    max_attempts: 3

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # Exponential backoff: 10s, 30s, 90s
    trunc(:math.pow(3, attempt) * 10)
  end
end
```

### 6. Unique Jobs

Prevent duplicate materialization of the same asset/partition:

```elixir
FlowStone.Workers.AssetWorker.new(job_args,
  unique: [
    period: 60,  # 60 second uniqueness window
    keys: [:asset_name, :partition]
  ]
)
```

### 7. Snoozing for Dependencies

When dependencies aren't ready, snooze instead of fail:

```elixir
def perform(%Oban.Job{attempt: attempt} = job) do
  case check_dependencies_ready(asset, partition) do
    :ok ->
      execute(...)

    {:error, :dependencies_not_ready} when attempt < 10 ->
      # Snooze for 30 seconds, check again
      {:snooze, 30}

    {:error, :dependencies_not_ready} ->
      # Too many retries, fail
      {:error, "Dependencies not ready after #{attempt} attempts"}
  end
end
```

## Consequences

### Positive

1. **Reliable Execution**: PostgreSQL-backed with transactional guarantees.
2. **Automatic Retries**: Configurable retry with exponential backoff.
3. **Observability**: Built-in telemetry and job introspection.
4. **Distributed**: Works across multiple nodes in a cluster.
5. **Prioritization**: Queue-based priority for different asset types.

### Negative

1. **PostgreSQL Dependency**: Requires PostgreSQL (not SQLite/MySQL).
2. **Oban Pro for Cron**: Some features require paid Oban Pro.
3. **Job Table Growth**: Need to prune old jobs periodically.

### Anti-Patterns Avoided

| pipeline_ex Problem | FlowStone Solution |
|---------------------|-------------------|
| Synchronous execution | Async Oban jobs |
| No retry handling | Automatic retries with backoff |
| No distributed execution | Oban cluster support |
| Manual checkpoint files | PostgreSQL job state |

## References

- Oban: https://hexdocs.pm/oban
- Oban Pro: https://oban.pro
