defmodule FlowStone.IO.Memory do
  @moduledoc """
  In-memory I/O manager for tests and development.

  Keys are normalized to ensure consistent lookups regardless of partition format
  (atoms, strings, dates all serialize to the same canonical form).
  """

  use Agent
  @behaviour FlowStone.IO.Manager
  alias FlowStone.Partition

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @impl true
  def load(asset, partition, config) do
    agent = resolve_agent(config)
    key = normalize_key(asset, partition)

    case Agent.get(agent, &Map.get(&1, key)) do
      nil -> {:error, :not_found}
      data -> {:ok, data}
    end
  end

  @impl true
  def store(asset, data, partition, config) do
    agent = resolve_agent(config)
    key = normalize_key(asset, partition)
    Agent.update(agent, &Map.put(&1, key, data))
    :ok
  end

  @impl true
  def delete(asset, partition, config) do
    agent = resolve_agent(config)
    key = normalize_key(asset, partition)
    Agent.update(agent, &Map.delete(&1, key))
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
    agent = resolve_agent(config)
    key = normalize_key(asset, partition)
    Agent.get(agent, &Map.has_key?(&1, key))
  end

  # Normalize keys to ensure consistent lookups regardless of partition format
  defp normalize_key(asset, partition) do
    asset_str = to_string(asset)
    partition_str = Partition.serialize(partition)
    {asset_str, partition_str}
  end

  defp resolve_agent(config) do
    case config do
      %{agent: agent} -> agent
      %{"agent" => agent} -> agent
      _ -> __MODULE__
    end
  end
end
