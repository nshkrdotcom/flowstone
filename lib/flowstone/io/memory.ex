defmodule FlowStone.IO.Memory do
  @moduledoc """
  In-memory I/O manager for tests and development.
  """

  use Agent
  @behaviour FlowStone.IO.Manager

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @impl true
  def load(asset, partition, config) do
    agent = resolve_agent(config)

    case Agent.get(agent, &Map.get(&1, {asset, partition})) do
      nil -> {:error, :not_found}
      data -> {:ok, data}
    end
  end

  @impl true
  def store(asset, data, partition, config) do
    config |> resolve_agent() |> Agent.update(&Map.put(&1, {asset, partition}, data))
    :ok
  end

  @impl true
  def delete(asset, partition, config) do
    config |> resolve_agent() |> Agent.update(&Map.delete(&1, {asset, partition}))
    :ok
  end

  @impl true
  def metadata(asset, partition, config) do
    with {:ok, data} <- load(asset, partition, config) do
      {:ok,
       %{
         size_bytes: :erlang.external_size(data),
         updated_at: DateTime.utc_now(),
         checksum: :erlang.phash2(data)
       }}
    end
  end

  @impl true
  def exists?(asset, partition, config) do
    config |> resolve_agent() |> Agent.get(&Map.has_key?(&1, {asset, partition}))
  end

  defp resolve_agent(config) do
    case config do
      %{agent: agent} -> agent
      %{"agent" => agent} -> agent
      _ -> __MODULE__
    end
  end
end
