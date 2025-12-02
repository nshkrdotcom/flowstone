defmodule FlowStone.Repo.Migrations.CreateApprovals do
  use Ecto.Migration

  def change do
    create table(:flowstone_approvals, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :materialization_id, :uuid
      add :checkpoint_name, :string, null: false
      add :message, :text
      add :context, :map
      add :timeout_at, :utc_datetime_usec
      add :status, :string, null: false, default: "pending"
      add :decision_by, :string
      add :decision_at, :utc_datetime_usec
      add :reason, :text
      add :modifications, :map
      add :escalated_to, :string
      add :escalation_count, :integer, default: 0

      timestamps()
    end

    create index(:flowstone_approvals, [:status])
    create index(:flowstone_approvals, [:timeout_at])
    create index(:flowstone_approvals, [:materialization_id])
  end
end
