defmodule FlowStone.Repo.Migrations.CreateScatterTables do
  use Ecto.Migration

  def change do
    # Scatter barriers table - tracks completion of scattered executions
    create table(:flowstone_scatter_barriers, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :run_id, :uuid, null: false
      add :asset_name, :string, null: false
      add :scatter_source_asset, :string
      add :partition, :string
      add :total_count, :integer, null: false
      add :completed_count, :integer, default: 0
      add :failed_count, :integer, default: 0
      add :status, :string, default: "pending", null: false
      add :scatter_keys, :jsonb, default: "[]"
      add :options, :jsonb, default: "{}"
      add :metadata, :jsonb, default: "{}"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:flowstone_scatter_barriers, [:run_id, :asset_name, :partition],
             name: :scatter_barriers_run_asset_partition_idx
           )

    create index(:flowstone_scatter_barriers, [:status])
    create index(:flowstone_scatter_barriers, [:run_id])
    create index(:flowstone_scatter_barriers, [:asset_name])

    # Scatter results table - stores individual instance results
    create table(:flowstone_scatter_results, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :barrier_id,
          references(:flowstone_scatter_barriers, type: :uuid, on_delete: :delete_all),
          null: false

      add :scatter_key_hash, :string, null: false
      add :scatter_key, :jsonb, null: false
      add :scatter_index, :integer
      add :status, :string, default: "pending", null: false
      add :result, :binary
      add :error, :jsonb
      add :duration_ms, :integer
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:flowstone_scatter_results, [:barrier_id, :scatter_key_hash],
             name: :scatter_results_barrier_key_idx
           )

    create index(:flowstone_scatter_results, [:barrier_id, :status])
    create index(:flowstone_scatter_results, [:barrier_id, :scatter_index])

    # Add scatter columns to materializations table
    alter table(:flowstone_materializations) do
      add :scatter_barrier_id,
          references(:flowstone_scatter_barriers, type: :uuid, on_delete: :nilify_all)

      add :scatter_key, :jsonb
      add :scatter_key_hash, :string
      add :scatter_index, :integer
    end

    create index(:flowstone_materializations, [:scatter_barrier_id])
    create index(:flowstone_materializations, [:scatter_key_hash])
  end
end
