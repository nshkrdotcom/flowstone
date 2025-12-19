defmodule FlowStone.Scatter.Batcher do
  @moduledoc """
  Groups scatter items into batches for efficient execution.

  Batching is applied after item selection (scatter function or ItemReader).
  Each batch becomes a single scatter instance with shared batch context.

  ## Batching Strategies

  1. **Fixed size** (`max_items_per_batch`): Simple N-item batches
  2. **Size-based** (`max_bytes_per_batch` + `size_fn`): Batches by payload size
  3. **Grouping** (`group_by` + `max_items_per_group`): Group items first
  4. **Custom** (`batch_fn`): User-defined batching logic

  ## Example

      items = [%{id: 1}, %{id: 2}, %{id: 3}, %{id: 4}, %{id: 5}]
      opts = BatchOptions.new(max_items_per_batch: 2)

      batches = Batcher.batch(items, opts)
      # => [[%{id: 1}, %{id: 2}], [%{id: 3}, %{id: 4}], [%{id: 5}]]
  """

  alias FlowStone.Scatter.BatchOptions

  @type batch :: [map()]

  @doc """
  Group items into batches according to the provided options.

  Returns a list of batches, where each batch is a list of items.
  Empty batches are filtered from the result.
  """
  @spec batch([map()], BatchOptions.t()) :: [batch()]
  def batch([], _opts), do: []

  def batch(items, %BatchOptions{batch_fn: batch_fn}) when is_function(batch_fn, 1) do
    items
    |> batch_fn.()
    |> filter_empty_batches()
  end

  def batch(items, %BatchOptions{group_by: group_fn} = opts) when is_function(group_fn, 1) do
    items
    |> group_items(group_fn)
    |> batch_groups(opts)
    |> filter_empty_batches()
  end

  def batch(items, %BatchOptions{max_bytes_per_batch: max_bytes, size_fn: size_fn} = opts)
      when not is_nil(max_bytes) and is_function(size_fn, 1) do
    items
    |> batch_by_size(max_bytes, size_fn, opts.max_items_per_batch)
    |> filter_empty_batches()
  end

  def batch(items, %BatchOptions{max_items_per_batch: max_items}) do
    items
    |> Enum.chunk_every(max_items)
    |> filter_empty_batches()
  end

  @doc """
  Build batch context fields for a scatter context.

  Returns a map with batch-specific fields to merge into the scatter context.
  """
  @spec build_batch_context([map()], non_neg_integer(), non_neg_integer(), map() | nil) :: map()
  def build_batch_context(items, batch_index, batch_count, batch_input) do
    %{
      batch_index: batch_index,
      batch_count: batch_count,
      batch_items: items,
      batch_input: batch_input,
      scatter_key: %{
        "_batch" => true,
        "index" => batch_index,
        "item_count" => length(items)
      }
    }
  end

  @doc """
  Generate a batch scatter key for storage and tracking.
  """
  @spec batch_scatter_key(non_neg_integer(), non_neg_integer()) :: map()
  def batch_scatter_key(batch_index, item_count) do
    %{
      "_batch" => true,
      "index" => batch_index,
      "item_count" => item_count
    }
  end

  @doc """
  Evaluate batch_input function or return static value.

  Called once at scatter start to generate shared batch context.
  """
  @spec evaluate_batch_input((map() -> map()) | map() | nil, map()) :: map() | nil
  def evaluate_batch_input(nil, _deps), do: nil

  def evaluate_batch_input(batch_input, deps) when is_function(batch_input, 1),
    do: batch_input.(deps)

  def evaluate_batch_input(batch_input, _deps) when is_map(batch_input), do: batch_input

  # Private helpers

  defp group_items(items, group_fn) do
    Enum.group_by(items, group_fn)
  end

  defp batch_groups(grouped, opts) do
    max_per_group = opts.max_items_per_group || opts.max_items_per_batch

    grouped
    |> Map.values()
    |> Enum.flat_map(fn group_items ->
      Enum.chunk_every(group_items, max_per_group)
    end)
  end

  defp batch_by_size(items, max_bytes, size_fn, max_items) do
    {batches, current_batch, _current_size} =
      Enum.reduce(items, {[], [], 0}, fn item, {batches, current, current_size} ->
        item_size = size_fn.(item)

        cond do
          # Single item exceeds max - put it in its own batch
          item_size > max_bytes and current == [] ->
            {batches ++ [[item]], [], 0}

          # Single item exceeds max - flush current, start new with oversized item
          item_size > max_bytes ->
            {batches ++ [current, [item]], [], 0}

          # Adding item would exceed max bytes - flush current batch
          current_size + item_size > max_bytes ->
            {batches ++ [current], [item], item_size}

          # Adding item would exceed max items - flush current batch
          max_items && length(current) >= max_items ->
            {batches ++ [current], [item], item_size}

          # Add item to current batch
          true ->
            {batches, current ++ [item], current_size + item_size}
        end
      end)

    # Don't forget the last batch
    if current_batch == [] do
      batches
    else
      batches ++ [current_batch]
    end
  end

  defp filter_empty_batches(batches) do
    Enum.reject(batches, &(&1 == []))
  end
end
