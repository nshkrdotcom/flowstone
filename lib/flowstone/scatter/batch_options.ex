defmodule FlowStone.Scatter.BatchOptions do
  @moduledoc """
  Configuration options for scatter batching.

  Controls how scatter items are grouped into batches for more efficient
  execution patterns like ECS tasks or batch APIs.

  ## Batching Strategies

  - **Fixed size**: `max_items_per_batch` - Simple N-item batches
  - **Size-based**: `max_bytes_per_batch` + `size_fn` - Batches by payload size
  - **Grouping**: `group_by` + `max_items_per_group` - Group items before batching
  - **Custom**: `batch_fn` - Custom batching logic

  ## Example

      batch_options do
        max_items_per_batch 20
        batch_input fn deps -> %{region_id: deps.region.id} end
        on_item_error :fail_batch
      end
  """

  @type t :: %__MODULE__{
          max_items_per_batch: pos_integer(),
          max_bytes_per_batch: pos_integer() | nil,
          size_fn: (map() -> non_neg_integer()) | nil,
          group_by: (map() -> term()) | nil,
          max_items_per_group: pos_integer() | nil,
          batch_fn: ([map()] -> [[map()]]) | nil,
          batch_input: (map() -> map()) | map() | nil,
          on_item_error: :fail_batch | :collect_errors
        }

  defstruct max_items_per_batch: 10,
            max_bytes_per_batch: nil,
            size_fn: nil,
            group_by: nil,
            max_items_per_group: nil,
            batch_fn: nil,
            batch_input: nil,
            on_item_error: :fail_batch

  @doc """
  Build options from a keyword list.

  ## Options

  - `:max_items_per_batch` - Maximum items per batch (default: 10)
  - `:max_bytes_per_batch` - Maximum bytes per batch (requires `:size_fn`)
  - `:size_fn` - Function to calculate item size in bytes
  - `:group_by` - Function to group items before batching
  - `:max_items_per_group` - Maximum items per group (with `:group_by`)
  - `:batch_fn` - Custom batching function
  - `:batch_input` - Shared batch context (function or map)
  - `:on_item_error` - Error handling: `:fail_batch` or `:collect_errors`

  ## Examples

      iex> FlowStone.Scatter.BatchOptions.new(max_items_per_batch: 20)
      %FlowStone.Scatter.BatchOptions{max_items_per_batch: 20, ...}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts = Keyword.merge(default_opts(), opts)
    validate_opts!(opts)
    struct(__MODULE__, opts)
  end

  defp default_opts do
    [
      max_items_per_batch: 10,
      max_bytes_per_batch: nil,
      size_fn: nil,
      group_by: nil,
      max_items_per_group: nil,
      batch_fn: nil,
      batch_input: nil,
      on_item_error: :fail_batch
    ]
  end

  defp validate_opts!(opts) do
    max_items = Keyword.get(opts, :max_items_per_batch)

    if is_integer(max_items) and max_items <= 0 do
      raise ArgumentError, "max_items_per_batch must be a positive integer"
    end

    max_bytes = Keyword.get(opts, :max_bytes_per_batch)
    size_fn = Keyword.get(opts, :size_fn)

    if max_bytes && is_nil(size_fn) do
      raise ArgumentError, "max_bytes_per_batch requires size_fn to be set"
    end

    :ok
  end

  @doc """
  Convert options to a JSON-safe map for database storage.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = opts) do
    %{
      "max_items_per_batch" => opts.max_items_per_batch,
      "max_bytes_per_batch" => opts.max_bytes_per_batch,
      "on_item_error" => to_string(opts.on_item_error)
    }
    |> maybe_add_max_items_per_group(opts)
  end

  defp maybe_add_max_items_per_group(map, %{max_items_per_group: nil}), do: map

  defp maybe_add_max_items_per_group(map, %{max_items_per_group: max}),
    do: Map.put(map, "max_items_per_group", max)

  @doc """
  Restore options from a stored map.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      max_items_per_batch: map["max_items_per_batch"] || 10,
      max_bytes_per_batch: map["max_bytes_per_batch"],
      max_items_per_group: map["max_items_per_group"],
      on_item_error: safe_to_atom(map["on_item_error"], :fail_batch)
    }
  end

  defp safe_to_atom(nil, default), do: default

  defp safe_to_atom(str, default) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> default
  end

  defp safe_to_atom(atom, _default) when is_atom(atom), do: atom

  @doc """
  Check if batching is enabled for these options.
  """
  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{} = opts) do
    opts.max_items_per_batch != nil or
      opts.max_bytes_per_batch != nil or
      opts.group_by != nil or
      opts.batch_fn != nil
  end
end
