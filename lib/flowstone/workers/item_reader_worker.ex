defmodule FlowStone.Workers.ItemReaderWorker do
  @moduledoc """
  Oban worker that runs distributed ItemReader scans.
  """

  use Oban.Worker,
    queue: :flowstone_scatter,
    max_attempts: 3

  alias FlowStone.{Partition, Registry, RunConfig, Scatter}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}), do: perform(%Oban.Job{args: args}, nil)

  @doc """
  Execute a distributed ItemReader scan.

  Accepts optional run_config for synchronous execution in tests.
  """
  def perform(%Oban.Job{args: args}, run_config) do
    run_id = args["run_id"]
    barrier_id = args["barrier_id"]
    asset_name_str = args["asset_name"]
    partition = Partition.deserialize(args["partition"])

    config = run_config || RunConfig.get(run_id) || []
    registry = Keyword.get(config, :registry) || FlowStone.Registry
    io_opts = build_io_opts(config)

    with {:ok, asset_name} <- resolve_asset_name(asset_name_str, registry),
         {:ok, asset} <- Registry.fetch(asset_name, server: registry) do
      deps = load_dependencies(asset, partition, io_opts)

      case Scatter.run_distributed_reader(asset, deps,
             run_id: run_id,
             partition: partition,
             barrier_id: barrier_id
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:discard, reason}
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
        case find_asset_by_string_name(name_string, registry) do
          {:ok, atom} -> {:ok, atom}
          :error -> {:error, "Unknown asset: #{name_string}"}
        end
    end
  end

  defp safe_to_existing_atom(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> :error
  end

  defp find_asset_by_string_name(name_string, registry) do
    assets = Registry.list(server: registry)

    case Enum.find(assets, fn asset -> to_string(asset.name) == name_string end) do
      nil -> :error
      asset -> {:ok, asset.name}
    end
  end

  defp load_dependencies(asset, partition, io_opts) do
    deps = Map.get(asset, :depends_on, [])

    Enum.reduce(deps, %{}, fn dep, acc ->
      case FlowStone.IO.load(dep, partition, io_opts) do
        {:ok, data} -> Map.put(acc, dep, data)
        {:error, _} -> acc
      end
    end)
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

  defp resolve_io_manager(manager_string) when is_binary(manager_string) do
    case safe_to_existing_atom(manager_string) do
      {:ok, mod} -> mod
      :error -> nil
    end
  end

  defp resolve_io_manager(other), do: other

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
end
