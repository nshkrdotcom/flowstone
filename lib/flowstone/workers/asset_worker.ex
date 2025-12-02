defmodule FlowStone.Workers.AssetWorker do
  @moduledoc """
  Oban worker that materializes a single asset partition.
  """

  use Oban.Worker,
    queue: :assets,
    max_attempts: 5,
    unique: [period: 60, fields: [:args]]

  alias FlowStone.{Error, Executor, Registry}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    asset_name = args["asset_name"] |> String.to_atom()
    partition = args["partition"]
    registry = Map.get(args, "registry", FlowStone.Registry)
    io_opts = Map.get(args, "io", [])
    resource_server = Map.get(args, "resource_server")
    lineage_server = Map.get(args, "lineage_server")
    materialization_store = Map.get(args, "materialization_store")
    run_id = Map.get(args, "run_id", Ecto.UUID.generate())
    use_repo = Map.get(args, "use_repo", true)

    case check_dependencies(asset_name, partition, registry, io_opts) do
      :ok ->
        case Executor.materialize(asset_name,
               partition: partition,
               registry: registry,
               io: io_opts,
               resource_server: resource_server,
               lineage_server: lineage_server,
               materialization_store: materialization_store,
               use_repo: use_repo,
               run_id: run_id
             ) do
          {:ok, _} ->
            :ok

          {:error, %Error{retryable: true} = err} ->
            err

          {:error, %Error{retryable: false} = err} ->
            {:discard, err.message}

          other ->
            other
        end

      {:snooze, seconds} ->
        {:snooze, seconds}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    trunc(:math.pow(2, attempt)) |> max(5) |> min(300)
  end

  defp check_dependencies(asset_name, partition, registry, io_opts) do
    with {:ok, asset} <- Registry.fetch(asset_name, server: registry) do
      missing =
        asset.depends_on
        |> Enum.reject(&FlowStone.IO.exists?(&1, partition, io_opts))

      case missing do
        [] -> :ok
        _ -> {:snooze, 30}
      end
    else
      _ -> {:snooze, 30}
    end
  end
end
