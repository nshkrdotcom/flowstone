defmodule FlowStone.Lineage do
  @moduledoc """
  In-memory lineage recorder and query API.
  """

  use GenServer
  alias FlowStone.Lineage.Entry

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  def record(asset, partition, run_id, deps, server \\ __MODULE__) do
    records =
      Enum.map(deps, fn {dep, dep_partition} ->
        %Entry{
          asset_name: Atom.to_string(asset),
          partition: FlowStone.Partition.serialize(partition),
          run_id: run_id,
          upstream_asset: Atom.to_string(dep),
          upstream_partition: FlowStone.Partition.serialize(dep_partition),
          consumed_at: DateTime.utc_now()
        }
      end)

    GenServer.call(server, {:record, records})
  end

  def upstream(asset, partition, server \\ __MODULE__) do
    GenServer.call(server, {:upstream, asset, partition})
  end

  def downstream(asset, partition, server \\ __MODULE__) do
    GenServer.call(server, {:downstream, asset, partition})
  end

  ## Server
  @impl true
  def init(:ok) do
    {:ok, %{entries: []}}
  end

  @impl true
  def handle_call({:upstream, asset, partition}, _from, state) do
    upstream =
      state.entries
      |> Enum.filter(
        &(&1.asset_name == Atom.to_string(asset) and
            &1.partition == FlowStone.Partition.serialize(partition))
      )
      |> Enum.map(&%{asset: safe_to_atom(&1.upstream_asset), partition: &1.upstream_partition})

    {:reply, upstream, state}
  end

  def handle_call({:downstream, asset, partition}, _from, state) do
    downstream =
      state.entries
      |> Enum.filter(
        &(&1.upstream_asset == Atom.to_string(asset) and
            &1.upstream_partition == FlowStone.Partition.serialize(partition))
      )
      |> Enum.map(&%{asset: safe_to_atom(&1.asset_name), partition: &1.partition})

    {:reply, downstream, state}
  end

  def handle_call({:record, records}, _from, state) do
    {:reply, :ok, %{state | entries: records ++ state.entries}}
  end

  # Safely convert string to atom - only if atom already exists
  # Returns the string as-is if not an existing atom
  defp safe_to_atom(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> string
  end

  defp safe_to_atom(atom) when is_atom(atom), do: atom
  defp safe_to_atom(other), do: other
end
