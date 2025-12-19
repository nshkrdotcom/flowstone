defmodule FlowStone.Repo.Migrations.CreateParallelTables do
  use Ecto.Migration

  def change do
    create table(:flowstone_parallel_executions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :run_id, :uuid, null: false
      add :parent_asset, :string, null: false
      add :partition, :string
      add :status, :string, null: false
      add :branch_count, :integer, null: false
      add :completed_count, :integer, default: 0
      add :failed_count, :integer, default: 0
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:flowstone_parallel_executions, [:run_id, :parent_asset, :partition],
             name: :parallel_executions_run_asset_partition_idx
           )

    create index(:flowstone_parallel_executions, [:status])
    create index(:flowstone_parallel_executions, [:run_id])
    create index(:flowstone_parallel_executions, [:parent_asset])

    create table(:flowstone_parallel_branches, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :execution_id,
          references(:flowstone_parallel_executions, type: :uuid, on_delete: :delete_all),
          null: false

      add :branch_name, :string, null: false
      add :final_asset, :string, null: false
      add :status, :string, null: false
      add :materialization_id, :uuid
      add :error, :map
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:flowstone_parallel_branches, [:execution_id, :branch_name])
    create index(:flowstone_parallel_branches, [:execution_id, :status])
  end
end
