defmodule FlowStone.Repo.Migrations.CreateSignalGateTables do
  use Ecto.Migration

  def change do
    # Signal gates table - tracks durable suspension points
    create table(:flowstone_signal_gates, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :materialization_id,
          references(:flowstone_materializations, type: :uuid, on_delete: :delete_all),
          null: false

      # Token (the signed version is sent to external service)
      add :token, :string, null: false
      add :token_hash, :string, null: false

      # Status
      add :status, :string, default: "waiting", null: false

      # Timeout handling
      add :timeout_at, :utc_datetime_usec
      add :timeout_action, :string, default: "fail"
      add :timeout_retries, :integer, default: 0
      add :max_timeout_retries, :integer, default: 3

      # Signal data
      add :signaled_at, :utc_datetime_usec
      add :signal_payload, :jsonb
      add :signal_source_ip, :string
      add :signal_headers, :jsonb

      # Metadata
      add :metadata, :jsonb, default: "{}"

      timestamps(type: :utc_datetime_usec)
    end

    # Unique on token_hash for secure lookup
    create unique_index(:flowstone_signal_gates, [:token_hash])

    # For timeout worker queries
    create index(:flowstone_signal_gates, [:timeout_at],
             where: "status = 'waiting'",
             name: :signal_gates_pending_timeout_idx
           )

    # For materialization lookup
    create unique_index(:flowstone_signal_gates, [:materialization_id])

    # Status tracking
    create index(:flowstone_signal_gates, [:status])
  end
end
