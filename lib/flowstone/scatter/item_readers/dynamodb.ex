defmodule FlowStone.Scatter.ItemReaders.DynamoDB do
  @moduledoc """
  DynamoDB ItemReader using ExAws.Dynamo scan/query.
  """

  @behaviour FlowStone.Scatter.ItemReader

  @impl true
  def init(config, _deps) when is_map(config) do
    with :ok <- ensure_dependency(config) do
      {:ok,
       %{
         table: config[:table],
         index: config[:index],
         key_condition: config[:key_condition],
         filter_expression: config[:filter_expression],
         expression_attribute_values: config[:expression_attribute_values],
         expression_attribute_names: config[:expression_attribute_names],
         projection_expression: config[:projection_expression],
         consistent_read: config[:consistent_read],
         max_items: config[:max_items],
         reader_batch_size: config[:reader_batch_size],
         last_evaluated_key: nil,
         read_count: 0,
         done: false,
         dynamo_module: config[:dynamo_module] || ExAws.Dynamo,
         ex_aws: config[:ex_aws_module] || ExAws
       }}
    end
  end

  @impl true
  def read(state, batch_size) do
    if state.done or reached_max?(state) do
      {:ok, [], :halt}
    else
      fetch_batch(state, batch_size)
    end
  end

  @impl true
  def count(_state), do: :unknown

  @impl true
  def checkpoint(state) do
    %{
      "last_evaluated_key" => state.last_evaluated_key,
      "read_count" => state.read_count,
      "done" => state.done
    }
  end

  @impl true
  def restore(state, checkpoint) do
    %{
      state
      | last_evaluated_key: checkpoint["last_evaluated_key"],
        read_count: checkpoint["read_count"] || 0,
        done: checkpoint["done"] || false
    }
  end

  @impl true
  def close(_state), do: :ok

  defp ensure_dependency(config) do
    ex_aws = config[:ex_aws_module] || ExAws
    dynamo = config[:dynamo_module] || ExAws.Dynamo

    if Code.ensure_loaded?(ex_aws) and Code.ensure_loaded?(dynamo) do
      :ok
    else
      {:error, {:missing_dependency, :ex_aws_dynamo}}
    end
  end

  defp next_key(%{last_evaluated_key: key}), do: key
  defp next_key(%{"LastEvaluatedKey" => key}), do: key
  defp next_key(_), do: nil

  defp fetch_batch(state, batch_size) do
    opts = build_opts(state, batch_size)
    operation = build_operation(state, opts)

    case state.ex_aws.request(operation) do
      {:ok, %{body: body}} ->
        handle_response(state, body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_opts(state, batch_size) do
    limit =
      case state.reader_batch_size do
        nil -> batch_size
        size -> min(batch_size, size)
      end

    []
    |> maybe_put(:index_name, state.index)
    |> maybe_put(:key_condition_expression, state.key_condition)
    |> maybe_put(:filter_expression, state.filter_expression)
    |> maybe_put(:expression_attribute_values, state.expression_attribute_values)
    |> maybe_put(:expression_attribute_names, state.expression_attribute_names)
    |> maybe_put(:projection_expression, state.projection_expression)
    |> maybe_put(:consistent_read, state.consistent_read)
    |> maybe_put(:exclusive_start_key, state.last_evaluated_key)
    |> maybe_put(:limit, limit)
  end

  defp build_operation(state, opts) do
    if state.key_condition do
      state.dynamo_module.query(state.table, opts)
    else
      state.dynamo_module.scan(state.table, opts)
    end
  end

  defp handle_response(state, body) do
    items = Map.get(body, :items) || Map.get(body, "Items") || []
    new_count = state.read_count + length(items)
    next_key = next_key(body)

    new_state = %{
      state
      | last_evaluated_key: next_key,
        read_count: new_count,
        done: next_key == nil or reached_max?(%{state | read_count: new_count})
    }

    {:ok, items, new_state}
  end

  defp reached_max?(%{max_items: nil}), do: false
  defp reached_max?(%{read_count: count, max_items: max}) when count >= max, do: true
  defp reached_max?(_state), do: false

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
