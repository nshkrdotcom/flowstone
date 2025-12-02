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

    resource_server =
      Keyword.get(
        opts,
        :resource_server,
        Application.get_env(:flowstone, :resources_server, FlowStone.Resources)
      )

    run_id = Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0)

    with {:ok, asset} <- Registry.fetch(asset_name, server: registry),
         {:ok, deps} <- load_dependencies(asset, partition, io_opts),
         context <- Context.build(asset, partition, run_id, resource_server: resource_server),
         {:ok, result} <- Materializer.execute(asset, context, deps),
         :ok <- FlowStone.IO.store(asset.name, result, partition, io_opts) do
      {:ok, result}
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
end
