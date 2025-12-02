defmodule FlowStone.Approval do
  @moduledoc """
  Ecto schema for checkpoint approvals.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @statuses [:pending, :approved, :modified, :rejected, :escalated, :expired]

  schema "flowstone_approvals" do
    field :materialization_id, :binary_id
    field :checkpoint_name, :string
    field :message, :string
    field :context, :map
    field :timeout_at, :utc_datetime_usec
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :decision_by, :string
    field :decision_at, :utc_datetime_usec
    field :reason, :string
    field :modifications, :map
    field :escalated_to, :string
    field :escalation_count, :integer, default: 0

    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [
      :materialization_id,
      :checkpoint_name,
      :message,
      :context,
      :timeout_at,
      :status,
      :decision_by,
      :decision_at,
      :reason,
      :modifications,
      :escalated_to,
      :escalation_count
    ])
    |> validate_required([:checkpoint_name, :status])
  end
end
