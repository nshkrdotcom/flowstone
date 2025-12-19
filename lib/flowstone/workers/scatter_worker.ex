defmodule FlowStone.Workers.ScatterWorker do
  @moduledoc """
  Oban worker for executing scattered asset instances.

  Each scattered instance runs as an independent job with:
  - Barrier-based coordination
  - Configurable concurrency control
  - Rate limiting support
  - Failure threshold checking
  """

  use Oban.Worker,
    queue: :flowstone_scatter,
    max_attempts: 3

  alias FlowStone.{Context, Materializer, Registry, RunConfig, Scatter}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    barrier_id = args["barrier_id"]
    scatter_key = args["scatter_key"]
    asset_name_str = args["asset_name"]
    run_id = args["run_id"]

    config = RunConfig.get(run_id) || []

    with {:ok, asset_name} <- resolve_asset_name(asset_name_str, config),
         {:ok, barrier} <- Scatter.get_barrier(barrier_id),
         :ok <- check_rate_limit(barrier),
         {:ok, _slot} <- acquire_slot(barrier) do
      start_time = System.monotonic_time(:millisecond)

      result =
        try do
          execute_scattered_instance(asset_name, scatter_key, run_id, config)
        rescue
          e ->
            {:error, Exception.message(e)}
        end

      duration = System.monotonic_time(:millisecond) - start_time

      case result do
        {:ok, value} ->
          case Scatter.complete(barrier_id, scatter_key, value) do
            {:ok, status} when status in [:continue, :gather, :partial_failure] ->
              maybe_trigger_downstream(barrier, status)
              :ok

            {:error, :threshold_exceeded} ->
              # Barrier failed due to too many errors
              :ok

            error ->
              error
          end

        {:error, reason} ->
          Scatter.fail(barrier_id, scatter_key, reason)
          emit_telemetry(:instance_error, asset_name, scatter_key, duration, reason)
          {:error, reason}
      end
    else
      {:wait, ms} ->
        # Rate limited - snooze and retry
        {:snooze, div(ms, 1000) + 1}

      {:error, :at_capacity} ->
        # Concurrency limited - snooze and retry
        {:snooze, 5}

      {:error, :not_found} ->
        # Barrier was cancelled or doesn't exist
        {:discard, "Barrier not found"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # Exponential backoff: 5s, 15s, 45s, capped at 60s
    attempt
    |> Kernel.-(1)
    |> max(0)
    |> then(&:math.pow(3, &1))
    |> Kernel.*(5)
    |> round()
    |> min(60)
  end

  defp execute_scattered_instance(asset_name, scatter_key, run_id, config) do
    registry = Keyword.get(config, :registry) || FlowStone.Registry
    io_opts = Keyword.get(config, :io_opts, [])
    resource_server = Keyword.get(config, :resource_server)

    case Registry.fetch(asset_name, server: registry) do
      {:ok, asset} ->
        # Build context with scatter_key
        context =
          Context.build(asset, nil, run_id, resource_server: resource_server)
          |> Map.put(:scatter_key, scatter_key)

        # Load dependencies (for non-scattered execution context)
        deps = load_dependencies(asset, scatter_key, io_opts)

        # Execute the asset
        Materializer.execute(asset, context, deps)

      {:error, _} = error ->
        error
    end
  end

  defp load_dependencies(asset, _scatter_key, io_opts) do
    # For scattered instances, dependencies are loaded from the scatter source
    # The scatter_key contains the specific context for this instance
    deps = Map.get(asset, :depends_on, [])

    Enum.reduce(deps, %{}, fn dep, acc ->
      case FlowStone.IO.load(dep, nil, io_opts) do
        {:ok, data} -> Map.put(acc, dep, data)
        {:error, _} -> acc
      end
    end)
  end

  defp check_rate_limit(barrier) do
    opts = Scatter.Barrier.get_options(barrier)

    case opts.rate_limit do
      nil ->
        :ok

      {limit, period} ->
        # Use Hammer for rate limiting
        bucket = "scatter:#{barrier.id}"
        scale = if period == :second, do: 1_000, else: 60_000

        case Hammer.check_rate(bucket, scale, limit) do
          {:allow, _count} -> :ok
          {:deny, _limit} -> {:wait, div(scale, limit)}
        end
    end
  end

  defp acquire_slot(barrier) do
    opts = Scatter.Barrier.get_options(barrier)

    case opts.max_concurrent do
      :unlimited ->
        {:ok, nil}

      max when is_integer(max) ->
        # Simple slot acquisition using barrier counts
        # In production, could use Postgres advisory locks
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
    # Trigger downstream assets when scatter completes
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

  defp emit_telemetry(event, asset, scatter_key, duration, error) do
    :telemetry.execute(
      [:flowstone, :scatter, event],
      %{duration: duration},
      %{asset: asset, scatter_key: scatter_key, error: error}
    )
  end
end
