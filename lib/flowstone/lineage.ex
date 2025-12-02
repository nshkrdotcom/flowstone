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
          partition: to_string(partition),
          run_id: run_id,
          upstream_asset: Atom.to_string(dep),
          upstream_partition: to_string(dep_partition),
          consumed_at: DateTime.utc_now()
        }
      end)

    GenServer.cast(server, {:record, records})
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
  def handle_cast({:record, records}, state) do
    {:noreply, %{state | entries: records ++ state.entries}}
  end

  @impl true
  def handle_call({:upstream, asset, partition}, _from, state) do
    upstream =
      state.entries
      |> Enum.filter(
        &(&1.asset_name == Atom.to_string(asset) and &1.partition == to_string(partition))
      )
      |> Enum.map(&%{asset: String.to_atom(&1.upstream_asset), partition: &1.upstream_partition})

    {:reply, upstream, state}
  end

  def handle_call({:downstream, asset, partition}, _from, state) do
    downstream =
      state.entries
      |> Enum.filter(
        &(&1.upstream_asset == Atom.to_string(asset) and
            &1.upstream_partition == to_string(partition))
      )
      |> Enum.map(&%{asset: String.to_atom(&1.asset_name), partition: &1.partition})

    {:reply, downstream, state}
  end
end
