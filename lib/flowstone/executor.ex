defmodule FlowStone.Executor do
  @moduledoc """
  Executes a single asset, loading dependencies and storing results via I/O managers.
  """

  alias FlowStone.{Context, Error, Materializer, Registry}

  @spec materialize(atom(), keyword()) :: {:ok, term()} | {:error, Error.t()} | {:error, term()}
  def materialize(asset_name, opts) do
    partition = Keyword.fetch!(opts, :partition)
    registry = Keyword.get(opts, :registry, Registry)
    io_opts = Keyword.get(opts, :io, [])
    use_repo = Keyword.get(opts, :use_repo, true)

    resource_server =
      Keyword.get(
        opts,
        :resource_server,
        Application.get_env(:flowstone, :resources_server, FlowStone.Resources)
      )

    lineage_server =
      Keyword.get(
        opts,
        :lineage_server,
        Application.get_env(:flowstone, :lineage_server, FlowStone.Lineage)
      )

    mat_store =
      Keyword.get(
        opts,
        :materialization_store,
        Application.get_env(:flowstone, :materialization_store, FlowStone.MaterializationStore)
      )

    run_id = Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0)

    with {:ok, asset} <- Registry.fetch(asset_name, server: registry),
         {:ok, deps} <- load_dependencies(asset, partition, io_opts),
         context <- Context.build(asset, partition, run_id, resource_server: resource_server) do
      start_time = System.monotonic_time(:millisecond)
      record_start(asset.name, partition, run_id, mat_store, use_repo)

      case Materializer.execute(asset, context, deps) do
        {:ok, result} ->
          :ok = FlowStone.IO.store(asset.name, result, partition, io_opts)
          duration = System.monotonic_time(:millisecond) - start_time
          record_success(asset.name, partition, run_id, duration, mat_store, use_repo)
          record_lineage(asset.name, partition, run_id, deps, lineage_server, use_repo)
          {:ok, result}

        {:error, %Error{} = err} ->
          record_failure(asset.name, partition, run_id, err, mat_store, use_repo)
          {:error, err}
      end
    end
  end

  defp load_dependencies(asset, partition, io_opts) do
    deps = Map.get(asset, :depends_on, [])

    results =
      Enum.reduce_while(deps, %{}, fn dep, acc ->
        case FlowStone.IO.load(dep, partition, io_opts) do
          {:ok, data} -> {:cont, Map.put(acc, dep, data)}
          {:error, _} -> {:halt, {:missing, dep}}
        end
      end)

    case results do
      {:missing, dep} -> {:error, Error.dependency_not_ready(asset.name, [dep])}
      map when is_map(map) -> {:ok, map}
    end
  end

  defp record_lineage(asset, partition, run_id, deps, server, use_repo) do
    pairs = Enum.map(deps, fn {dep, _data} -> {dep, partition} end)

    FlowStone.LineagePersistence.record(asset, partition, run_id, pairs,
      server: server,
      use_repo: use_repo
    )
  end

  defp record_start(asset, partition, run_id, store, use_repo) do
    FlowStone.Materializations.record_start(asset, partition, run_id,
      store: store,
      use_repo: use_repo
    )
  end

  defp record_success(asset, partition, run_id, duration_ms, store, use_repo) do
    FlowStone.Materializations.record_success(asset, partition, run_id, duration_ms,
      store: store,
      use_repo: use_repo
    )
  end

  defp record_failure(asset, partition, run_id, error, store, use_repo) do
    FlowStone.Materializations.record_failure(asset, partition, run_id, error,
      store: store,
      use_repo: use_repo
    )
  end
end
