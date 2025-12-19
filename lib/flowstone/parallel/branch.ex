defmodule FlowStone.Parallel.Branch do
  @moduledoc """
  Ecto schema for parallel branch status tracking.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:pending, :success, :failed, :skipped]

  schema "flowstone_parallel_branches" do
    belongs_to :execution, FlowStone.Parallel.Execution
    field :branch_name, :string
    field :final_asset, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :materialization_id, :binary_id
    field :error, :map
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          execution_id: Ecto.UUID.t(),
          branch_name: String.t(),
          final_asset: String.t(),
          status: atom(),
          materialization_id: Ecto.UUID.t() | nil,
          error: map() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @required_fields [:execution_id, :branch_name, :final_asset, :status]
  @optional_fields [:materialization_id, :error, :started_at, :completed_at]

  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(branch, attrs) do
    branch
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
  end
end
