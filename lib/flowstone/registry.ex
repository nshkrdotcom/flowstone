defmodule FlowStone.Registry do
  @moduledoc """
  In-memory registry for asset definitions.
  """

  use Agent

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{} end, name: name)
  end

  def register_assets(assets, opts \\ []) when is_list(assets) do
    server = Keyword.get(opts, :server, __MODULE__)

    Agent.update(server, fn state ->
      Enum.reduce(assets, state, fn asset, acc -> Map.put(acc, asset.name, asset) end)
    end)
  end

  def fetch(name, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)

    case Agent.get(server, &Map.get(&1, name)) do
      nil -> {:error, :not_found}
      asset -> {:ok, asset}
    end
  end

  def list(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    Agent.get(server, &Map.values/1)
  end
end
