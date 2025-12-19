defmodule FlowStone.Repo.Migrations.AddItemBatcherFields do
  use Ecto.Migration

  def change do
    alter table(:flowstone_scatter_barriers) do
      add :batching_enabled, :boolean, default: false
      add :batch_count, :integer
      add :batch_options, :jsonb
    end

    alter table(:flowstone_scatter_results) do
      add :batch_index, :integer
      add :batch_items, {:array, :map}
      add :batch_input, :map
    end

    create index(:flowstone_scatter_results, [:batch_index])
  end
end
