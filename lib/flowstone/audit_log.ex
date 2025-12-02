defmodule FlowStone.AuditLog do
  @moduledoc """
  Immutable audit log schema.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "flowstone_audit_log" do
    field :event_type, :string
    field :actor_id, :string
    field :actor_type, :string
    field :resource_type, :string
    field :resource_id, :string
    field :action, :string
    field :details, :map
    field :correlation_id, Ecto.UUID
    field :client_ip, :string
    field :user_agent, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [
      :event_type,
      :actor_id,
      :actor_type,
      :resource_type,
      :resource_id,
      :action,
      :details,
      :correlation_id,
      :client_ip,
      :user_agent
    ])
    |> validate_required([:event_type, :actor_id, :actor_type])
  end
end
