defmodule FlowStone.Resources do
  @moduledoc """
  Manages configured resources and exposes them to asset execution.
  """

  use GenServer

  ## Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.delete(opts, :name), name: name)
  end

  @doc """
  Get a single resource by name.
  """
  def get(name, server \\ __MODULE__) do
    GenServer.call(server, {:get, name})
  end

  @doc """
  Return all loaded resources.
  """
  def load(server \\ __MODULE__) do
    GenServer.call(server, :all)
  end

  @doc """
  Override current resources (useful for tests).
  """
  def override(map, server \\ __MODULE__) when is_map(map) do
    GenServer.cast(server, {:override, map})
  end

  ## Server callbacks

  @impl true
  def init(opts) do
    resources_cfg =
      opts
      |> Keyword.get(:resources, Application.get_env(:flowstone, :resources, %{}))

    resources =
      resources_cfg
      |> Enum.reduce(%{}, fn {name, {module, config}}, acc ->
        config = normalize_config(config)

        case module.setup(config) do
          {:ok, resource} ->
            Map.put(acc, name, %{resource: resource, module: module})

          {:error, reason} ->
            raise "Failed to setup resource #{inspect(name)}: #{inspect(reason)}"
        end
      end)

    {:ok, %{resources: resources}}
  end

  @impl true
  def handle_call({:get, name}, _from, %{resources: resources} = state) do
    case Map.get(resources, name) do
      nil -> {:reply, {:error, :not_found}, state}
      %{resource: resource} -> {:reply, {:ok, resource}, state}
    end
  end

  @impl true
  def handle_call(:all, _from, %{resources: resources} = state) do
    {:reply, Enum.into(resources, %{}, fn {k, %{resource: r}} -> {k, r} end), state}
  end

  @impl true
  def handle_cast({:override, map}, _state) do
    {:noreply,
     %{resources: Enum.into(map, %{}, fn {k, r} -> {k, %{resource: r, module: nil}} end)}}
  end

  defp normalize_config(config) when is_map(config) do
    Enum.reduce(config, %{}, fn
      {key, {:system, env_var}}, acc -> Map.put(acc, key, System.get_env(env_var))
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end
end
