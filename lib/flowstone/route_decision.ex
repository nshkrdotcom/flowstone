defmodule FlowStone.RouteDecision do
  @moduledoc """
  Ecto schema for persisted routing decisions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "flowstone_route_decisions" do
    field :run_id, Ecto.UUID
    field :router_asset, :string
    field :partition, :string
    field :selected_branch, :string
    field :available_branches, {:array, :string}, default: []
    field :input_hash, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          run_id: Ecto.UUID.t(),
          router_asset: String.t(),
          partition: String.t() | nil,
          selected_branch: String.t() | nil,
          available_branches: [String.t()],
          input_hash: String.t() | nil,
          metadata: map(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @required_fields [:run_id, :router_asset, :available_branches]
  @optional_fields [:partition, :selected_branch, :input_hash, :metadata]

  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
