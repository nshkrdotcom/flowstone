defmodule FlowStone.Registry do
  @moduledoc """
  In-memory registry for asset definitions.

  The registry stores asset definitions keyed by name. It uses an Agent for
  simple state management.

  ## Usage

      # Start a named registry
      {:ok, _pid} = FlowStone.Registry.start_link(name: MyRegistry)

      # Register assets from a pipeline
      FlowStone.Registry.register_assets(assets, server: MyRegistry)

      # Fetch a specific asset
      {:ok, asset} = FlowStone.Registry.fetch(:my_asset, server: MyRegistry)

  """

  use Agent

  alias FlowStone.Asset

  @type server :: GenServer.server()

  @doc """
  Start a new registry.

  ## Options

    * `:name` - The name to register the agent under (default: `FlowStone.Registry`)

  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @doc """
  Register a list of assets.

  ## Options

    * `:server` - The registry server (default: `FlowStone.Registry`)

  """
  @spec register_assets([Asset.t()], keyword()) :: :ok
  def register_assets(assets, opts \\ []) when is_list(assets) do
    server = Keyword.get(opts, :server, __MODULE__)

    Agent.update(server, fn state ->
      Enum.reduce(assets, state, fn asset, acc -> Map.put(acc, asset.name, asset) end)
    end)
  end

  @doc """
  Fetch an asset by name.

  ## Options

    * `:server` - The registry server (default: `FlowStone.Registry`)

  ## Returns

    * `{:ok, asset}` if found
    * `{:error, :not_found}` if not found

  """
  @spec fetch(atom(), keyword()) :: {:ok, Asset.t()} | {:error, :not_found}
  def fetch(name, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)

    case Agent.get(server, &Map.get(&1, name)) do
      nil -> {:error, :not_found}
      asset -> {:ok, asset}
    end
  end

  @doc """
  Fetch an asset by name, raising if not found.

  ## Options

    * `:server` - The registry server (default: `FlowStone.Registry`)

  ## Raises

    * `ArgumentError` if the asset is not found

  """
  @spec fetch!(atom(), keyword()) :: Asset.t()
  def fetch!(name, opts \\ []) do
    case fetch(name, opts) do
      {:ok, asset} -> asset
      {:error, :not_found} -> raise ArgumentError, "asset #{inspect(name)} not found"
    end
  end

  @doc """
  List all registered assets.

  ## Options

    * `:server` - The registry server (default: `FlowStone.Registry`)

  """
  @spec list(keyword()) :: [Asset.t()]
  def list(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    Agent.get(server, &Map.values/1)
  end
end
