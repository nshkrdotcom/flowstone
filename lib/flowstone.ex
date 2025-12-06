defmodule FlowStone do
  @moduledoc """
  Entry point for FlowStone APIs.
  """

  alias FlowStone.Registry
  alias FlowStone.DAG

  @doc """
  Return assets declared in a pipeline module.
  """
  def assets(pipeline_module) do
    pipeline_module.__flowstone_assets__()
  end

  @doc """
  Build a DAG from a pipeline module.
  """
  def dag(pipeline_module) do
    pipeline_module
    |> assets()
    |> DAG.from_assets()
  end

  @doc """
  Register all assets from a pipeline into the registry.
  """
  def register(pipeline_module, opts \\ []) do
    server = Keyword.get(opts, :registry, Registry)
    ensure_registry(server)
    Registry.register_assets(assets(pipeline_module), server: server)
  end

  @doc """
  Materialize a single asset immediately (synchronously).
  """
  def materialize(asset, opts) do
    args = build_args(asset, opts)

    if oban_running?() do
      enqueue_asset(args)
    else
      perform_asset(args)
    end
  end

  @doc """
  Enqueue materialization via Oban if running; otherwise performs synchronously.
  """
  def materialize_async(asset, opts) do
    args = build_args(asset, opts)

    case oban_running?() do
      true -> enqueue_asset(args)
      false -> perform_asset(args)
    end
  end

  @doc """
  Materialize an asset and all its dependencies in topological order.
  """
  def materialize_all(asset, opts) do
    registry = Keyword.get(opts, :registry, Registry)
    io_opts = Keyword.get(opts, :io, [])
    resource_server = Keyword.get(opts, :resource_server, nil)
    partition = Keyword.fetch!(opts, :partition)
    use_repo = Keyword.get(opts, :use_repo, true)
    run_id = Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0)

    assets = Registry.list(server: registry)
    {:ok, graph} = DAG.from_assets(assets)

    subset = dependencies_for(asset, graph)

    if oban_running?() do
      subset
      |> Enum.map(fn name ->
        materialize_async(name,
          partition: partition,
          registry: registry,
          io: io_opts,
          resource_server: resource_server,
          use_repo: use_repo,
          run_id: run_id
        )
      end)
      |> List.last()
    else
      Enum.map(subset, fn name ->
        materialize(name,
          partition: partition,
          registry: registry,
          io: io_opts,
          resource_server: resource_server,
          use_repo: use_repo,
          run_id: run_id
        )
      end)
      |> List.last()
    end
  end

  @doc """
  Backfill an asset across multiple partitions sequentially.
  """
  def backfill(asset, opts) do
    registry = Keyword.get(opts, :registry, Registry)
    io_opts = Keyword.get(opts, :io, [])
    resource_server = Keyword.get(opts, :resource_server, nil)
    lineage_server = Keyword.get(opts, :lineage_server, nil)
    materialization_store = Keyword.get(opts, :materialization_store, nil)
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

    runner = fn partition ->
      target_fun = if oban_running, do: &materialize_async/2, else: &materialize/2

      target_fun.(asset,
        partition: partition,
        registry: registry,
        io: io_opts,
        resource_server: resource_server,
        use_repo: use_repo,
        lineage_server: lineage_server,
        materialization_store: materialization_store,
        run_id: run_id
      )
    end

    results =
      if oban_running do
        partitions_to_run
        |> Task.async_stream(runner, max_concurrency: max_parallel, timeout: timeout)
        |> Enum.map(fn {:ok, res} -> res end)
      else
        Enum.map(partitions_to_run, runner)
      end

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

  defp build_args(asset, opts) do
    partition = Keyword.fetch!(opts, :partition)
    registry = Keyword.get(opts, :registry, Registry)
    io_opts = Keyword.get(opts, :io, [])
    use_repo = Keyword.get(opts, :use_repo, true)
    resource_server = Keyword.get(opts, :resource_server, nil)
    lineage_server = Keyword.get(opts, :lineage_server, nil)
    materialization_store = Keyword.get(opts, :materialization_store, nil)
    run_id = Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0)

    %{
      "asset_name" => Atom.to_string(asset),
      "partition" => partition,
      "registry" => registry,
      "io" => io_opts,
      "resource_server" => resource_server,
      "lineage_server" => lineage_server,
      "materialization_store" => materialization_store,
      "run_id" => run_id,
      "use_repo" => use_repo
    }
  end

  defp enqueue_asset(args) do
    FlowStone.Workers.AssetWorker.new(args) |> Oban.insert()
  end

  defp perform_asset(args) do
    FlowStone.Workers.AssetWorker.perform(%Oban.Job{args: args})
  end
end
