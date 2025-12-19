defmodule FlowStone.Repo.Migrations.CreateRouteDecisions do
  use Ecto.Migration

  def change do
    create table(:flowstone_route_decisions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :run_id, :uuid, null: false
      add :router_asset, :string, null: false
      add :partition, :string
      add :selected_branch, :string
      add :available_branches, {:array, :string}, null: false
      add :input_hash, :string
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:flowstone_route_decisions, [:run_id, :router_asset, :partition])
  end
end
