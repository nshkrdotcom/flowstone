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
    if use_repo?(opts) do
      Repo.one(
        from m in Materialization,
          where:
            m.asset_name == ^Atom.to_string(asset) and
              m.partition == ^FlowStone.Partition.serialize(partition),
          order_by: [desc: m.inserted_at],
          limit: 1
      )
    else
      store = Keyword.get(opts, :store, MaterializationStore)

      store
      |> MaterializationStore.list()
      |> Enum.filter(&(&1.asset == asset and &1.partition == partition))
      |> List.last()
    end
  end

  defp repo_running?, do: Process.whereis(Repo) != nil

  defp use_repo?(opts),
    do: Keyword.get(opts, :use_repo, true) and repo_running?()
end
