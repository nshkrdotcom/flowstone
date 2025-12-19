defmodule FlowStone.Parallel.Execution do
  @moduledoc """
  Ecto schema for parallel execution tracking.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @statuses [:running, :joining, :completed, :failed]

  schema "flowstone_parallel_executions" do
    field :run_id, Ecto.UUID
    field :parent_asset, :string
    field :partition, :string
    field :status, Ecto.Enum, values: @statuses, default: :running
    field :branch_count, :integer
    field :completed_count, :integer, default: 0
    field :failed_count, :integer, default: 0
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          run_id: Ecto.UUID.t(),
          parent_asset: String.t(),
          partition: String.t() | nil,
          status: atom(),
          branch_count: non_neg_integer(),
          completed_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          metadata: map(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @required_fields [:run_id, :parent_asset, :branch_count, :status]
  @optional_fields [:partition, :completed_count, :failed_count, :metadata]

  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(execution, attrs) do
    execution
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:branch_count, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
  end
end
