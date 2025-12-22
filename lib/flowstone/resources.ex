defmodule FlowStone.Resources do
  @moduledoc """
  Manages configured resources and exposes them to asset execution.

  ## Resilient Startup

  Resource setup failures are handled gracefully - the server continues to start
  even if some resources fail to initialize. Failed resources are tracked and
  can be queried via `list_failed/1`.

  When a resource fails to set up:
  - The server continues starting with remaining resources
  - Telemetry event `[:flowstone, :resources, :setup_failed]` is emitted
  - `get/2` returns `{:error, {:setup_failed, reason}}` for failed resources
  - `list_failed/1` returns details about all failed resources

  ## Example

      # Even if some resources fail, the server starts
      {:ok, pid} = FlowStone.Resources.start_link(
        resources: %{
          database: {DatabaseResource, %{host: "localhost"}},
          cache: {CacheResource, %{host: "unavailable-host"}}
        }
      )

      # Working resources are available
      {:ok, db} = FlowStone.Resources.get(:database)

      # Failed resources return the failure reason
      {:error, {:setup_failed, :connection_refused}} = FlowStone.Resources.get(:cache)

      # Query all failures
      [%{name: :cache, reason: :connection_refused}] = FlowStone.Resources.list_failed()
  """

  use GenServer

  ## Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.delete(opts, :name), name: name)
  end

  @doc """
  Get a single resource by name.

  Returns:
  - `{:ok, resource}` if the resource is available
  - `{:error, :not_found}` if the resource was not configured
  - `{:error, {:setup_failed, reason}}` if the resource failed during setup
  """
  @spec get(atom(), GenServer.server()) :: {:ok, term()} | {:error, term()}
  def get(name, server \\ __MODULE__) do
    GenServer.call(server, {:get, name})
  end

  @doc """
  Return all successfully loaded resources.

  Resources that failed to set up are not included.
  """
  @spec load(GenServer.server()) :: map()
  def load(server \\ __MODULE__) do
    GenServer.call(server, :all)
  end

  @doc """
  Override current resources (useful for tests).

  This is a synchronous operation that waits for confirmation.
  """
  @spec override(map(), GenServer.server()) :: :ok
  def override(map, server \\ __MODULE__) when is_map(map) do
    GenServer.call(server, {:override, map})
  end

  @doc """
  List resources that failed to set up.

  Returns a list of maps with `:name`, `:reason`, and `:module` keys.
  """
  @spec list_failed(GenServer.server()) :: [%{name: atom(), reason: term(), module: module()}]
  def list_failed(server \\ __MODULE__) do
    GenServer.call(server, :list_failed)
  end

  ## Server callbacks

  @impl true
  def init(opts) do
    resources_cfg =
      opts
      |> Keyword.get(:resources, Application.get_env(:flowstone, :resources, %{}))

    {resources, failed} =
      resources_cfg
      |> Enum.reduce({%{}, []}, fn {name, {module, config}}, {acc, failures} ->
        config = normalize_config(config)

        case safe_setup(module, config) do
          {:ok, resource} ->
            {Map.put(acc, name, %{resource: resource, module: module, status: :ok}), failures}

          {:error, reason} ->
            :telemetry.execute(
              [:flowstone, :resources, :setup_failed],
              %{},
              %{name: name, module: module, reason: reason}
            )

            failure = %{name: name, module: module, reason: reason}
            entry = %{resource: nil, module: module, status: :failed, reason: reason}
            {Map.put(acc, name, entry), [failure | failures]}
        end
      end)

    {:ok, %{resources: resources, failed: failed}}
  end

  # Safely call the setup function, catching any exceptions
  defp safe_setup(module, config) do
    module.setup(config)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @impl true
  def handle_call({:get, name}, _from, %{resources: resources} = state) do
    reply =
      case Map.get(resources, name) do
        nil ->
          {:error, :not_found}

        %{status: :failed, reason: reason} ->
          {:error, {:setup_failed, reason}}

        %{resource: resource} ->
          {:ok, resource}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:all, _from, %{resources: resources} = state) do
    working =
      resources
      |> Enum.filter(fn {_k, v} -> v.status == :ok end)
      |> Enum.into(%{}, fn {k, %{resource: r}} -> {k, r} end)

    {:reply, working, state}
  end

  @impl true
  def handle_call(:list_failed, _from, %{failed: failed} = state) do
    {:reply, failed, state}
  end

  @impl true
  def handle_call({:override, map}, _from, _state) do
    resources =
      Enum.into(map, %{}, fn {k, r} -> {k, %{resource: r, module: nil, status: :ok}} end)

    {:reply, :ok, %{resources: resources, failed: []}}
  end

  defp normalize_config(config) when is_map(config) do
    Enum.reduce(config, %{}, fn
      {key, {:system, env_var}}, acc -> Map.put(acc, key, System.get_env(env_var))
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end
end
