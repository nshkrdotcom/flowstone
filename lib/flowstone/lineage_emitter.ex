defmodule FlowStone.LineageEmitter do
  @moduledoc false

  require Logger

  alias LineageIR.{Artifact, ArtifactRef, Event, Span, Trace}

  @default_source "flowstone"

  @spec start_span(FlowStone.Asset.t(), FlowStone.Context.t(), map(), keyword()) ::
          {:ok, String.t() | nil}
  def start_span(asset, context, meta, opts \\ []) do
    if enabled?(opts) do
      trace_id = meta.trace_id || context.run_id
      run_id = meta.run_id || context.run_id
      work_id = meta.work_id
      plan_id = meta.plan_id

      _ = emit_trace(trace_id, run_id, work_id, plan_id, opts)

      span_id = Ecto.UUID.generate()
      started_at = context.started_at || utc_now()

      span = %Span{
        id: span_id,
        trace_id: trace_id,
        run_id: run_id,
        step_id: meta.step_id,
        work_id: work_id,
        name: span_name(asset, meta),
        kind: "asset",
        status: "running",
        attributes: span_attributes(asset, context, meta),
        started_at: started_at
      }

      emit_event(
        %Event{
          id: Ecto.UUID.generate(),
          type: "span_start",
          trace_id: trace_id,
          span_id: span_id,
          run_id: run_id,
          step_id: meta.step_id,
          work_id: work_id,
          plan_id: plan_id,
          source: @default_source,
          source_ref: run_id,
          payload: span
        },
        opts
      )

      {:ok, span_id}
    else
      {:ok, nil}
    end
  end

  @spec finish_span(
          FlowStone.Asset.t(),
          FlowStone.Context.t(),
          map(),
          String.t() | nil,
          String.t(),
          term(),
          keyword()
        ) :: :ok
  def finish_span(_asset, _context, _meta, nil, _status, _error, _opts), do: :ok

  def finish_span(asset, context, meta, span_id, status, error, opts) do
    if enabled?(opts) do
      trace_id = meta.trace_id || context.run_id
      run_id = meta.run_id || context.run_id
      work_id = meta.work_id

      {error_type, error_message, error_details} = error_fields(error)

      span = %Span{
        id: span_id,
        trace_id: trace_id,
        run_id: run_id,
        step_id: meta.step_id,
        work_id: work_id,
        name: span_name(asset, meta),
        kind: "asset",
        status: status,
        attributes: span_attributes(asset, context, meta),
        error_type: error_type,
        error_message: error_message,
        error_details: error_details,
        started_at: context.started_at,
        finished_at: utc_now()
      }

      emit_event(
        %Event{
          id: Ecto.UUID.generate(),
          type: "span_end",
          trace_id: trace_id,
          span_id: span_id,
          run_id: run_id,
          step_id: meta.step_id,
          work_id: work_id,
          plan_id: meta.plan_id,
          source: @default_source,
          source_ref: run_id,
          payload: span
        },
        opts
      )
    else
      :ok
    end
  end

  @spec emit_artifact(
          FlowStone.Asset.t(),
          FlowStone.Context.t(),
          map(),
          String.t() | nil,
          term(),
          keyword(),
          keyword()
        ) :: {:ok, ArtifactRef.t() | nil}
  def emit_artifact(_asset, _context, _meta, nil, _result, _io_opts, _opts),
    do: {:ok, nil}

  def emit_artifact(asset, context, meta, span_id, result, io_opts, opts) do
    if enabled?(opts) do
      trace_id = meta.trace_id || context.run_id
      run_id = meta.run_id || context.run_id
      artifact_id = Ecto.UUID.generate()

      {size_bytes, checksum, metadata} = artifact_metadata(asset, context, result, io_opts)

      artifact = %Artifact{
        id: artifact_id,
        trace_id: trace_id,
        span_id: span_id,
        run_id: run_id,
        step_id: meta.step_id,
        type: "flowstone.asset",
        uri: metadata[:uri],
        checksum: checksum,
        size_bytes: size_bytes,
        mime_type: metadata[:mime_type],
        metadata: metadata,
        created_at: utc_now()
      }

      emit_event(
        %Event{
          id: Ecto.UUID.generate(),
          type: "artifact",
          trace_id: trace_id,
          span_id: span_id,
          run_id: run_id,
          step_id: meta.step_id,
          plan_id: meta.plan_id,
          source: @default_source,
          source_ref: run_id,
          payload: artifact
        },
        opts
      )

      ref = %ArtifactRef{
        artifact_id: artifact_id,
        type: artifact.type,
        uri: artifact.uri,
        checksum: artifact.checksum,
        metadata: artifact.metadata
      }

      {:ok, ref}
    else
      {:ok, nil}
    end
  end

  defp emit_trace(trace_id, run_id, work_id, plan_id, opts) do
    trace = %Trace{
      id: trace_id,
      root_trace_id: trace_id,
      run_id: run_id,
      work_id: work_id,
      origin: @default_source,
      origin_ref: run_id,
      status: "running",
      attributes: trace_attributes(plan_id),
      started_at: utc_now()
    }

    emit_event(
      %Event{
        id: Ecto.UUID.generate(),
        type: "trace_start",
        trace_id: trace_id,
        run_id: run_id,
        work_id: work_id,
        plan_id: plan_id,
        source: @default_source,
        source_ref: run_id,
        payload: trace
      },
      opts
    )
  end

  defp enabled?(opts) do
    Keyword.get(opts, :lineage_ir, Application.get_env(:flowstone, :lineage_ir, true)) and
      Code.ensure_loaded?(LineageIR.Sink)
  end

  defp emit_event(event, opts) do
    sink_opts = Keyword.get(opts, :lineage_opts, [])

    case LineageIR.Sink.emit(event, sink_opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("FlowStone lineage emit failed: #{inspect(reason)}")
        :ok
    end
  end

  defp span_name(asset, meta) do
    Map.get(meta, :action_name) || to_string(asset.name)
  end

  defp span_attributes(asset, context, meta) do
    action_module =
      case meta.action_module do
        nil -> nil
        module -> inspect(module)
      end

    %{
      "asset" => to_string(asset.name),
      "partition" => FlowStone.Partition.serialize(context.partition),
      "action_module" => action_module,
      "step_key" => to_string(meta.step_key),
      "plan_id" => meta.plan_id
    }
  end

  defp trace_attributes(nil), do: %{}
  defp trace_attributes(plan_id), do: %{"plan_id" => plan_id}

  defp artifact_metadata(asset, context, result, io_opts) do
    metadata =
      case FlowStone.IO.metadata(asset.name, context.partition, io_opts) do
        {:ok, data} -> data
        _ -> %{}
      end

    size_bytes =
      Map.get(metadata, :size_bytes) ||
        Map.get(metadata, "size_bytes") ||
        :erlang.external_size(result)

    checksum =
      Map.get(metadata, :checksum) ||
        Map.get(metadata, "checksum") ||
        :erlang.phash2(result)

    metadata =
      metadata
      |> Map.put_new(:asset, asset.name)
      |> Map.put_new(:partition, FlowStone.Partition.serialize(context.partition))
      |> Map.put_new(:io_manager, io_manager_name(io_opts))

    {size_bytes, checksum, metadata}
  end

  defp io_manager_name(io_opts) do
    io_opts
    |> Keyword.get(:io_manager)
    |> case do
      nil -> Application.get_env(:flowstone, :default_io_manager, :memory)
      manager -> manager
    end
    |> to_string()
  end

  defp error_fields(nil), do: {nil, nil, nil}

  defp error_fields(%FlowStone.Error{} = error) do
    {
      to_string(error.type),
      error.message,
      error.context
    }
  end

  defp error_fields(%_{} = error) do
    {error.__struct__ |> Module.split() |> List.last(), Exception.message(error), %{}}
  end

  defp error_fields(error) do
    {"error", inspect(error), %{}}
  end

  defp utc_now do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end
end
