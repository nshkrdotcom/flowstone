defmodule FlowStone.MaterializationContext do
  @moduledoc """
  Context functions for querying materializations from Repo or fallback store.
  """

  import Ecto.Query
  alias FlowStone.{Materialization, MaterializationStore, Repo}

  def get(asset, partition, run_id, opts \\ []) do
    if use_repo?(opts) do
      Repo.get_by(Materialization,
        asset_name: Atom.to_string(asset),
        partition: FlowStone.Partition.serialize(partition),
        run_id: run_id
      )
    else
      store = Keyword.get(opts, :store, MaterializationStore)
      MaterializationStore.get(asset, partition, run_id, store)
    end
  end

  def list(opts \\ []) do
    if use_repo?(opts) do
      Repo.all(from m in Materialization, order_by: [desc: m.inserted_at])
    else
      store = Keyword.get(opts, :store, MaterializationStore)
      MaterializationStore.list(store)
    end
  end

  def latest(asset, partition, opts \\ []) do
    asset_str = to_string(asset)
    partition_str = FlowStone.Partition.serialize(partition)

    if use_repo?(opts) do
      Repo.one(
        from m in Materialization,
          where:
            m.asset_name == ^asset_str and
              m.partition == ^partition_str,
          order_by: [desc: m.started_at, desc: m.inserted_at],
          limit: 1
      )
    else
      store = Keyword.get(opts, :store, MaterializationStore)

      store
      |> MaterializationStore.list()
      |> Enum.filter(fn entry ->
        to_string(entry.asset) == asset_str and
          FlowStone.Partition.serialize(entry.partition) == partition_str
      end)
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
      |> List.first()
    end
  end

  defp repo_running?, do: Process.whereis(Repo) != nil

  defp use_repo?(opts),
    do: Keyword.get(opts, :use_repo, true) and repo_running?()
end
