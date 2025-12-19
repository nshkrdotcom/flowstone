defmodule FlowStone.Materialization do
  @moduledoc """
  Ecto schema for materialization metadata.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @statuses [:pending, :running, :success, :failed, :waiting_approval, :skipped]

  schema "flowstone_materializations" do
    field :asset_name, :string
    field :partition, :string
    field :run_id, Ecto.UUID
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :upstream_assets, {:array, :string}
    field :upstream_partitions, {:array, :string}
    field :dependency_hash, :string
    field :metadata, :map, default: %{}
    field :error_message, :string
    field :executor_node, :string

    timestamps()
  end

  @doc """
  Build a changeset for inserting/updating materializations.
  """
  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [
      :asset_name,
      :partition,
      :run_id,
      :status,
      :started_at,
      :completed_at,
      :duration_ms,
      :upstream_assets,
      :upstream_partitions,
      :dependency_hash,
      :metadata,
      :error_message,
      :executor_node
    ])
    |> validate_required([:asset_name, :run_id, :status])
  end
end
