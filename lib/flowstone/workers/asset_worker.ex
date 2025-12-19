defmodule FlowStone.Workers.AssetWorker do
  @moduledoc """
  Oban worker that materializes a single asset partition.

  ## JSON Safety

  Oban persists job args as JSON. This worker expects only JSON-safe values:
  - `asset_name` - string (converted to atom via safe lookup)
  - `partition` - serialized partition string
  - `run_id` - UUID string
  - `use_repo` - boolean

  Runtime configuration (servers, IO config) is loaded from:
  1. `FlowStone.RunConfig` if the run_id entry exists
  2. Application config as fallback

  This ensures jobs that persist across restarts still work.
  """

  use Oban.Worker,
    queue: :assets,
    max_attempts: 5,
    unique: [period: 60, fields: [:args], keys: [:asset_name, :partition, :run_id]]

  alias FlowStone.{Error, Executor, Partition, Registry, RouteDecisions, RunConfig}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}), do: perform(%Oban.Job{args: args}, nil)

  @doc """
  Execute the materialization.

  Can be called with an optional run_config for synchronous execution
  (when Oban is not running and we have the config in memory).
  """
  def perform(%Oban.Job{args: args}, run_config) do
    run_id = Map.fetch!(args, "run_id")
    use_repo = Map.get(args, "use_repo", true)

    # Load runtime config from RunConfig store or use provided config
    config = run_config || RunConfig.get(run_id) || []

    # Safely resolve asset name (avoid unbounded atom creation)
    case resolve_asset_name(args["asset_name"], config) do
      {:ok, asset_name} ->
        partition = Partition.deserialize(args["partition"])
        execute_materialization(asset_name, partition, run_id, use_repo, config)

      {:error, reason} ->
        {:discard, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    attempt
    |> Kernel.-(1)
    |> max(0)
    |> then(&:math.pow(3, &1))
    |> Kernel.*(30)
    |> round()
    |> min(300)
  end

  # Resolve asset name string to atom safely.
  # Only converts to atom if the asset is registered in the registry.
  defp resolve_asset_name(name_string, config) when is_binary(name_string) do
    registry = Keyword.get(config, :registry) || get_registry_from_config()

    # First try to convert using existing atom (fast path for known assets)
    case safe_to_existing_atom(name_string) do
      {:ok, atom} ->
        # Verify it's a registered asset
        case Registry.fetch(atom, server: registry) do
          {:ok, _} -> {:ok, atom}
          _ -> {:error, "Asset not found: #{name_string}"}
        end

      :error ->
        # Asset name not an existing atom - could be first time or invalid
        # Search registry by string name
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

  defp get_registry_from_config do
    Application.get_env(:flowstone, :registry, FlowStone.Registry)
  end

  defp execute_materialization(asset_name, partition, run_id, use_repo, config) do
    registry = Keyword.get(config, :registry) || get_registry_from_config()
    io_opts = build_io_opts(config)

    case check_dependencies(asset_name, partition, run_id, registry, io_opts) do
      :ok ->
        # Build executor options, only including non-nil values
        exec_opts =
          [
            partition: partition,
            registry: registry,
            io: io_opts,
            use_repo: use_repo,
            run_id: run_id
          ]
          |> maybe_add_opt(:resource_server, Keyword.get(config, :resource_server))
          |> maybe_add_opt(:lineage_server, Keyword.get(config, :lineage_server))
          |> maybe_add_opt(:materialization_store, Keyword.get(config, :materialization_store))

        case Executor.materialize(asset_name, exec_opts) do
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

  # Only add option if value is not nil (prevents nil overriding defaults)
  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp build_io_opts(config) do
    # Prefer original io_opts (for synchronous execution with full runtime values)
    # Fall back to io_config (for async execution after JSON round-trip)
    case Keyword.get(config, :io_opts) do
      opts when is_list(opts) and opts != [] ->
        opts

      _ ->
        # Fall back to io_config (JSON-safe format)
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

  # Convert string keys back to atoms for IO config
  # (only for known safe keys)
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

  defp check_dependencies(asset_name, partition, run_id, registry, io_opts) do
    case Registry.fetch(asset_name, server: registry) do
      {:ok, asset} ->
        optional = Map.get(asset, :optional_deps, [])

        missing =
          Enum.reject(asset.depends_on, fn dep ->
            dep in optional or FlowStone.IO.exists?(dep, partition, io_opts)
          end)

        cond do
          missing != [] ->
            {:snooze, 30}

          Map.get(asset, :routed_from) &&
              RouteDecisions.get(run_id, asset.routed_from, partition) == {:error, :not_found} ->
            {:snooze, 30}

          true ->
            :ok
        end

      _ ->
        {:snooze, 30}
    end
  end
end
