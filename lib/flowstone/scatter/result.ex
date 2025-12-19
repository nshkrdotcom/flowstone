defmodule FlowStone.Scatter.Result do
  @moduledoc """
  Ecto schema for individual scatter results.

  Stores the result of each scattered instance for efficient
  gathering by downstream assets.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:pending, :executing, :completed, :failed]

  schema "flowstone_scatter_results" do
    belongs_to :barrier, FlowStone.Scatter.Barrier

    field :scatter_key_hash, :string
    field :scatter_key, :map
    field :scatter_index, :integer
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :result, :binary
    field :error, :map
    field :duration_ms, :integer
    field :completed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          barrier_id: Ecto.UUID.t(),
          scatter_key_hash: String.t(),
          scatter_key: map(),
          scatter_index: non_neg_integer(),
          status: atom(),
          result: binary() | nil,
          error: map() | nil,
          duration_ms: non_neg_integer() | nil,
          completed_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @required_fields [:barrier_id, :scatter_key_hash, :scatter_key]
  @optional_fields [:scatter_index, :status, :result, :error, :duration_ms, :completed_at]

  @doc """
  Build a changeset for creating a result.
  """
  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(result, attrs) do
    result
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:barrier_id)
  end

  @doc """
  Build a changeset for recording completion.
  """
  @spec complete_changeset(t(), binary()) :: Ecto.Changeset.t()
  def complete_changeset(result, compressed_result) do
    change(result, %{
      status: :completed,
      result: compressed_result,
      completed_at: DateTime.utc_now()
    })
  end

  @doc """
  Build a changeset for recording failure.
  """
  @spec fail_changeset(t(), map()) :: Ecto.Changeset.t()
  def fail_changeset(result, error_map) do
    change(result, %{
      status: :failed,
      error: error_map,
      completed_at: DateTime.utc_now()
    })
  end

  @doc """
  Compress a result value for storage.
  Uses :erlang.term_to_binary with compression.
  """
  @spec compress(term()) :: binary()
  def compress(value) do
    :erlang.term_to_binary(value, [:compressed])
  end

  @doc """
  Decompress a stored result value.
  Uses safe binary_to_term with [:safe] option.
  """
  @spec decompress(binary()) :: term()
  def decompress(binary) when is_binary(binary) do
    :erlang.binary_to_term(binary, [:safe])
  end

  def decompress(nil), do: nil
end
