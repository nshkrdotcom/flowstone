defmodule FlowStone.Lineage.Entry do
  @moduledoc """
  Ecto schema representing lineage consumption between assets.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "flowstone_lineage" do
    field :asset_name, :string
    field :partition, :string
    field :run_id, Ecto.UUID
    field :upstream_asset, :string
    field :upstream_partition, :string
    field :upstream_materialization_id, :binary_id
    field :consumed_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [
      :asset_name,
      :partition,
      :run_id,
      :upstream_asset,
      :upstream_partition,
      :upstream_materialization_id,
      :consumed_at
    ])
    |> validate_required([:asset_name, :upstream_asset, :consumed_at])
  end
end
