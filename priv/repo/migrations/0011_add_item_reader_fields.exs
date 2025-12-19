defmodule FlowStone.Repo.Migrations.AddItemReaderFields do
  use Ecto.Migration

  def change do
    drop_if_exists index(:flowstone_scatter_barriers, [:run_id, :asset_name, :partition],
                     name: :scatter_barriers_run_asset_partition_idx
                   )

    alter table(:flowstone_scatter_barriers) do
      add :mode, :string, default: "inline", null: false
      add :reader_checkpoint, :jsonb
      add :parent_barrier_id, references(:flowstone_scatter_barriers, type: :uuid)
      add :batch_index, :integer
    end

    create index(:flowstone_scatter_barriers, [:parent_barrier_id])
  end
end
