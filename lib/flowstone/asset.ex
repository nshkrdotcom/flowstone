defmodule FlowStone.Asset do
  @moduledoc """
  Core asset definition used by the FlowStone DSL.

  An asset captures the contract for a materialized data artifact, including
  dependencies and the function that computes it.
  """

  @enforce_keys [:name, :module, :line]
  defstruct [
    :name,
    :module,
    :line,
    :description,
    :io_manager,
    :partitioned_by,
    :partition_fn,
    :execute_fn,
    # Scatter support
    :scatter_fn,
    :scatter_options,
    :gather_fn,
    # Signal Gate support
    :on_signal_fn,
    :on_timeout_fn,
    metadata: %{},
    tags: [],
    depends_on: [],
    requires: []
  ]

  @type name :: atom()

  @type t :: %__MODULE__{
          name: name(),
          module: module(),
          line: non_neg_integer(),
          description: String.t() | nil,
          io_manager: atom() | module() | nil,
          partitioned_by: term(),
          partition_fn: (term() -> term()) | nil,
          execute_fn: (any(), map() -> {:ok, term()} | {:error, term()}) | nil,
          scatter_fn: (map() -> [map()]) | nil,
          scatter_options: map() | nil,
          gather_fn: (map() -> term()) | nil,
          on_signal_fn: (map(), map() -> {:ok, term()} | {:error, term()}) | nil,
          on_timeout_fn: (map() -> {:retry, keyword()} | {:error, term()}) | nil,
          metadata: map(),
          tags: [atom()],
          depends_on: [name()],
          requires: [atom()]
        }
end
