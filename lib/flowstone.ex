defmodule FlowStone do
  @moduledoc """
  Entry point for FlowStone APIs.

  ## High-Level API

  The simplified API requires only a pipeline module and asset name:

      # Run an asset (automatically runs dependencies)
      {:ok, result} = FlowStone.run(MyPipeline, :asset)

      # With partition
      {:ok, result} = FlowStone.run(MyPipeline, :asset, partition: ~D[2025-01-15])

      # Get cached result
      {:ok, result} = FlowStone.get(MyPipeline, :asset)

      # Check existence
      FlowStone.exists?(MyPipeline, :asset)

      # Backfill multiple partitions
      {:ok, stats} = FlowStone.backfill(MyPipeline, :asset, partitions: dates)

      # View pipeline graph
      FlowStone.graph(MyPipeline)

  ## Low-Level API

  For advanced use cases requiring direct control over registries, IO managers,
  and Oban job execution:

      # Manual registration with custom registry
      FlowStone.register(MyPipeline, registry: MyRegistry)

      # Direct materialization with full control
      FlowStone.materialize(:asset, partition: date, registry: reg, io: io_opts)

      # Async materialization via Oban
      FlowStone.materialize_async(:asset, partition: date, ...)

  The low-level API is used internally by FlowStone's scheduler, parallel
  execution, and other subsystems.
  """

  alias FlowStone.{DAG, Partition, Registry, RunConfig}
  alias FlowStone.Workers.AssetWorker

  # ============================================================================
  # High-Level API
  # ============================================================================

  @doc """
  Run an asset and return its result.

  ## Examples

      {:ok, result} = FlowStone.run(MyPipeline, :asset)
      {:ok, result} = FlowStone.run(MyPipeline, :asset, partition: ~D[2025-01-15])
      {:ok, result} = FlowStone.run(MyPipeline, :asset, force: true)

  ## Options

  - `partition` - Partition key (default: `:default`)
  - `force` - Re-run even if cached (default: `false`)
  - `with_deps` - Run missing dependencies first (default: `true`)
  - `async` - Run via Oban job queue (default: `false`)
  """
  defdelegate run(pipeline, asset), to: FlowStone.API
  defdelegate run(pipeline, asset, opts), to: FlowStone.API

  @doc """
  Get the cached result of an asset.

  ## Examples

      {:ok, result} = FlowStone.get(MyPipeline, :asset)
      {:ok, result} = FlowStone.get(MyPipeline, :asset, partition: ~D[2025-01-15])
  """
  defdelegate get(pipeline, asset), to: FlowStone.API
  defdelegate get(pipeline, asset, opts), to: FlowStone.API

  @doc """
  Check if an asset result exists.

  ## Examples

      FlowStone.exists?(MyPipeline, :asset)
      FlowStone.exists?(MyPipeline, :asset, partition: ~D[2025-01-15])
  """
  defdelegate exists?(pipeline, asset), to: FlowStone.API
  defdelegate exists?(pipeline, asset, opts), to: FlowStone.API

  @doc """
  Remove cached results for an asset.

  ## Examples

      {:ok, count} = FlowStone.invalidate(MyPipeline, :asset)
  """
  defdelegate invalidate(pipeline, asset), to: FlowStone.API
  defdelegate invalidate(pipeline, asset, opts), to: FlowStone.API

  @doc """
  Get the status of an asset.

  ## Examples

      status = FlowStone.status(MyPipeline, :asset)
  """
  defdelegate status(pipeline, asset), to: FlowStone.API
  defdelegate status(pipeline, asset, opts), to: FlowStone.API

  @doc """
  Get a visual representation of the pipeline DAG.

  ## Examples

      FlowStone.graph(MyPipeline)
      FlowStone.graph(MyPipeline, format: :mermaid)
  """
  defdelegate graph(pipeline), to: FlowStone.API
  defdelegate graph(pipeline, opts), to: FlowStone.API

  @doc """
  List all assets in a pipeline.

  ## Examples

      FlowStone.assets(MyPipeline)
      # => [:raw, :processed, :output]
  """
  def assets(pipeline_module) when is_atom(pipeline_module) do
    FlowStone.API.assets(pipeline_module)
  end

  @doc """
  Get detailed information about an asset.

  ## Examples

      FlowStone.asset_info(MyPipeline, :processed)
  """
  defdelegate asset_info(pipeline, asset), to: FlowStone.API

  # ============================================================================
  # Low-Level API
  # ============================================================================

  @doc """
  Build a DAG from a pipeline module.
  """
  def dag(pipeline_module) do
    pipeline_module.__flowstone_assets__()
    |> DAG.from_assets()
  end

  @doc """
  Register all assets from a pipeline into the registry.

  Note: Pipelines are now auto-registered when using `FlowStone.run/3`.
  This function is kept for advanced use cases and backward compatibility.
  """
  def register(pipeline_module, opts \\ []) do
    server = Keyword.get(opts, :registry, Registry)
    ensure_registry(server)
    assets_list = pipeline_module.__flowstone_assets__()
    Registry.register_assets(assets_list, server: server)
  end

  @doc """
  Run an asset across multiple partitions.

  ## Examples

      {:ok, stats} = FlowStone.backfill(MyPipeline, :asset,
        partitions: Date.range(~D[2025-01-01], ~D[2025-01-31])
      )

  ## Options

  - `partitions` - (required) Enumerable of partition keys
  - `parallel` - Number of concurrent executions (default: 1)
  - `force` - Re-run even if cached (default: `false`)
  """
  defdelegate backfill(pipeline, asset, opts), to: FlowStone.API

  @doc """
  Materialize a single asset.

  For the simplified API, see `FlowStone.run/3`.

  When Oban is running, this enqueues a job for async execution.
  Otherwise, executes synchronously.

  Returns:
    - `{:ok, %Oban.Job{}}` when job is enqueued
    - `:ok` when executed synchronously and successful
    - `{:error, reason}` on failure
  """
  def materialize(asset, opts) do
    {args, run_config} = build_args(asset, opts)

    if oban_running?() do
      store_run_config(args["run_id"], run_config)
      enqueue_asset(args)
    else
      perform_asset(args, run_config)
    end
  end

  @doc """
  Enqueue materialization via Oban if running; otherwise performs synchronously.

  For the simplified API, see `FlowStone.run/3` with `async: true`.
  """
  def materialize_async(asset, opts) do
    {args, run_config} = build_args(asset, opts)

    case oban_running?() do
      true ->
        store_run_config(args["run_id"], run_config)
        enqueue_asset(args)

      false ->
        perform_asset(args, run_config)
    end
  end

  @doc """
  Materialize an asset and all its dependencies in topological order.

  For the simplified API, see `FlowStone.run/3` which runs dependencies by default.
  """
  def materialize_all(asset, opts) do
    registry = Keyword.get(opts, :registry, Registry)
    io_opts = Keyword.get(opts, :io, [])
    resource_server = Keyword.get(opts, :resource_server)
    lineage_server = Keyword.get(opts, :lineage_server)
    materialization_store = Keyword.get(opts, :materialization_store)
    partition = Keyword.fetch!(opts, :partition)
    use_repo = Keyword.get(opts, :use_repo, true)
    run_id = Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0)

    assets = Registry.list(server: registry)
    {:ok, graph} = DAG.from_assets(assets)

    subset = dependencies_for(asset, graph)

    shared_opts = [
      partition: partition,
      registry: registry,
      io: io_opts,
      resource_server: resource_server,
      lineage_server: lineage_server,
      materialization_store: materialization_store,
      use_repo: use_repo,
      run_id: run_id
    ]

    if oban_running?() do
      subset
      |> Enum.map(fn name -> materialize_async(name, shared_opts) end)
      |> List.last()
    else
      subset
      |> Enum.map(fn name -> materialize(name, shared_opts) end)
      |> List.last()
    end
  end

  @doc """
  Backfill an asset across multiple partitions.

  For the simplified API, see `FlowStone.backfill/3` with a pipeline module.

  Options:
    - `:partitions` - list of partitions to backfill
    - `:force` - re-run even if already materialized (default: false)
    - `:max_parallel` - max concurrent materializations (default: 1)
    - `:timeout` - timeout for parallel execution (default: :infinity)
  """
  def backfill(asset, opts) when is_atom(asset) and is_list(opts) do
    registry = Keyword.get(opts, :registry, Registry)
    io_opts = Keyword.get(opts, :io, [])
    resource_server = Keyword.get(opts, :resource_server)
    lineage_server = Keyword.get(opts, :lineage_server)
    materialization_store = Keyword.get(opts, :materialization_store)
    use_repo = Keyword.get(opts, :use_repo, true)
    force? = Keyword.get(opts, :force, false)
    max_parallel = Keyword.get(opts, :max_parallel, 1)
    timeout = Keyword.get(opts, :timeout, :infinity)
    run_id = Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0)

    {:ok, asset_struct} = Registry.fetch(asset, server: registry)

    backfill_opts =
      case asset_struct.partition_fn do
        fun when is_function(fun) -> Keyword.put_new(opts, :partition_fn, fun)
        _ -> opts
      end

    partitions = FlowStone.Backfill.generate(backfill_opts)

    partitions_to_run =
      Enum.reject(partitions, fn partition ->
        not force? and
          existing_materialization?(asset, partition, materialization_store, use_repo)
      end)

    oban_running = oban_running?()

    shared_opts = [
      registry: registry,
      io: io_opts,
      resource_server: resource_server,
      lineage_server: lineage_server,
      materialization_store: materialization_store,
      use_repo: use_repo,
      run_id: run_id
    ]

    runner = fn partition ->
      target_fun = if oban_running, do: &materialize_async/2, else: &materialize/2
      target_fun.(asset, Keyword.put(shared_opts, :partition, partition))
    end

    results =
      run_backfill_partitions(partitions_to_run, runner, oban_running, max_parallel, timeout)

    skipped = partitions -- partitions_to_run

    {:ok, %{run_id: run_id, partitions: partitions, skipped: skipped, results: results}}
  end

  @doc """
  Register a cron schedule.
  """
  def schedule(asset, opts) do
    schedule = %FlowStone.Schedule{
      asset: asset,
      cron: Keyword.fetch!(opts, :cron),
      registry: Keyword.get(opts, :registry, FlowStone.Registry),
      io: Keyword.get(opts, :io, []),
      resource_server: Keyword.get(opts, :resource_server, FlowStone.Resources),
      lineage_server: Keyword.get(opts, :lineage_server, FlowStone.Lineage),
      use_repo: Keyword.get(opts, :use_repo, true),
      timezone: Keyword.get(opts, :timezone, "UTC"),
      partition_fn: Keyword.get(opts, :partition, fn -> Date.utc_today() end)
    }

    server = Keyword.get(opts, :store, FlowStone.ScheduleStore)
    ensure_schedule_store(server)
    FlowStone.ScheduleStore.put(schedule, server)
    :ok
  end

  def unschedule(asset, opts \\ []) do
    server = Keyword.get(opts, :store, FlowStone.ScheduleStore)
    ensure_schedule_store(server)
    FlowStone.ScheduleStore.delete(asset, server)
    :ok
  end

  def list_schedules(opts \\ []) do
    server = Keyword.get(opts, :store, FlowStone.ScheduleStore)
    ensure_schedule_store(server)
    FlowStone.ScheduleStore.list(server)
  end

  defp ensure_registry(server) when is_atom(server) do
    case Process.whereis(server) do
      nil -> Registry.start_link(name: server)
      _pid -> :ok
    end
  end

  defp ensure_registry(_server), do: :ok

  defp ensure_schedule_store(server) when is_atom(server) do
    case Process.whereis(server) do
      nil -> FlowStone.ScheduleStore.start_link(name: server)
      _ -> :ok
    end
  end

  defp ensure_schedule_store(_server), do: :ok

  defp dependencies_for(asset_name, %{edges: edges}) do
    deps = Map.get(edges, asset_name, [])
    Enum.flat_map(deps, &dependencies_for(&1, %{edges: edges})) ++ [asset_name]
  end

  defp existing_materialization?(asset, partition, store, use_repo) do
    case FlowStone.MaterializationContext.latest(asset, partition,
           store: store,
           use_repo: use_repo
         ) do
      %FlowStone.Materialization{status: :success} -> true
      %{status: :success} -> true
      _ -> false
    end
  end

  defp oban_running?,
    do: Process.whereis(Oban.Registry) != nil and Process.whereis(Oban.Config) != nil

  # Run backfill partitions with appropriate parallelism strategy
  defp run_backfill_partitions(partitions, runner, true = _oban_running, _max_parallel, _timeout) do
    # When Oban is running, enqueue jobs (enqueue is fast, no need for Task.async_stream)
    Enum.map(partitions, runner)
  end

  defp run_backfill_partitions(partitions, runner, false, max_parallel, timeout)
       when max_parallel > 1 do
    # When running synchronously with parallelism, use Task.async_stream
    partitions
    |> Task.async_stream(runner, max_concurrency: max_parallel, timeout: timeout)
    |> Enum.map(fn {:ok, res} -> res end)
  end

  defp run_backfill_partitions(partitions, runner, false, _max_parallel, _timeout) do
    # When running synchronously without parallelism
    Enum.map(partitions, runner)
  end

  # Build JSON-safe args for Oban jobs and a separate run_config for runtime values.
  #
  # Oban persists job args as JSON, so we can only include:
  # - strings, numbers, booleans, lists, maps
  #
  # Runtime values (servers, functions, keywords) are stored in RunConfig
  # and looked up by run_id when the job executes.
  defp build_args(asset, opts) do
    partition = Keyword.fetch!(opts, :partition)
    run_id = Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0)
    use_repo = Keyword.get(opts, :use_repo, true)
    io_opts = Keyword.get(opts, :io, [])

    # JSON-safe args for Oban
    args = %{
      "asset_name" => to_string(asset),
      "partition" => Partition.serialize(partition),
      "run_id" => run_id,
      "use_repo" => use_repo
    }

    # Runtime config stored separately (not JSON-safe)
    # For synchronous execution, we keep the original io_opts
    # For async execution, the io_config is converted to a JSON-safe format
    run_config = [
      registry: Keyword.get(opts, :registry, Registry),
      resource_server: Keyword.get(opts, :resource_server),
      lineage_server: Keyword.get(opts, :lineage_server),
      materialization_store: Keyword.get(opts, :materialization_store),
      io_opts: io_opts,
      io_config: build_io_config(io_opts)
    ]

    {args, run_config}
  end

  # Convert IO options to a serializable config map
  defp build_io_config(io_opts) when is_list(io_opts) do
    config = Keyword.get(io_opts, :config, %{})

    # Extract only JSON-safe values from the config
    json_safe_config =
      config
      |> Enum.filter(fn {_k, v} -> json_safe?(v) end)
      |> Map.new()

    %{
      "manager" => io_manager_name(Keyword.get(io_opts, :manager)),
      "config" => json_safe_config
    }
  end

  defp build_io_config(_), do: %{}

  defp io_manager_name(nil), do: nil
  defp io_manager_name(mod) when is_atom(mod), do: to_string(mod)
  defp io_manager_name(other), do: to_string(other)

  defp json_safe?(v) when is_binary(v), do: true
  defp json_safe?(v) when is_number(v), do: true
  defp json_safe?(v) when is_boolean(v), do: true
  defp json_safe?(v) when is_nil(v), do: true
  defp json_safe?(v) when is_atom(v), do: true
  defp json_safe?(v) when is_list(v), do: Enum.all?(v, &json_safe?/1)

  defp json_safe?(v) when is_map(v),
    do: Enum.all?(v, fn {k, val} -> json_safe?(k) and json_safe?(val) end)

  defp json_safe?(_), do: false

  defp store_run_config(run_id, config) do
    if Process.whereis(RunConfig) do
      RunConfig.put(run_id, config)
    end

    :ok
  end

  defp enqueue_asset(args) do
    AssetWorker.new(args) |> Oban.insert()
  end

  defp perform_asset(args, run_config) do
    AssetWorker.perform(%Oban.Job{args: args}, run_config)
  end
end
