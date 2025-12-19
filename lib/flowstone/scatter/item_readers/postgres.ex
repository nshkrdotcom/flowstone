defmodule FlowStone.Scatter.ItemReaders.Postgres do
  @moduledoc """
  Postgres ItemReader using keyset pagination.
  """

  import Ecto.Query

  @behaviour FlowStone.Scatter.ItemReader

  @impl true
  def init(config, _deps) when is_map(config) do
    query = config[:query]
    cursor_field = config[:cursor_field]
    order = config[:order] || :asc
    start_after = config[:start_after]

    if is_nil(query) or is_nil(cursor_field) do
      {:error, :missing_query_or_cursor}
    else
      {:ok,
       %{
         query: query,
         cursor_field: cursor_field,
         order: order,
         last_value: start_after,
         max_items: config[:max_items],
         reader_batch_size: config[:reader_batch_size],
         read_count: 0,
         done: false,
         repo: config[:repo] || FlowStone.Repo,
         row_selector: config[:row_selector]
       }}
    end
  end

  @impl true
  def read(state, batch_size) do
    cond do
      state.done ->
        {:ok, [], :halt}

      reached_max?(state) ->
        {:ok, [], :halt}

      true ->
        limit =
          case state.reader_batch_size do
            nil -> batch_size
            size -> min(batch_size, size)
          end

        query =
          state.query
          |> apply_cursor(state)
          |> apply_order(state)
          |> limit(^limit)

        rows = state.repo.all(query)
        items = Enum.map(rows, &map_row(&1, state.row_selector))
        new_last = next_cursor(rows, state.cursor_field, state.order)
        new_count = state.read_count + length(rows)
        done = rows == [] or reached_max?(%{state | read_count: new_count})

        new_state = %{
          state
          | last_value: new_last,
            read_count: new_count,
            done: done
        }

        {:ok, items, new_state}
    end
  end

  @impl true
  def count(_state), do: :unknown

  @impl true
  def checkpoint(state) do
    %{
      "last_value" => state.last_value,
      "read_count" => state.read_count,
      "done" => state.done
    }
  end

  @impl true
  def restore(state, checkpoint) do
    %{
      state
      | last_value: checkpoint["last_value"],
        read_count: checkpoint["read_count"] || 0,
        done: checkpoint["done"] || false
    }
  end

  @impl true
  def close(_state), do: :ok

  defp apply_cursor(query, %{last_value: nil}), do: query

  defp apply_cursor(query, %{cursor_field: field, last_value: value, order: :asc}) do
    from(row in query, where: field(row, ^field) > ^value)
  end

  defp apply_cursor(query, %{cursor_field: field, last_value: value, order: :desc}) do
    from(row in query, where: field(row, ^field) < ^value)
  end

  defp apply_order(query, %{cursor_field: field, order: :desc}) do
    from(row in query, order_by: [desc: field(row, ^field)])
  end

  defp apply_order(query, %{cursor_field: field}) do
    from(row in query, order_by: [asc: field(row, ^field)])
  end

  defp next_cursor([], _field, _order), do: nil

  defp next_cursor(rows, field, _order) do
    row = List.last(rows)

    case row do
      %{^field => value} -> value
      struct when is_struct(struct) -> Map.get(struct, field)
      map when is_map(map) -> Map.get(map, field)
      _ -> nil
    end
  end

  defp map_row(row, selector) when is_function(selector, 1), do: selector.(row)

  defp map_row(row, _selector) when is_struct(row) do
    row
    |> Map.from_struct()
    |> Map.drop([:__meta__])
  end

  defp map_row(row, _selector) when is_map(row), do: row
  defp map_row(row, _selector), do: %{"value" => row}

  defp reached_max?(%{max_items: nil}), do: false
  defp reached_max?(%{read_count: count, max_items: max}) when count >= max, do: true
  defp reached_max?(_state), do: false
end
