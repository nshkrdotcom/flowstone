defmodule FlowStone.Repo.Migrations.CreateLineage do
  use Ecto.Migration

  def change do
    create table(:flowstone_lineage, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :asset_name, :string, null: false
      add :partition, :string
      add :run_id, :uuid
      add :upstream_asset, :string, null: false
      add :upstream_partition, :string
      add :upstream_materialization_id, :uuid
      add :consumed_at, :utc_datetime_usec, null: false

      timestamps()
    end

    create index(:flowstone_lineage, [:asset_name, :partition])
    create index(:flowstone_lineage, [:upstream_asset, :upstream_partition])
    create index(:flowstone_lineage, [:run_id])
  end
end
