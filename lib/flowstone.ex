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
    partition = Keyword.fetch!(opts, :partition)
    registry = Keyword.get(opts, :registry, Registry)
    io_opts = Keyword.get(opts, :io, [])
    resource_server = Keyword.get(opts, :resource_server, nil)
    run_id = Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0)

    job = %Oban.Job{
      args: %{
        "asset_name" => Atom.to_string(asset),
        "partition" => partition,
        "registry" => registry,
        "io" => io_opts,
        "resource_server" => resource_server,
        "run_id" => run_id
      }
    }

    FlowStone.Workers.AssetWorker.perform(job)
  end

  @doc """
  Materialize an asset and all its dependencies in topological order.
  """
  def materialize_all(asset, opts) do
    registry = Keyword.get(opts, :registry, Registry)
    io_opts = Keyword.get(opts, :io, [])
    resource_server = Keyword.get(opts, :resource_server, nil)
    partition = Keyword.fetch!(opts, :partition)
    run_id = Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0)

    assets = Registry.list(server: registry)
    {:ok, graph} = DAG.from_assets(assets)

    subset = dependencies_for(asset, graph)

    Enum.map(subset, fn name ->
      materialize(name,
        partition: partition,
        registry: registry,
        io: io_opts,
        resource_server: resource_server,
        run_id: run_id
      )
    end)
    |> List.last()
  end

  @doc """
  Backfill an asset across multiple partitions sequentially.
  """
  def backfill(asset, opts) do
    partitions = Keyword.fetch!(opts, :partitions)
    io_opts = Keyword.get(opts, :io, [])
    registry = Keyword.get(opts, :registry, Registry)
    resource_server = Keyword.get(opts, :resource_server, nil)
    run_id = Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0)

    results =
      Enum.map(partitions, fn partition ->
        materialize(asset,
          partition: partition,
          registry: registry,
          io: io_opts,
          resource_server: resource_server,
          run_id: run_id
        )
      end)

    {:ok, %{run_id: run_id, partitions: partitions, results: results}}
  end

  @doc """
  Register a cron schedule.
  """
  def schedule(asset, opts) do
    schedule = %FlowStone.Schedule{
      asset: asset,
      cron: Keyword.fetch!(opts, :cron),
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
end
