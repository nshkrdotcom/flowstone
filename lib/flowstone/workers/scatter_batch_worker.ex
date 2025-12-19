defmodule FlowStone.Workers.ScatterBatchWorker do
  @moduledoc """
  Oban worker for executing batched scatter instances.

  Each batch runs as an independent job with:
  - Batch context (batch_items, batch_input, batch_index, batch_count)
  - Barrier-based coordination
  - Configurable concurrency control
  - Rate limiting support
  - Failure threshold checking
  """

  use Oban.Worker,
    queue: :flowstone_scatter,
    max_attempts: 3

  import Ecto.Query
  alias FlowStone.{Context, Materializer, Registry, RunConfig, Scatter}
  alias FlowStone.Scatter.{Barrier, Result}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    perform(%Oban.Job{args: args}, RunConfig.get(args["run_id"]) || [])
  end

  @doc false
  def perform(%Oban.Job{args: args}, config) do
    barrier_id = args["barrier_id"]
    batch_index = args["batch_index"]
    scatter_key = args["scatter_key"]
    asset_name_str = args["asset_name"]
    run_id = args["run_id"]

    with {:ok, asset_name} <- resolve_asset_name(asset_name_str, config),
         {:ok, barrier} <- Scatter.get_barrier(barrier_id),
         {:ok, batch_result} <- get_batch_result(barrier_id, scatter_key),
         :ok <- check_rate_limit(barrier),
         {:ok, _slot} <- acquire_slot(barrier) do
      start_time = System.monotonic_time(:millisecond)

      emit_batch_telemetry(:batch_start, barrier, batch_index, batch_result)

      result =
        try do
          execute_batch(
            asset_name,
            batch_result,
            barrier,
            run_id,
            config
          )
        rescue
          e ->
            {:error, Exception.message(e)}
        end

      duration = System.monotonic_time(:millisecond) - start_time

      case result do
        {:ok, value} ->
          case Scatter.complete(barrier_id, scatter_key, value) do
            {:ok, status} when status in [:continue, :gather, :partial_failure] ->
              emit_batch_telemetry(:batch_complete, barrier, batch_index, batch_result, duration)
              maybe_trigger_downstream(barrier, status)
              :ok

            {:error, :threshold_exceeded} ->
              emit_batch_telemetry(:batch_fail, barrier, batch_index, batch_result, duration)
              :ok

            error ->
              error
          end

        {:error, reason} ->
          Scatter.fail(barrier_id, scatter_key, reason)
          emit_batch_telemetry(:batch_fail, barrier, batch_index, batch_result, duration)
          {:error, reason}
      end
    else
      {:wait, ms} ->
        {:snooze, div(ms, 1000) + 1}

      {:error, :at_capacity} ->
        {:snooze, 5}

      {:error, :not_found} ->
        {:discard, "Barrier not found"}

      {:error, :batch_not_found} ->
        {:discard, "Batch result not found"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    attempt
    |> Kernel.-(1)
    |> max(0)
    |> then(&:math.pow(3, &1))
    |> Kernel.*(5)
    |> round()
    |> min(60)
  end

  defp execute_batch(asset_name, batch_result, barrier, run_id, config) do
    registry = Keyword.get(config, :registry) || FlowStone.Registry
    resource_server = Keyword.get(config, :resource_server)

    case Registry.fetch(asset_name, server: registry) do
      {:ok, asset} ->
        context = build_batch_context(asset, batch_result, barrier, run_id, resource_server)
        deps = load_dependencies(asset, config)
        Materializer.execute(asset, context, deps)

      {:error, _} = error ->
        error
    end
  end

  defp build_batch_context(asset, batch_result, barrier, run_id, resource_server) do
    base_context = Context.build(asset, nil, run_id, resource_server: resource_server)

    batch_count = barrier.batch_count || 1
    batch_items = normalize_batch_items(batch_result.batch_items)
    batch_input = normalize_batch_input(batch_result.batch_input)

    %{
      base_context
      | scatter_key: batch_result.scatter_key,
        batch_index: batch_result.batch_index,
        batch_count: batch_count,
        batch_items: batch_items,
        batch_input: batch_input
    }
  end

  defp normalize_batch_items(nil), do: []
  defp normalize_batch_items(items) when is_list(items), do: items

  defp normalize_batch_input(nil), do: %{}
  defp normalize_batch_input(input) when is_map(input), do: input

  defp load_dependencies(asset, config) do
    io_opts = Keyword.get(config, :io_opts, [])
    deps = Map.get(asset, :depends_on, [])

    Enum.reduce(deps, %{}, fn dep, acc ->
      case FlowStone.IO.load(dep, nil, io_opts) do
        {:ok, data} -> Map.put(acc, dep, data)
        {:error, _} -> acc
      end
    end)
  end

  defp get_batch_result(barrier_id, scatter_key) do
    key_hash = Scatter.Key.hash(Scatter.Key.normalize(scatter_key))

    case FlowStone.Repo.one(
           from(r in Result,
             where: r.barrier_id == ^barrier_id and r.scatter_key_hash == ^key_hash
           )
         ) do
      nil -> {:error, :batch_not_found}
      result -> {:ok, result}
    end
  end

  defp check_rate_limit(barrier) do
    opts = Barrier.get_options(barrier)

    case opts.rate_limit do
      nil ->
        :ok

      {limit, period} ->
        bucket = "scatter_batch:#{barrier.id}"
        scale = if period == :second, do: 1_000, else: 60_000

        case Hammer.check_rate(bucket, scale, limit) do
          {:allow, _count} -> :ok
          {:deny, _limit} -> {:wait, div(scale, limit)}
        end
    end
  end

  defp acquire_slot(barrier) do
    opts = Barrier.get_options(barrier)

    case opts.max_concurrent do
      :unlimited ->
        {:ok, nil}

      max when is_integer(max) ->
        pending =
          barrier.total_count - barrier.completed_count - barrier.failed_count

        executing = min(pending, max)

        if executing < max do
          {:ok, executing + 1}
        else
          {:error, :at_capacity}
        end
    end
  end

  defp maybe_trigger_downstream(barrier, :gather) do
    :telemetry.execute(
      [:flowstone, :scatter, :gather_ready],
      %{},
      %{barrier_id: barrier.id, asset: barrier.asset_name}
    )
  end

  defp maybe_trigger_downstream(_barrier, _status), do: :ok

  defp resolve_asset_name(name_string, config) when is_binary(name_string) do
    registry = Keyword.get(config, :registry) || FlowStone.Registry

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

  defp emit_batch_telemetry(event, barrier, batch_index, batch_result, duration \\ 0) do
    item_count = length(batch_result.batch_items || [])

    :telemetry.execute(
      [:flowstone, :scatter, event],
      %{duration: duration, item_count: item_count},
      %{
        barrier_id: barrier.id,
        asset: barrier.asset_name,
        run_id: barrier.run_id,
        batch_index: batch_index
      }
    )
  end
end
