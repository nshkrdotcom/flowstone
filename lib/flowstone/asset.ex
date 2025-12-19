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
    # Routing support
    :route_fn,
    :route_rules,
    :routed_from,
    # Scatter support
    :scatter_fn,
    :scatter_source,
    :scatter_source_config,
    :scatter_options,
    :item_selector_fn,
    :scatter_mode,
    :gather_fn,
    # Batch support
    :batch_options,
    # Signal Gate support
    :on_signal_fn,
    :on_timeout_fn,
    metadata: %{},
    tags: [],
    depends_on: [],
    optional_deps: [],
    route_error_policy: :fail,
    requires: [],
    parallel_branches: %{},
    parallel_options: %{},
    join_fn: nil
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
          route_fn: (map() -> atom() | nil | {:error, term()}) | nil,
          route_rules:
            %{choices: [{name(), (map() -> boolean())}], default: name() | nil}
            | nil,
          routed_from: name() | nil,
          optional_deps: [name()],
          route_error_policy: :fail | {:fallback, name()},
          scatter_fn: (map() -> [map()]) | nil,
          scatter_source: atom() | module() | nil,
          scatter_source_config: map() | nil,
          scatter_options: map() | nil,
          item_selector_fn: (map(), map() -> map()) | nil,
          scatter_mode: :inline | :distributed | nil,
          gather_fn: (map() -> term()) | nil,
          batch_options: map() | nil,
          parallel_branches: %{name() => FlowStone.ParallelBranch.t()} | map(),
          parallel_options: map() | nil,
          join_fn: (map() -> term()) | (map(), map() -> term()) | nil,
          on_signal_fn: (map(), map() -> {:ok, term()} | {:error, term()}) | nil,
          on_timeout_fn: (map() -> {:retry, keyword()} | {:error, term()}) | nil,
          metadata: map(),
          tags: [atom()],
          depends_on: [name()],
          requires: [atom()]
        }
end
