defmodule FlowStone.Repo.Migrations.CreateMaterializations do
  use Ecto.Migration

  def change do
    create table(:flowstone_materializations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :asset_name, :string, null: false
      add :partition, :string
      add :run_id, :uuid, null: false
      add :status, :string, null: false, default: "pending"
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :duration_ms, :integer
      add :upstream_assets, {:array, :string}
      add :upstream_partitions, {:array, :string}
      add :dependency_hash, :string
      add :metadata, :map, default: %{}
      add :error_message, :text
      add :executor_node, :string

      timestamps()
    end

    create index(:flowstone_materializations, [:asset_name, :partition])
    create index(:flowstone_materializations, [:run_id])
    create index(:flowstone_materializations, [:status])
  end
end
