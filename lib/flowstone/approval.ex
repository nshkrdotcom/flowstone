defmodule FlowStone.Approval do
  @moduledoc """
  Ecto schema for checkpoint approvals.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @statuses [:pending, :approved, :modified, :rejected, :escalated, :expired]

  @type status :: :pending | :approved | :modified | :rejected | :escalated | :expired

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          materialization_id: Ecto.UUID.t() | nil,
          checkpoint_name: String.t() | nil,
          message: String.t() | nil,
          context: map() | nil,
          timeout_at: DateTime.t() | nil,
          status: status(),
          decision_by: String.t() | nil,
          decision_at: DateTime.t() | nil,
          reason: String.t() | nil,
          modifications: map() | nil,
          escalated_to: String.t() | nil,
          escalation_count: non_neg_integer(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

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
