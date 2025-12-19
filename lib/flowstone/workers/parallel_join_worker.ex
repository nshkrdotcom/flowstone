defmodule FlowStone.Workers.ParallelJoinWorker do
  @moduledoc """
  Oban worker that coordinates parallel branch joins.
  """

  use Oban.Worker,
    queue: :parallel_join,
    max_attempts: 10,
    unique: [period: 60, fields: [:args], keys: [:execution_id]]

  alias FlowStone.{AuditLogContext, Error, LineagePersistence, MaterializationContext}
  alias FlowStone.{Materializations, Parallel, Partition, Registry, RunConfig}
  alias FlowStone.Parallel.{Branch, Execution}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}), do: perform(%Oban.Job{args: args}, nil)

  def perform(%Oban.Job{args: args}, run_config) do
    execution_id = args["execution_id"]
    run_id = args["run_id"]
    parent_asset_str = args["parent_asset"]
    partition = Partition.deserialize(args["partition"])
    use_repo = Map.get(args, "use_repo", true)

    config = run_config || RunConfig.get(run_id) || []
    registry = Keyword.get(config, :registry) || get_registry_from_config()
    io_opts = build_io_opts(config)
    lineage_server = Keyword.get(config, :lineage_server) || get_lineage_from_config()

    mat_store =
      Keyword.get(config, :materialization_store) || get_materialization_store_from_config()

    with {:ok, asset_name} <- resolve_asset_name(parent_asset_str, registry),
         {:ok, asset} <- Registry.fetch(asset_name, server: registry),
         %Execution{} = execution <- Parallel.get_execution(execution_id) do
      run_join(asset, execution, partition, run_id,
        io_opts: io_opts,
        lineage_server: lineage_server,
        materialization_store: mat_store,
        use_repo: use_repo
      )
    else
      nil -> {:discard, "Parallel execution not found"}
      {:error, reason} -> {:discard, reason}
    end
  end

  defp run_join(asset, execution, partition, run_id, opts) do
    case execution.status do
      status when status in [:completed, :failed] ->
        :ok

      :joining ->
        {:snooze, 5}

      _ ->
        refresh = refresh_branch_statuses(asset, execution, partition, run_id, opts)

        mode = parallel_failure_mode(asset)

        with {:ok, %{statuses: statuses, branches: branches} = refresh} <- refresh,
             :ok <- maybe_update_counts(execution, statuses),
             :ok <- check_timeout(asset, execution, partition),
             :ok <- ensure_ready(statuses, branches, mode) do
          case Parallel.mark_joining(execution.id) do
            :ok ->
              finalize_join(asset, execution, partition, run_id, refresh, opts)

            :already_running ->
              {:snooze, 5}
          end
        else
          {:snooze, seconds} -> {:snooze, seconds}
          {:error, reason} -> finalize_failure(asset, execution, partition, run_id, reason, opts)
        end
    end
  end

  defp refresh_branch_statuses(asset, execution, partition, run_id, opts) do
    branches = Map.get(asset, :parallel_branches, %{})
    branch_records = Parallel.list_branches(execution.id) |> Map.new(&{&1.branch_name, &1})

    {statuses, errors} =
      Enum.reduce(branches, {%{}, %{}}, fn {branch_name, branch}, {status_acc, error_acc} ->
        record = Map.get(branch_records, Atom.to_string(branch_name))

        {status, materialization_id, error} =
          branch_status(branch.final, partition, run_id, opts)

        maybe_update_branch(
          asset,
          execution,
          partition,
          record,
          branch,
          status,
          materialization_id,
          error
        )

        error_acc =
          if status == :failed do
            Map.put(error_acc, branch_name, error_message(error))
          else
            error_acc
          end

        {Map.put(status_acc, branch_name, status), error_acc}
      end)

    {:ok, %{statuses: statuses, errors: errors, branches: branches}}
  end

  defp branch_status(asset_name, partition, run_id, opts) do
    mat =
      MaterializationContext.get(asset_name, partition, run_id,
        store: opts[:materialization_store],
        use_repo: opts[:use_repo]
      )

    case mat do
      %FlowStone.Materialization{status: :success, id: id} ->
        {:success, id, nil}

      %FlowStone.Materialization{status: :failed, id: id, error_message: msg} ->
        {:failed, id, error_map(msg)}

      %FlowStone.Materialization{status: :skipped, id: id} ->
        {:skipped, id, nil}

      %FlowStone.Materialization{status: _} ->
        {:pending, nil, nil}

      %{status: :success} ->
        {:success, Map.get(mat, :id), nil}

      %{status: :failed} ->
        {:failed, Map.get(mat, :id), error_map(Map.get(mat, :error))}

      %{status: :skipped} ->
        {:skipped, Map.get(mat, :id), nil}

      _ ->
        {:pending, nil, nil}
    end
  end

  defp maybe_update_branch(
         asset,
         execution,
         partition,
         record,
         branch,
         status,
         materialization_id,
         error
       ) do
    terminal? = status in [:success, :failed, :skipped]

    if terminal? and record do
      if record.status != status do
        attrs =
          %{
            status: status,
            materialization_id: materialization_id,
            error: error,
            completed_at: DateTime.utc_now()
          }
          |> maybe_put_started_at(record)

        {:ok, _} = Parallel.update_branch(record, attrs)
        emit_branch_status(asset, execution, branch, status, partition)
      end
    end
  end

  defp maybe_put_started_at(attrs, %Branch{started_at: nil}) do
    Map.put(attrs, :started_at, DateTime.utc_now())
  end

  defp maybe_put_started_at(attrs, _record), do: attrs

  defp maybe_update_counts(execution, statuses) do
    completed =
      statuses
      |> Map.values()
      |> Enum.count(&(&1 in [:success, :skipped]))

    failed = statuses |> Map.values() |> Enum.count(&(&1 == :failed))

    Parallel.update_counts(execution.id, completed, failed)
  end

  defp ensure_ready(statuses, branches, :partial) do
    required =
      branches
      |> Enum.filter(fn {_name, branch} -> branch.required end)
      |> Enum.map(&elem(&1, 0))

    if Enum.all?(required, fn name ->
         Map.get(statuses, name) in [:success, :failed, :skipped]
       end) do
      :ok
    else
      {:snooze, 5}
    end
  end

  defp ensure_ready(statuses, _branches, _mode) do
    if Enum.all?(statuses, fn {_name, status} -> status in [:success, :failed, :skipped] end) do
      :ok
    else
      {:snooze, 5}
    end
  end

  defp check_timeout(asset, execution, partition) do
    case parallel_timeout(asset) do
      :infinity ->
        :ok

      nil ->
        :ok

      timeout_ms when is_integer(timeout_ms) ->
        elapsed_ms = DateTime.diff(DateTime.utc_now(), execution.inserted_at, :millisecond)

        if elapsed_ms > timeout_ms do
          {:error, Error.timeout(asset.name, partition, timeout_ms)}
        else
          :ok
        end
    end
  end

  defp finalize_join(asset, execution, partition, run_id, %{statuses: statuses} = refresh, opts) do
    failures = Enum.filter(statuses, fn {_name, status} -> status != :success end)

    if parallel_failure_mode(asset) == :all_or_nothing and failures != [] do
      err =
        Error.execution_error(
          asset.name,
          partition,
          %RuntimeError{message: "Parallel branches failed: #{inspect(failures)}"},
          []
        )

      finalize_failure(asset, execution, partition, run_id, err, opts)
    else
      mode = parallel_failure_mode(asset)
      run_join_fn(asset, execution, partition, run_id, refresh, opts, mode)
    end
  end

  defp run_join_fn(asset, execution, partition, run_id, refresh, opts, mode) do
    start_time = System.monotonic_time(:millisecond)

    with {:ok, deps} <- load_dependencies(asset, partition, opts[:io_opts]),
         {:ok, branches} <- load_branch_results(refresh, partition, opts[:io_opts], mode) do
      join_fn = Map.get(asset, :join_fn)

      case evaluate_join(join_fn, branches, deps) do
        {:ok, result} ->
          :ok = FlowStone.IO.store(asset.name, result, partition, opts[:io_opts])
          duration = System.monotonic_time(:millisecond) - start_time

          Materializations.record_success(asset.name, partition, run_id, duration,
            store: opts[:materialization_store],
            use_repo: opts[:use_repo]
          )

          record_lineage(asset, partition, run_id, deps, refresh, opts)
          emit_materialization_stop(asset, partition, run_id, duration)
          maybe_audit(asset.name, partition, run_id, opts[:use_repo])

          {:ok, _} = Parallel.update_execution(execution, %{status: :completed})
          emit_parallel_stop(asset, partition, run_id, execution.id, duration)
          :ok

        {:error, reason} ->
          finalize_failure(asset, execution, partition, run_id, reason, opts)
      end
    else
      {:error, reason} ->
        finalize_failure(asset, execution, partition, run_id, reason, opts)
    end
  end

  defp load_branch_results(
         %{branches: branches, statuses: statuses, errors: errors},
         partition,
         io_opts,
         :partial
       ) do
    results =
      Enum.reduce(branches, %{}, fn {branch_name, branch}, acc ->
        status = Map.fetch!(statuses, branch_name)
        value = partial_branch_value(status, branch, partition, io_opts, errors, branch_name)
        Map.put(acc, branch_name, value)
      end)

    {:ok, results}
  end

  defp load_branch_results(%{branches: branches}, partition, io_opts, :all_or_nothing) do
    Enum.reduce_while(branches, {:ok, %{}}, fn {branch_name, branch}, {:ok, acc} ->
      case FlowStone.IO.load(branch.final, partition, io_opts) do
        {:ok, data} ->
          {:cont, {:ok, Map.put(acc, branch_name, data)}}

        {:error, reason} ->
          {:halt, {:error, {:branch_load_failed, branch_name, reason}}}
      end
    end)
  end

  defp load_dependencies(asset, partition, io_opts) do
    deps = Map.get(asset, :depends_on, [])
    optional = Map.get(asset, :optional_deps, [])

    deps
    |> Enum.reduce_while(%{}, fn dep, acc ->
      load_dependency(dep, partition, io_opts, optional, acc)
    end)
    |> normalize_dependency_result(asset)
  end

  defp partial_branch_value(:success, branch, partition, io_opts, _errors, _branch_name) do
    case FlowStone.IO.load(branch.final, partition, io_opts) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp partial_branch_value(:failed, _branch, _partition, _io_opts, errors, branch_name) do
    {:error, Map.get(errors, branch_name, "branch_failed")}
  end

  defp partial_branch_value(:skipped, _branch, _partition, _io_opts, _errors, _branch_name),
    do: :skipped

  defp partial_branch_value(:pending, branch, _partition, _io_opts, _errors, _branch_name) do
    if branch.required do
      {:error, "branch_pending"}
    else
      :skipped
    end
  end

  defp load_dependency(dep, partition, io_opts, optional, acc) do
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

  defp normalize_dependency_result({:missing, dep}, asset) do
    {:error, Error.dependency_not_ready(asset.name, [dep])}
  end

  defp normalize_dependency_result(map, _asset) when is_map(map), do: {:ok, map}

  defp evaluate_join(nil, branches, _deps), do: {:ok, branches}

  defp evaluate_join(join_fn, branches, deps) do
    result =
      cond do
        is_function(join_fn, 2) -> join_fn.(branches, deps)
        is_function(join_fn, 1) -> join_fn.(branches)
        true -> branches
      end

    case result do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
      value -> {:ok, value}
    end
  rescue
    exception ->
      {:error, {:exception, exception, __STACKTRACE__}}
  catch
    :exit, reason ->
      {:error, {:exit, reason}}
  end

  defp finalize_failure(asset, execution, partition, run_id, reason, opts) do
    err =
      case reason do
        %Error{} = error ->
          error

        {:exception, exception, stacktrace} ->
          Error.execution_error(asset.name, partition, exception, stacktrace)

        {:exit, exit_reason} ->
          Error.execution_error(
            asset.name,
            partition,
            %RuntimeError{message: inspect(exit_reason)},
            []
          )

        other ->
          Error.execution_error(asset.name, partition, wrap(other), [])
      end

    Materializations.record_failure(asset.name, partition, run_id, err,
      store: opts[:materialization_store],
      use_repo: opts[:use_repo]
    )

    emit_materialization_exception(asset, partition, run_id, err)
    {:ok, _} = Parallel.update_execution(execution, %{status: :failed})
    emit_parallel_error(asset, partition, run_id, execution.id, err)
    :ok
  end

  defp record_lineage(asset, partition, run_id, deps, %{branches: branches}, opts) do
    deps_pairs =
      deps
      |> Enum.reject(fn {_dep, data} -> is_nil(data) end)
      |> Enum.map(fn {dep, _data} -> {dep, partition} end)

    branch_pairs =
      branches
      |> Enum.map(fn {_name, branch} -> {branch.final, partition} end)

    pairs = Enum.uniq(deps_pairs ++ branch_pairs)

    LineagePersistence.record(asset.name, partition, run_id, pairs,
      server: opts[:lineage_server],
      use_repo: opts[:use_repo]
    )
  end

  defp emit_materialization_stop(asset, partition, run_id, duration) do
    :telemetry.execute([:flowstone, :materialization, :stop], %{duration: duration}, %{
      asset: asset.name,
      partition: partition,
      run_id: run_id
    })
  end

  defp emit_materialization_exception(asset, partition, run_id, error) do
    :telemetry.execute([:flowstone, :materialization, :exception], %{}, %{
      asset: asset.name,
      partition: partition,
      run_id: run_id,
      error: error
    })
  end

  defp emit_parallel_stop(asset, partition, run_id, execution_id, duration) do
    :telemetry.execute([:flowstone, :parallel, :stop], %{duration: duration}, %{
      asset: asset.name,
      partition: partition,
      run_id: run_id,
      execution_id: execution_id
    })
  end

  defp emit_parallel_error(asset, partition, run_id, execution_id, error) do
    :telemetry.execute([:flowstone, :parallel, :error], %{}, %{
      asset: asset.name,
      partition: partition,
      run_id: run_id,
      execution_id: execution_id,
      error: error
    })
  end

  defp emit_branch_status(asset, execution, branch, :failed, partition) do
    :telemetry.execute([:flowstone, :parallel, :branch_fail], %{}, %{
      asset: asset.name,
      branch: branch.name,
      final_asset: branch.final,
      run_id: execution.run_id,
      partition: partition,
      execution_id: execution.id
    })
  end

  defp emit_branch_status(asset, execution, branch, status, partition)
       when status in [:success, :skipped] do
    :telemetry.execute([:flowstone, :parallel, :branch_complete], %{}, %{
      asset: asset.name,
      branch: branch.name,
      final_asset: branch.final,
      run_id: execution.run_id,
      partition: partition,
      execution_id: execution.id,
      status: status
    })
  end

  defp parallel_failure_mode(asset) do
    asset
    |> Map.get(:parallel_options, %{})
    |> Map.get(:failure_mode, :all_or_nothing)
  end

  defp parallel_timeout(asset) do
    asset
    |> Map.get(:parallel_options, %{})
    |> Map.get(:timeout)
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

  defp resolve_asset_name(name_string, registry) when is_binary(name_string) do
    case safe_to_existing_atom(name_string) do
      {:ok, atom} ->
        case Registry.fetch(atom, server: registry) do
          {:ok, _} -> {:ok, atom}
          _ -> {:error, "Asset not found: #{name_string}"}
        end

      :error ->
        {:error, "Unknown asset: #{name_string}"}
    end
  end

  defp safe_to_existing_atom(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> :error
  end

  defp get_registry_from_config do
    Application.get_env(:flowstone, :registry, FlowStone.Registry)
  end

  defp get_lineage_from_config do
    Application.get_env(:flowstone, :lineage_server, FlowStone.Lineage)
  end

  defp get_materialization_store_from_config do
    Application.get_env(:flowstone, :materialization_store, FlowStone.MaterializationStore)
  end

  defp build_io_opts(config) do
    case Keyword.get(config, :io_opts) do
      opts when is_list(opts) and opts != [] ->
        opts

      _ ->
        case Keyword.get(config, :io_config) do
          %{"manager" => manager, "config" => io_config} when not is_nil(manager) ->
            [manager: resolve_io_manager(manager), config: convert_config_keys(io_config)]

          %{"config" => io_config} when is_map(io_config) ->
            [config: convert_config_keys(io_config)]

          _ ->
            []
        end
    end
  end

  defp convert_config_keys(config) when is_map(config) do
    config
    |> Enum.map(fn {k, v} -> {safe_key_to_atom(k), v} end)
    |> Map.new()
  end

  defp convert_config_keys(other), do: other

  defp safe_key_to_atom(key) when is_atom(key), do: key

  defp safe_key_to_atom(key) when is_binary(key) do
    case safe_to_existing_atom(key) do
      {:ok, atom} -> atom
      :error -> key
    end
  end

  defp resolve_io_manager(manager_string) when is_binary(manager_string) do
    case safe_to_existing_atom(manager_string) do
      {:ok, mod} -> mod
      :error -> nil
    end
  end

  defp resolve_io_manager(other), do: other

  defp error_map(%{message: msg}), do: %{"message" => msg, "type" => "error"}
  defp error_map(msg) when is_binary(msg), do: %{"message" => msg, "type" => "error"}
  defp error_map(other), do: %{"message" => inspect(other), "type" => "error"}

  defp wrap(reason) when is_binary(reason), do: %RuntimeError{message: reason}
  defp wrap(reason) when is_atom(reason), do: %RuntimeError{message: Atom.to_string(reason)}
  defp wrap(reason), do: %RuntimeError{message: inspect(reason)}

  defp error_message(error) when is_map(error) do
    case Map.get(error, "message") || Map.get(error, :message) do
      nil -> inspect(error)
      msg -> to_string(msg)
    end
  end

  defp error_message(other), do: inspect(other)
end
