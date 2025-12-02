defmodule FlowStone.MaterializationContext do
  @moduledoc """
  Context functions for querying materializations from Repo or fallback store.
  """

  import Ecto.Query
  alias FlowStone.{Materialization, MaterializationStore, Repo}

  def get(asset, partition, run_id, opts \\ []) do
    if repo_running?() do
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
    if repo_running?() do
      Repo.all(from m in Materialization, order_by: [desc: m.inserted_at])
    else
      store = Keyword.get(opts, :store, MaterializationStore)
      MaterializationStore.list(store)
    end
  end

  defp repo_running?, do: Process.whereis(Repo) != nil
end
