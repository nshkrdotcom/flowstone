defmodule FlowStone.SignalGate.Gate do
  @moduledoc """
  Ecto schema for signal gates.

  A gate represents a durable suspension point where execution
  pauses and waits for an external signal (webhook, callback).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:waiting, :signaled, :timeout, :cancelled, :expired]
  @timeout_actions [:retry, :fail, :cancel]

  schema "flowstone_signal_gates" do
    belongs_to :materialization, FlowStone.Materialization

    field :token, :string
    field :token_hash, :string

    field :status, Ecto.Enum, values: @statuses, default: :waiting

    field :timeout_at, :utc_datetime_usec
    field :timeout_action, Ecto.Enum, values: @timeout_actions, default: :fail
    field :timeout_retries, :integer, default: 0
    field :max_timeout_retries, :integer, default: 3

    field :signaled_at, :utc_datetime_usec
    field :signal_payload, :map
    field :signal_source_ip, :string
    field :signal_headers, :map

    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          materialization_id: Ecto.UUID.t(),
          token: String.t(),
          token_hash: String.t(),
          status: atom(),
          timeout_at: DateTime.t() | nil,
          timeout_action: atom(),
          timeout_retries: non_neg_integer(),
          max_timeout_retries: non_neg_integer(),
          signaled_at: DateTime.t() | nil,
          signal_payload: map() | nil,
          signal_source_ip: String.t() | nil,
          signal_headers: map() | nil,
          metadata: map(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @required_fields [:materialization_id, :token, :token_hash]
  @optional_fields [
    :status,
    :timeout_at,
    :timeout_action,
    :timeout_retries,
    :max_timeout_retries,
    :signaled_at,
    :signal_payload,
    :signal_source_ip,
    :signal_headers,
    :metadata
  ]

  @doc """
  Build a changeset for creating a new gate.
  """
  @spec create_changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(gate, attrs) do
    gate
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:timeout_action, @timeout_actions)
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:materialization_id)
  end

  @doc """
  Build a changeset for recording a signal.
  """
  @spec signal_changeset(t(), map(), String.t() | nil, map() | nil) :: Ecto.Changeset.t()
  def signal_changeset(gate, payload, source_ip, headers) do
    change(gate, %{
      status: :signaled,
      signaled_at: DateTime.utc_now(),
      signal_payload: payload,
      signal_source_ip: source_ip,
      signal_headers: headers
    })
  end

  @doc """
  Build a changeset for timeout handling.
  """
  @spec timeout_changeset(t()) :: Ecto.Changeset.t()
  def timeout_changeset(gate) do
    if gate.timeout_retries < gate.max_timeout_retries and gate.timeout_action == :retry do
      change(gate, %{
        timeout_retries: gate.timeout_retries + 1,
        timeout_at:
          DateTime.add(DateTime.utc_now(), retry_delay(gate.timeout_retries), :millisecond)
      })
    else
      change(gate, %{status: :timeout})
    end
  end

  @doc """
  Check if gate can accept a signal.
  """
  @spec can_signal?(t()) :: boolean()
  def can_signal?(%__MODULE__{status: :waiting}), do: true
  def can_signal?(_), do: false

  @doc """
  Check if gate has timed out.
  """
  @spec timed_out?(t()) :: boolean()
  def timed_out?(%__MODULE__{timeout_at: nil}), do: false

  def timed_out?(%__MODULE__{timeout_at: timeout_at, status: :waiting}) do
    DateTime.compare(DateTime.utc_now(), timeout_at) == :gt
  end

  def timed_out?(_), do: false

  @doc """
  Calculate wait duration in milliseconds.
  """
  @spec wait_duration_ms(t()) :: non_neg_integer()
  def wait_duration_ms(%__MODULE__{inserted_at: created, signaled_at: signaled})
      when not is_nil(signaled) do
    DateTime.diff(signaled, created, :millisecond)
  end

  def wait_duration_ms(%__MODULE__{inserted_at: created}) do
    DateTime.diff(DateTime.utc_now(), created, :millisecond)
  end

  # Exponential backoff: 5min, 15min, 45min
  defp retry_delay(attempt) do
    trunc(:math.pow(3, attempt) * 5 * 60 * 1000)
  end
end
