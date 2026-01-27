defmodule FlowStone.API do
  @moduledoc """
  Simplified API for FlowStone v0.5.0.

  This module provides a clean, pipeline-centric API for running and managing
  FlowStone assets. It eliminates the need for manual registry setup, server
  management, and complex option passing.

  ## Quick Start

      # Define a pipeline
      defmodule MyPipeline do
        use FlowStone.Pipeline

        asset :greeting do
          execute fn _, _ -> {:ok, "Hello!"} end
        end
      end

      # Run it
      {:ok, "Hello!"} = FlowStone.run(MyPipeline, :greeting)

  ## Features

  - **Auto-registration**: Pipelines are automatically registered on first use
  - **Simple defaults**: Works with zero configuration using in-memory storage
  - **Partition support**: Run assets for different time periods or segments
  - **Caching**: Results are automatically cached and reused
  - **Backfill**: Process multiple partitions efficiently

  ## Options

  All functions that accept options support:

  - `partition` - The partition key (default: `:default`)
  - `storage` - Override the storage backend
  - `force` - Re-run even if cached (default: `false`)
  - `metadata` - Extra metadata propagated to execution context and observability
  - `trace_id` - Override the trace id used for lineage/run indexing
  """

  alias FlowStone.{
    Context,
    DAG,
    Error,
    ExecutionMetadata,
    IO,
    LineageEmitter,
    Materializer,
    Registry,
    RunIndex
  }

  alias FlowStone.IO.Memory, as: IOMemory

  @default_partition :default
  @default_timeout 300_000

  # Registry and IO manager names are derived from the pipeline module
  # This ensures isolation between pipelines and tests

  @doc """
  Run an asset and return its result.

  ## Examples

      # Basic usage
      {:ok, result} = FlowStone.run(MyPipeline, :asset)

      # With partition
      {:ok, result} = FlowStone.run(MyPipeline, :asset, partition: ~D[2025-01-15])

      # Force re-run
      {:ok, result} = FlowStone.run(MyPipeline, :asset, force: true)

  ## Options

  - `partition` - Partition key (default: `:default`)
  - `force` - Re-run even if cached (default: `false`)
  - `with_deps` - Run missing dependencies first (default: `true`)
  - `timeout` - Execution timeout in ms (default: 300_000)
  - `async` - Run via Oban job queue (default: `false`)
  - `metadata` - Metadata for lineage and run indexing (plan_id, trace_id, work_id, etc.)

  ## Returns

  - `{:ok, result}` - On success (sync mode)
  - `{:ok, %Oban.Job{}}` - When async: true
  - `{:error, %FlowStone.Error{}}` - On failure
  """
  @spec run(module(), atom(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(pipeline, asset_name, opts \\ []) do
    partition = Keyword.get(opts, :partition, @default_partition)
    force? = Keyword.get(opts, :force, false)
    with_deps? = Keyword.get(opts, :with_deps, true)
    _timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Ensure pipeline is registered
    with :ok <- ensure_pipeline_registered(pipeline),
         {:ok, asset} <- fetch_asset(pipeline, asset_name) do
      # Check cache unless force
      if not force? and cached?(pipeline, asset_name, partition) do
        load_result(pipeline, asset_name, partition)
      else
        if with_deps? do
          run_with_deps(pipeline, asset, partition, opts)
        else
          run_single(pipeline, asset, partition, opts)
        end
      end
    end
  end

  @doc """
  Retrieve the result of a previously run asset.

  ## Examples

      {:ok, result} = FlowStone.get(MyPipeline, :asset)
      {:ok, result} = FlowStone.get(MyPipeline, :asset, partition: ~D[2025-01-15])

  ## Returns

  - `{:ok, result}` - If the asset has been run
  - `{:error, :not_found}` - If not found
  """
  @spec get(module(), atom(), keyword()) :: {:ok, term()} | {:error, :not_found}
  def get(pipeline, asset_name, opts \\ []) do
    partition = Keyword.get(opts, :partition, @default_partition)

    # Ensure IO agent is started
    :ok = ensure_pipeline_registered(pipeline)

    load_result(pipeline, asset_name, partition)
  end

  @doc """
  Check if an asset result exists.

  ## Examples

      FlowStone.exists?(MyPipeline, :asset)
      FlowStone.exists?(MyPipeline, :asset, partition: ~D[2025-01-15])

  ## Returns

  - `true` if the asset has been run
  - `false` otherwise
  """
  @spec exists?(module(), atom(), keyword()) :: boolean()
  def exists?(pipeline, asset_name, opts \\ []) do
    partition = Keyword.get(opts, :partition, @default_partition)

    # Ensure IO agent is started
    :ok = ensure_pipeline_registered(pipeline)

    cached?(pipeline, asset_name, partition)
  end

  @doc """
  Remove cached results for an asset.

  ## Examples

      {:ok, 1} = FlowStone.invalidate(MyPipeline, :asset)
      {:ok, 0} = FlowStone.invalidate(MyPipeline, :never_run)

  ## Options

  - `partition` - Specific partition to invalidate (default: `:default`)
  - `cascade` - Also invalidate downstream dependents (default: `false`)

  ## Returns

  - `{:ok, count}` - Number of invalidated items
  """
  @spec invalidate(module(), atom(), keyword()) :: {:ok, non_neg_integer()}
  def invalidate(pipeline, asset_name, opts \\ []) do
    partition = Keyword.get(opts, :partition, @default_partition)

    # Ensure IO agent is started
    :ok = ensure_pipeline_registered(pipeline)

    io_opts = io_opts_for_pipeline(pipeline)

    if IO.exists?(asset_name, partition, io_opts) do
      :ok = IO.delete(asset_name, partition, io_opts)
      {:ok, 1}
    else
      {:ok, 0}
    end
  end

  @doc """
  Get the status of an asset.

  ## Examples

      status = FlowStone.status(MyPipeline, :asset)
      # => %{state: :completed, partition: :default, ...}

  ## Returns

  A map with:
  - `state` - `:completed`, `:running`, `:pending`, `:failed`, or `:not_found`
  - `partition` - The partition key
  - Other status-specific fields
  """
  @spec status(module(), atom(), keyword()) :: map()
  def status(pipeline, asset_name, opts \\ []) do
    partition = Keyword.get(opts, :partition, @default_partition)

    # Ensure IO agent is started
    :ok = ensure_pipeline_registered(pipeline)

    if cached?(pipeline, asset_name, partition) do
      %{
        state: :completed,
        partition: partition
      }
    else
      %{
        state: :not_found,
        partition: partition
      }
    end
  end

  # Maximum concurrent partitions for backfill
  @max_parallel_default 32
  # 30 minutes per partition
  @backfill_timeout_default 1_800_000

  @doc """
  Run an asset across multiple partitions.

  ## Examples

      {:ok, stats} = FlowStone.backfill(MyPipeline, :asset,
        partitions: Date.range(~D[2025-01-01], ~D[2025-01-31])
      )

      {:ok, stats} = FlowStone.backfill(MyPipeline, :asset,
        partitions: [:us, :eu, :asia],
        parallel: 4
      )

  ## Options

  - `partitions` - (required) Enumerable of partition keys
  - `parallel` - Number of concurrent executions (default: 1, max: 32)
  - `timeout` - Timeout per partition in milliseconds (default: 30 minutes)
  - `force` - Re-run even if cached (default: `false`)
  - `on_error` - `:continue` or `:halt` (default: `:continue`)

  ## Returns

  - `{:ok, stats}` with `%{succeeded: N, failed: N, skipped: N}`

  ## Resource Protection

  The `parallel` option is capped at 32 to prevent resource exhaustion.
  Each partition has a default timeout of 30 minutes.
  """
  @spec backfill(module(), atom(), keyword()) ::
          {:ok,
           %{succeeded: non_neg_integer(), failed: non_neg_integer(), skipped: non_neg_integer()}}
  def backfill(pipeline, asset_name, opts) do
    partitions = Keyword.fetch!(opts, :partitions) |> Enum.to_list()
    parallel = opts |> Keyword.get(:parallel, 1) |> min(@max_parallel_default) |> max(1)
    timeout = Keyword.get(opts, :timeout, @backfill_timeout_default)
    force? = Keyword.get(opts, :force, false)
    _on_error = Keyword.get(opts, :on_error, :continue)

    # Ensure pipeline is registered
    :ok = ensure_pipeline_registered(pipeline)

    # Filter out already-completed partitions unless force
    {to_run, skipped} =
      if force? do
        {partitions, []}
      else
        Enum.split_with(partitions, fn p ->
          not cached?(pipeline, asset_name, p)
        end)
      end

    # Run partitions
    results =
      if parallel > 1 do
        to_run
        |> Task.async_stream(
          fn partition ->
            run(pipeline, asset_name, Keyword.put(opts, :partition, partition))
          end,
          max_concurrency: parallel,
          timeout: timeout,
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, :timeout} -> {:error, :timeout}
        end)
      else
        Enum.map(to_run, fn partition ->
          run(pipeline, asset_name, Keyword.put(opts, :partition, partition))
        end)
      end

    succeeded = Enum.count(results, &match?({:ok, _}, &1))
    failed = Enum.count(results, &match?({:error, _}, &1))

    {:ok, %{succeeded: succeeded, failed: failed, skipped: length(skipped)}}
  end

  @doc """
  Get a visual representation of the pipeline DAG.

  ## Examples

      FlowStone.graph(MyPipeline)
      # => "raw\\n└── processed\\n    └── output"

      FlowStone.graph(MyPipeline, format: :mermaid)
      # => "graph TD\\n  raw --> processed\\n  ..."

  ## Options

  - `format` - `:ascii` (default), `:mermaid`, or `:dot`
  """
  @spec graph(module(), keyword()) :: String.t()
  def graph(pipeline, opts \\ []) do
    format = Keyword.get(opts, :format, :ascii)
    assets = pipeline.__flowstone_assets__()

    case DAG.from_assets(assets) do
      {:ok, dag} ->
        render_graph(dag, assets, format)

      {:error, _reason} ->
        "Error: Could not build graph"
    end
  end

  @doc """
  List all assets in a pipeline.

  ## Examples

      FlowStone.assets(MyPipeline)
      # => [:raw, :processed, :output]
  """
  @spec assets(module()) :: [atom()]
  def assets(pipeline) do
    pipeline.__flowstone_assets__()
    |> Enum.map(& &1.name)
  end

  @doc """
  Get detailed information about an asset.

  ## Examples

      FlowStone.asset_info(MyPipeline, :processed)
      # => %{name: :processed, depends_on: [:raw], ...}
  """
  @spec asset_info(module(), atom()) :: map() | {:error, :not_found}
  def asset_info(pipeline, asset_name) do
    case Enum.find(pipeline.__flowstone_assets__(), &(&1.name == asset_name)) do
      nil ->
        {:error, :not_found}

      asset ->
        %{
          name: asset.name,
          depends_on: asset.depends_on || [],
          description: asset.description,
          module: asset.module
        }
    end
  end

  # Semi-private functions (used by FlowStone.Test)

  @doc false
  def ensure_pipeline_registered(pipeline) do
    registry = registry_for_pipeline(pipeline)

    # Ensure registry is started
    case Registry.start_link(name: registry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Register assets if not already registered
    case Registry.list(server: registry) do
      [] ->
        assets = pipeline.__flowstone_assets__()
        Registry.register_assets(assets, server: registry)

      _ ->
        :ok
    end

    # Ensure IO manager is started
    io_agent = io_agent_for_pipeline(pipeline)

    case IOMemory.start_link(name: io_agent) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp fetch_asset(pipeline, asset_name) do
    case Enum.find(pipeline.__flowstone_assets__(), &(&1.name == asset_name)) do
      nil ->
        available = assets(pipeline)
        {:error, Error.asset_not_found_with_suggestion(pipeline, asset_name, available)}

      asset ->
        {:ok, asset}
    end
  end

  defp cached?(pipeline, asset_name, partition) do
    io_opts = io_opts_for_pipeline(pipeline)
    IO.exists?(asset_name, partition, io_opts)
  end

  defp load_result(pipeline, asset_name, partition) do
    io_opts = io_opts_for_pipeline(pipeline)

    case IO.load(asset_name, partition, io_opts) do
      {:ok, data} -> {:ok, data}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_with_deps(pipeline, asset, partition, opts) do
    assets = pipeline.__flowstone_assets__()
    run_id = Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0)
    meta = run_meta(opts, run_id)
    started_at = DateTime.utc_now()

    case DAG.from_assets(assets) do
      {:ok, dag} ->
        _ = RunIndex.write_run(run_attrs(meta, partition, "running", started_at), opts)

        result = run_deps_in_order(pipeline, asset, partition, opts, dag, run_id)
        finish_run_index(result, meta, partition, started_at, opts)
        result

      {:error, reason} ->
        {:error, Error.validation_error(asset.name, reason)}
    end
  end

  defp run_deps_in_order(pipeline, asset, partition, opts, dag, run_id) do
    registry = registry_for_pipeline(pipeline)
    io_opts = io_opts_for_pipeline(pipeline)
    deps_to_run = dependencies_for(asset.name, dag)

    run_context = %{
      pipeline: pipeline,
      target_name: asset.name,
      partition: partition,
      run_id: run_id,
      registry: registry,
      io_opts: io_opts,
      force?: Keyword.get(opts, :force, false),
      opts: opts
    }

    Enum.reduce_while(deps_to_run, {:ok, nil}, fn dep_name, _acc ->
      run_dep_step(dep_name, run_context)
    end)
  end

  defp run_dep_step(dep_name, run_context) do
    should_force = run_context.force? and dep_name == run_context.target_name

    if not should_force and cached?(run_context.pipeline, dep_name, run_context.partition) do
      {:cont, {:ok, :cached}}
    else
      result =
        run_single_by_name(
          run_context.pipeline,
          dep_name,
          run_context.partition,
          run_context.run_id,
          run_context.registry,
          run_context.io_opts,
          run_context.opts
        )

      handle_dep_result(dep_name, run_context.target_name, result)
    end
  end

  defp handle_dep_result(dep_name, target_name, {:ok, result}) do
    if dep_name == target_name, do: {:halt, {:ok, result}}, else: {:cont, {:ok, result}}
  end

  defp handle_dep_result(_dep_name, _target_name, {:error, reason}), do: {:halt, {:error, reason}}

  defp run_single(pipeline, asset, partition, opts) do
    registry = registry_for_pipeline(pipeline)
    io_opts = io_opts_for_pipeline(pipeline)
    run_id = Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0)
    meta = run_meta(opts, run_id)
    started_at = DateTime.utc_now()
    _ = RunIndex.write_run(run_attrs(meta, partition, "running", started_at), opts)

    # Check dependencies are available
    deps = asset.depends_on || []

    missing_deps =
      Enum.reject(deps, fn dep ->
        cached?(pipeline, dep, partition)
      end)

    if Enum.empty?(missing_deps) do
      result =
        run_single_by_name(pipeline, asset.name, partition, run_id, registry, io_opts, opts)

      finish_run_index(result, meta, partition, started_at, opts)
      result
    else
      error = Error.dependency_not_ready(asset.name, missing_deps)
      finish_run_index({:error, error}, meta, partition, started_at, opts)
      {:error, error}
    end
  end

  defp run_single_by_name(pipeline, asset_name, partition, run_id, registry, io_opts, opts) do
    with {:ok, asset} <- fetch_from_registry(pipeline, asset_name, registry),
         {:ok, deps_map} <- load_deps(asset, partition, io_opts) do
      execute_and_store(asset, asset_name, partition, run_id, deps_map, io_opts, opts)
    end
  end

  defp fetch_from_registry(pipeline, asset_name, registry) do
    case Registry.fetch(asset_name, server: registry) do
      {:ok, asset} ->
        {:ok, asset}

      {:error, :not_found} ->
        available = assets(pipeline)
        {:error, Error.asset_not_found_with_suggestion(pipeline, asset_name, available)}
    end
  end

  defp execute_and_store(asset, asset_name, partition, run_id, deps_map, io_opts, opts) do
    context = Context.build(asset, partition, run_id, metadata: metadata_from_opts(opts))
    meta = ExecutionMetadata.build(asset, context, opts)
    {:ok, span_id} = LineageEmitter.start_span(asset, context, meta, opts)
    step_record_id = Ecto.UUID.generate()
    started_at = context.started_at

    _ =
      RunIndex.write_step(
        step_attrs(meta, partition, step_record_id, span_id, "running", started_at),
        opts
      )

    case Materializer.execute(asset, context, deps_map) do
      {:ok, result} ->
        :ok = IO.store(asset_name, result, partition, io_opts)

        {:ok, artifact_ref} =
          LineageEmitter.emit_artifact(asset, context, meta, span_id, result, io_opts, opts)

        LineageEmitter.finish_span(asset, context, meta, span_id, "succeeded", nil, opts)
        finished_at = DateTime.utc_now()

        _ =
          RunIndex.write_step(
            step_attrs(meta, partition, step_record_id, span_id, "succeeded", started_at,
              finished_at: finished_at,
              output_artifact_refs: artifact_refs([artifact_ref])
            ),
            opts
          )

        {:ok, result}

      {:error, %Error{} = err} ->
        status = error_status(err)
        LineageEmitter.finish_span(asset, context, meta, span_id, status, err, opts)

        finish_step_record(
          meta,
          partition,
          step_record_id,
          span_id,
          status,
          started_at,
          err,
          opts
        )

        {:error, err}

      {:skipped, _reason} = result ->
        LineageEmitter.finish_span(asset, context, meta, span_id, "skipped", nil, opts)

        finish_step_record(
          meta,
          partition,
          step_record_id,
          span_id,
          "skipped",
          started_at,
          nil,
          opts
        )

        result

      {:parallel_pending, _info} = result ->
        LineageEmitter.finish_span(asset, context, meta, span_id, "running", nil, opts)

        finish_step_record(
          meta,
          partition,
          step_record_id,
          span_id,
          "running",
          started_at,
          nil,
          opts
        )

        result
    end
  end

  defp load_deps(asset, partition, io_opts) do
    deps = Map.get(asset, :depends_on, [])
    optional = Map.get(asset, :optional_deps, [])

    result =
      Enum.reduce_while(deps, %{}, fn dep, acc ->
        load_single_dep(asset.name, dep, partition, io_opts, dep in optional, acc)
      end)

    case result do
      {:error, _} = err -> err
      deps_map -> {:ok, deps_map}
    end
  end

  defp load_single_dep(asset_name, dep, partition, io_opts, optional?, acc) do
    case IO.load(dep, partition, io_opts) do
      {:ok, data} -> {:cont, Map.put(acc, dep, data)}
      {:error, _} when optional? -> {:cont, Map.put(acc, dep, nil)}
      {:error, _} -> {:halt, {:error, Error.dependency_not_ready(asset_name, [dep])}}
    end
  end

  defp dependencies_for(asset_name, %{edges: edges}) do
    deps = Map.get(edges, asset_name, [])
    Enum.flat_map(deps, &dependencies_for(&1, %{edges: edges})) ++ [asset_name]
  end

  # Generate unique names for registry and IO agent per pipeline
  # This provides isolation between pipelines
  defp registry_for_pipeline(pipeline) do
    Module.concat(pipeline, FlowStone.Registry)
  end

  defp io_agent_for_pipeline(pipeline) do
    Module.concat(pipeline, FlowStone.IO.Memory)
  end

  @doc false
  def io_opts_for_pipeline(pipeline) do
    [
      io_manager: :memory,
      config: %{agent: io_agent_for_pipeline(pipeline)}
    ]
  end

  # Graph rendering

  defp render_graph(dag, assets, :ascii) do
    # Find root nodes (no dependencies)
    root_names =
      assets
      |> Enum.filter(fn a -> Enum.empty?(a.depends_on || []) end)
      |> Enum.map(& &1.name)

    # Build dependency tree
    dependents = build_dependents_map(dag)

    Enum.map_join(root_names, "\n", &render_tree(&1, dependents, ""))
  end

  defp render_graph(dag, _assets, :mermaid) do
    edges =
      dag.edges
      |> Enum.flat_map(fn {child, parents} ->
        Enum.map(parents, fn parent -> "  #{parent} --> #{child}" end)
      end)
      |> Enum.join("\n")

    "graph TD\n#{edges}"
  end

  defp render_graph(_dag, _assets, _format) do
    "Unsupported format"
  end

  defp build_dependents_map(%{edges: edges}) do
    # Invert the edges map to get dependents
    Enum.reduce(edges, %{}, fn {child, parents}, acc ->
      Enum.reduce(parents, acc, fn parent, inner_acc ->
        Map.update(inner_acc, parent, [child], &[child | &1])
      end)
    end)
  end

  defp render_tree(name, dependents, prefix) do
    children = Map.get(dependents, name, []) |> Enum.sort()

    if Enum.empty?(children) do
      "#{prefix}#{name}"
    else
      child_count = length(children)

      child_lines =
        children
        |> Enum.with_index()
        |> Enum.map(&render_child(&1, child_count, dependents, prefix))

      "#{prefix}#{name}\n#{Enum.join(child_lines, "\n")}"
    end
  end

  defp render_child({child, idx}, child_count, dependents, prefix) do
    is_last = idx == child_count - 1
    connector = if is_last, do: "└── ", else: "├── "
    child_prefix = if is_last, do: "    ", else: "│   "

    render_tree(child, dependents, prefix <> child_prefix)
    |> String.replace_prefix(prefix <> child_prefix, prefix <> connector)
  end

  defp metadata_from_opts(opts) do
    base = Keyword.get(opts, :metadata, %{})

    base
    |> maybe_put(:trace_id, Keyword.get(opts, :trace_id))
    |> maybe_put(:work_id, Keyword.get(opts, :work_id))
    |> maybe_put(:plan_id, Keyword.get(opts, :plan_id))
    |> maybe_put(:plan_version, Keyword.get(opts, :plan_version))
    |> maybe_put(:plan_hash, Keyword.get(opts, :plan_hash))
    |> maybe_put(:plan_ref, Keyword.get(opts, :plan_ref))
    |> maybe_put(:session_id, Keyword.get(opts, :session_id))
    |> maybe_put(:actor_type, Keyword.get(opts, :actor_type))
    |> maybe_put(:actor_id, Keyword.get(opts, :actor_id))
    |> maybe_put(:tenant_id, Keyword.get(opts, :tenant_id))
  end

  defp run_meta(opts, run_id) do
    meta = metadata_from_opts(opts)

    %{
      run_id: run_id,
      trace_id: Map.get(meta, :trace_id) || run_id,
      work_id: Map.get(meta, :work_id),
      plan_id: Map.get(meta, :plan_id),
      plan_version: Map.get(meta, :plan_version),
      plan_hash: Map.get(meta, :plan_hash),
      plan_ref: Map.get(meta, :plan_ref),
      session_id: Map.get(meta, :session_id),
      actor_type: Map.get(meta, :actor_type),
      actor_id: Map.get(meta, :actor_id),
      tenant_id: Map.get(meta, :tenant_id)
    }
  end

  defp finish_run_index(result, meta, partition, started_at, opts) do
    finished_at = DateTime.utc_now()

    {status, error} =
      case result do
        {:ok, :skipped} -> {"skipped", nil}
        {:ok, _} -> {"succeeded", nil}
        {:error, err} -> {error_status(err), err}
      end

    {error_type, error_message, error_details} = error_fields(error)

    _ =
      RunIndex.write_run(
        run_attrs(meta, partition, status, started_at,
          finished_at: finished_at,
          status_reason: status_reason(error),
          error_type: error_type,
          error_message: error_message,
          error_details: error_details
        ),
        opts
      )

    :ok
  end

  defp finish_step_record(
         meta,
         partition,
         step_record_id,
         span_id,
         status,
         started_at,
         error,
         opts
       ) do
    {error_type, error_message, error_details} = error_fields(error)

    extra =
      %{}
      |> maybe_put(:finished_at, finished_at_for(status))
      |> maybe_put(:status_reason, status_reason(error))
      |> maybe_put(:error_type, error_type)
      |> maybe_put(:error_message, error_message)
      |> maybe_put(:error_details, error_details)

    _ =
      RunIndex.write_step(
        step_attrs(meta, partition, step_record_id, span_id, status, started_at, extra),
        opts
      )

    :ok
  end

  defp finished_at_for("running"), do: nil
  defp finished_at_for(_status), do: DateTime.utc_now()

  defp error_status(%Error{} = error) do
    if Error.waiting_approval?(error), do: "paused", else: "failed"
  end

  defp error_status(_), do: "failed"

  defp status_reason(nil), do: nil
  defp status_reason(%Error{} = err), do: if(Error.waiting_approval?(err), do: "waiting_approval")
  defp status_reason(_), do: nil

  defp error_fields(nil), do: {nil, nil, nil}

  defp error_fields(%Error{} = error) do
    {to_string(error.type), error.message, error.context}
  end

  defp error_fields(%_{} = error) do
    {error.__struct__ |> Module.split() |> List.last(), Exception.message(error), %{}}
  end

  defp error_fields(error) do
    {"error", inspect(error), %{}}
  end

  defp run_attrs(meta, partition, status, started_at, extra \\ %{}) do
    Map.merge(
      %{
        id: meta.run_id,
        runtime: "flowstone",
        runtime_ref: to_string(meta.run_id),
        status: status,
        plan_id: meta.plan_id,
        plan_version: meta.plan_version,
        plan_hash: meta.plan_hash,
        plan_ref: meta.plan_ref,
        trace_id: meta.trace_id,
        work_id: meta.work_id,
        session_id: meta.session_id,
        actor_type: meta.actor_type,
        actor_id: meta.actor_id,
        tenant_id: meta.tenant_id,
        inputs: %{partition: FlowStone.Partition.serialize(partition)},
        started_at: started_at
      },
      normalize_extra(extra)
    )
  end

  defp step_attrs(meta, partition, step_record_id, span_id, status, started_at, extra \\ %{}) do
    action_module =
      case meta.action_module do
        nil -> nil
        module -> inspect(module)
      end

    Map.merge(
      %{
        id: step_record_id,
        run_id: meta.run_id,
        step_id: meta.step_id,
        step_key: meta.step_key,
        action_name: meta.action_name || to_string(meta.step_key),
        action_module: action_module,
        tool_name: meta.tool_name,
        status: status,
        trace_id: meta.trace_id,
        span_id: span_id,
        work_id: meta.work_id,
        inputs: %{partition: FlowStone.Partition.serialize(partition)},
        started_at: started_at
      },
      normalize_extra(extra)
    )
  end

  defp artifact_refs(refs) do
    refs
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&LineageIR.Serialization.to_map/1)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_extra(extra) when is_map(extra), do: extra
  defp normalize_extra(extra) when is_list(extra), do: Map.new(extra)
end
