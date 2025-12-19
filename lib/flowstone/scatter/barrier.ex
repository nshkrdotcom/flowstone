defmodule FlowStone.Scatter.Barrier do
  @moduledoc """
  Ecto schema for scatter barriers.

  A barrier tracks the completion status of a scattered execution,
  coordinating fan-out instances and triggering downstream assets
  when all instances complete.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FlowStone.Scatter.Options

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:pending, :executing, :completed, :partial_failure, :failed, :cancelled]
  @modes [:inline, :distributed]

  schema "flowstone_scatter_barriers" do
    field :run_id, Ecto.UUID
    field :asset_name, :string
    field :scatter_source_asset, :string
    field :partition, :string
    field :total_count, :integer
    field :completed_count, :integer, default: 0
    field :failed_count, :integer, default: 0
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :scatter_keys, {:array, :map}, default: []
    field :mode, Ecto.Enum, values: @modes, default: :inline
    field :reader_checkpoint, :map
    field :parent_barrier_id, Ecto.UUID
    field :batch_index, :integer
    field :options, :map, default: %{}
    field :metadata, :map, default: %{}
    # Batch fields
    field :batching_enabled, :boolean, default: false
    field :batch_count, :integer
    field :batch_options, :map

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          run_id: Ecto.UUID.t(),
          asset_name: String.t(),
          scatter_source_asset: String.t() | nil,
          partition: String.t() | nil,
          total_count: non_neg_integer(),
          completed_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          status: atom(),
          scatter_keys: [map()],
          mode: atom(),
          reader_checkpoint: map() | nil,
          parent_barrier_id: Ecto.UUID.t() | nil,
          batch_index: non_neg_integer() | nil,
          options: map(),
          metadata: map(),
          batching_enabled: boolean(),
          batch_count: non_neg_integer() | nil,
          batch_options: map() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @required_fields [:run_id, :asset_name, :total_count]
  @optional_fields [
    :scatter_source_asset,
    :partition,
    :completed_count,
    :failed_count,
    :status,
    :scatter_keys,
    :mode,
    :reader_checkpoint,
    :parent_barrier_id,
    :batch_index,
    :options,
    :metadata,
    :batching_enabled,
    :batch_count,
    :batch_options
  ]

  @doc """
  Build a changeset for creating a new barrier.
  """
  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(barrier, attrs) do
    barrier
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:total_count, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:mode, @modes)
  end

  @doc """
  Create a barrier struct (not persisted).
  """
  @spec new(keyword()) :: t()
  def new(attrs) do
    struct(__MODULE__, attrs)
  end

  @doc """
  Get scatter options from a barrier.
  """
  @spec get_options(t()) :: Options.t()
  def get_options(%__MODULE__{options: options}) do
    Options.from_map(options)
  end

  @doc """
  Calculate progress as a percentage.
  """
  @spec progress(t()) :: float()
  def progress(%__MODULE__{total_count: 0}), do: 0.0

  def progress(%__MODULE__{total_count: total, completed_count: completed, failed_count: failed}) do
    (completed + failed) / total * 100.0
  end

  @doc """
  Check if barrier is complete (all instances finished, success or failure).
  """
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{total_count: total, completed_count: completed, failed_count: failed}) do
    completed + failed >= total
  end

  @doc """
  Calculate failure rate as a decimal.
  """
  @spec failure_rate(t()) :: float()
  def failure_rate(%__MODULE__{total_count: 0}), do: 0.0

  def failure_rate(%__MODULE__{total_count: total, failed_count: failed}) do
    failed / total
  end
end
