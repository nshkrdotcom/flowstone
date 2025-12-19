defmodule FlowStone.Scatter.ItemReaders.S3 do
  @moduledoc """
  S3 ItemReader using ExAws.S3 list_objects_v2.
  """

  @behaviour FlowStone.Scatter.ItemReader

  @max_keys 1000

  @impl true
  def init(config, _deps) when is_map(config) do
    with :ok <- ensure_dependency(config) do
      if delay = config[:consistency_delay_ms] do
        Process.sleep(delay)
      end

      bucket = config[:bucket]
      prefix = config[:prefix]
      max_items = config[:max_items]
      start_after = config[:start_after]
      suffix = config[:suffix]

      reader_batch_size = config[:reader_batch_size] || @max_keys
      max_keys = min(reader_batch_size, @max_keys)

      {:ok,
       %{
         bucket: bucket,
         prefix: prefix,
         max_items: max_items,
         start_after: start_after,
         suffix: suffix,
         max_keys: max_keys,
         continuation_token: nil,
         read_count: 0,
         done: false,
         ex_aws: config[:ex_aws_module] || ExAws,
         s3_module: config[:s3_module] || ExAws.S3
       }}
    end
  end

  @impl true
  def read(state, batch_size) do
    limit = min(batch_size, state.max_keys)

    cond do
      state.done ->
        {:ok, [], :halt}

      reached_max?(state) ->
        {:ok, [], :halt}

      true ->
        opts =
          []
          |> maybe_put(:prefix, state.prefix)
          |> maybe_put(:start_after, state.start_after)
          |> maybe_put(:continuation_token, state.continuation_token)
          |> Keyword.put(:max_keys, min(limit, @max_keys))

        opts =
          if state.continuation_token do
            Keyword.delete(opts, :start_after)
          else
            opts
          end

        operation = state.s3_module.list_objects_v2(state.bucket, opts)

        case state.ex_aws.request(operation) do
          {:ok, %{body: body}} ->
            items =
              body
              |> extract_items()
              |> filter_suffix(state.suffix)

            new_count = state.read_count + length(items)
            done = done_reading?(body, %{state | read_count: new_count})

            new_state = %{
              state
              | continuation_token: next_token(body),
                read_count: new_count,
                done: done
            }

            {:ok, items, new_state}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl true
  def count(_state), do: :unknown

  @impl true
  def checkpoint(state) do
    %{
      "continuation_token" => state.continuation_token,
      "read_count" => state.read_count,
      "done" => state.done
    }
  end

  @impl true
  def restore(state, checkpoint) do
    %{
      state
      | continuation_token: checkpoint["continuation_token"],
        read_count: checkpoint["read_count"] || 0,
        done: checkpoint["done"] || false
    }
  end

  @impl true
  def close(_state), do: :ok

  defp ensure_dependency(config) do
    ex_aws = config[:ex_aws_module] || ExAws
    s3_module = config[:s3_module] || ExAws.S3

    if Code.ensure_loaded?(ex_aws) and Code.ensure_loaded?(s3_module) do
      :ok
    else
      {:error, {:missing_dependency, :ex_aws_s3}}
    end
  end

  defp extract_items(%{contents: contents}), do: List.wrap(contents)
  defp extract_items(%{"Contents" => contents}), do: List.wrap(contents)
  defp extract_items(_), do: []

  defp next_token(%{next_continuation_token: token}), do: token
  defp next_token(%{"NextContinuationToken" => token}), do: token
  defp next_token(_), do: nil

  defp done_reading?(body, state) do
    truncated? = Map.get(body, :is_truncated) || Map.get(body, "IsTruncated")
    reached_max?(state) or not truncated?
  end

  defp filter_suffix(items, nil), do: items

  defp filter_suffix(items, suffix) do
    Enum.filter(items, fn item ->
      key = Map.get(item, :key) || Map.get(item, "Key")
      is_binary(key) and String.ends_with?(key, suffix)
    end)
  end

  defp reached_max?(%{max_items: nil}), do: false
  defp reached_max?(%{read_count: count, max_items: max}) when count >= max, do: true
  defp reached_max?(_state), do: false

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
