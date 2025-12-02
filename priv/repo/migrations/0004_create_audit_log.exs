defmodule FlowStone.Repo.Migrations.CreateAuditLog do
  use Ecto.Migration

  def change do
    create table(:flowstone_audit_log, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :event_type, :string, null: false
      add :actor_id, :string, null: false
      add :actor_type, :string, null: false
      add :resource_type, :string
      add :resource_id, :string
      add :action, :string
      add :details, :map, default: %{}
      add :correlation_id, :uuid
      add :client_ip, :string
      add :user_agent, :text
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:flowstone_audit_log, [:event_type])
    create index(:flowstone_audit_log, [:actor_id, :actor_type])
    create index(:flowstone_audit_log, [:resource_type, :resource_id])
    create index(:flowstone_audit_log, [:correlation_id])
    create index(:flowstone_audit_log, [:inserted_at])
  end
end
