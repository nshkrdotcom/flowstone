defmodule FlowStone.Executor do
  @moduledoc """
  Executes a single asset, loading dependencies and storing results via I/O managers.
  """

  alias FlowStone.{
    AuditLogContext,
    Context,
    Error,
    Materializer,
    Parallel,
    Registry,
    RouteDecisions
  }

  @spec materialize(atom(), keyword()) :: {:ok, term()} | {:error, Error.t()} | {:error, term()}
  def materialize(asset_name, opts) do
    partition = Keyword.fetch!(opts, :partition)
    registry = Keyword.get(opts, :registry, Registry)
    io_opts = Keyword.get(opts, :io, [])
    use_repo = Keyword.get(opts, :use_repo, true)

    # Use get_with_default to ensure nil doesn't override defaults
    resource_server =
      get_with_default(opts, :resource_server, fn ->
        Application.get_env(:flowstone, :resources_server, FlowStone.Resources)
      end)

    lineage_server =
      get_with_default(opts, :lineage_server, fn ->
        Application.get_env(:flowstone, :lineage_server, FlowStone.Lineage)
      end)

    mat_store =
      get_with_default(opts, :materialization_store, fn ->
        Application.get_env(:flowstone, :materialization_store, FlowStone.MaterializationStore)
      end)

    run_id = Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0)

    with {:ok, asset} <- Registry.fetch(asset_name, server: registry),
         {:ok, deps} <- load_dependencies(asset, partition, run_id, io_opts),
         context <-
           Context.build(asset, partition, run_id,
             resource_server: resource_server,
             metadata: %{route_branches: route_branches(asset, registry)}
           ) do
      start_time = System.monotonic_time(:millisecond)
      telemetry_start(asset.name, partition, run_id)
      record_start(asset.name, partition, run_id, mat_store, use_repo)

      case Materializer.execute(asset, context, deps) do
        {:ok, result} ->
          :ok = FlowStone.IO.store(asset.name, result, partition, io_opts)
          duration = System.monotonic_time(:millisecond) - start_time
          record_success(asset.name, partition, run_id, duration, mat_store, use_repo)
          telemetry_stop(asset.name, partition, run_id, duration)
          maybe_audit(asset.name, partition, run_id, use_repo)
          record_lineage(asset.name, partition, run_id, deps, lineage_server, use_repo)
          {:ok, result}

        {:parallel_pending, _info} ->
          case Parallel.start_execution(asset, context,
                 registry: registry,
                 io: io_opts,
                 resource_server: resource_server,
                 lineage_server: lineage_server,
                 materialization_store: mat_store,
                 use_repo: use_repo,
                 run_id: run_id,
                 partition: partition
               ) do
            {:ok, _execution} ->
              {:ok, :parallel_pending}

            {:error, %Error{} = err} ->
              record_failure(asset.name, partition, run_id, err, mat_store, use_repo)
              telemetry_exception(asset.name, partition, run_id, err)
              {:error, err}

            {:error, reason} ->
              err = Error.execution_error(asset.name, partition, wrap(reason), [])
              record_failure(asset.name, partition, run_id, err, mat_store, use_repo)
              telemetry_exception(asset.name, partition, run_id, err)
              {:error, err}
          end

        {:skipped, _reason} ->
          duration = System.monotonic_time(:millisecond) - start_time
          record_skipped(asset.name, partition, run_id, duration, mat_store, use_repo)
          telemetry_stop(asset.name, partition, run_id, duration)
          {:ok, :skipped}

        {:error, %Error{} = err} ->
          record_failure(asset.name, partition, run_id, err, mat_store, use_repo)
          telemetry_exception(asset.name, partition, run_id, err)
          {:error, err}
      end
    end
  end

  defp load_dependencies(asset, partition, run_id, io_opts) do
    deps = Map.get(asset, :depends_on, [])
    optional = Map.get(asset, :optional_deps, [])

    with :ok <- ensure_route_decision(asset, partition, run_id) do
      results =
        Enum.reduce_while(deps, %{}, fn dep, acc ->
          load_single_dep(dep, partition, io_opts, optional, acc)
        end)

      case results do
        {:missing, dep} -> {:error, Error.dependency_not_ready(asset.name, [dep])}
        map when is_map(map) -> {:ok, map}
      end
    end
  end

  defp load_single_dep(dep, partition, io_opts, optional, acc) do
    case FlowStone.IO.load(dep, partition, io_opts) do
      {:ok, data} ->
        {:cont, Map.put(acc, dep, data)}

      {:error, _} ->
        if dep in optional do
          {:cont, Map.put(acc, dep, nil)}
        else
          {:halt, {:missing, dep}}
        end
    end
  end

  defp record_lineage(asset, partition, run_id, deps, server, use_repo) do
    pairs =
      deps
      |> Enum.reject(fn {_dep, data} -> is_nil(data) end)
      |> Enum.map(fn {dep, _data} -> {dep, partition} end)

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

  defp record_skipped(asset, partition, run_id, duration_ms, store, use_repo) do
    FlowStone.Materializations.record_skipped(asset, partition, run_id, duration_ms,
      store: store,
      use_repo: use_repo
    )
  end

  defp telemetry_start(asset, partition, run_id) do
    :telemetry.execute([:flowstone, :materialization, :start], %{}, %{
      asset: asset,
      partition: partition,
      run_id: run_id
    })
  end

  defp telemetry_stop(asset, partition, run_id, duration) do
    :telemetry.execute([:flowstone, :materialization, :stop], %{duration: duration}, %{
      asset: asset,
      partition: partition,
      run_id: run_id
    })
  end

  defp telemetry_exception(asset, partition, run_id, error) do
    :telemetry.execute([:flowstone, :materialization, :exception], %{}, %{
      asset: asset,
      partition: partition,
      run_id: run_id,
      error: error
    })
  end

  defp maybe_audit(asset, partition, run_id, use_repo) do
    if use_repo do
      AuditLogContext.log("asset.materialized",
        actor_id: "system",
        actor_type: "system",
        resource_type: "asset",
        resource_id: Atom.to_string(asset),
        action: "materialized",
        details: %{run_id: run_id, partition: FlowStone.Partition.serialize(partition)}
      )
    else
      :ok
    end
  end

  defp ensure_route_decision(asset, partition, run_id) do
    case Map.get(asset, :routed_from) do
      nil ->
        :ok

      router_asset ->
        case RouteDecisions.get(run_id, router_asset, partition) do
          {:ok, _decision} -> :ok
          {:error, :not_found} -> {:error, Error.dependency_not_ready(asset.name, [router_asset])}
        end
    end
  end

  defp route_branches(asset, registry) do
    if router_asset?(asset) do
      Registry.list(server: registry)
      |> Enum.filter(fn candidate -> candidate.routed_from == asset.name end)
      |> Enum.map(& &1.name)
      |> Enum.sort()
    else
      []
    end
  end

  defp router_asset?(asset) do
    not is_nil(Map.get(asset, :route_fn)) or not is_nil(Map.get(asset, :route_rules))
  end

  # Get a value from opts, falling back to default_fn if key is missing or nil.
  # This prevents nil from overriding defaults (unlike Keyword.get/3).
  defp get_with_default(opts, key, default_fn) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when not is_nil(value) -> value
      _ -> default_fn.()
    end
  end

  defp wrap(reason) when is_binary(reason), do: %RuntimeError{message: reason}
  defp wrap(reason) when is_atom(reason), do: %RuntimeError{message: Atom.to_string(reason)}
  defp wrap(reason), do: %RuntimeError{message: inspect(reason)}
end
