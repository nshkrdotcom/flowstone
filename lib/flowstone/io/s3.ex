defmodule FlowStone.IO.S3 do
  @moduledoc """
  S3-backed I/O manager with injectable client functions for tests.
  """

  @behaviour FlowStone.IO.Manager

  @impl true
  def load(asset, partition, config) do
    get_fun = config[:get_fun] || fn _, _ -> {:error, :not_configured} end
    bucket = resolve_bucket(config, partition)
    key = resolve_key(asset, partition, config)
    get_fun.(bucket, key)
  end

  @impl true
  def store(asset, data, partition, config) do
    put_fun = config[:put_fun] || fn _, _, _ -> {:error, :not_configured} end
    bucket = resolve_bucket(config, partition)
    key = resolve_key(asset, partition, config)
    put_fun.(bucket, key, data)
  end

  @impl true
  def delete(_asset, _partition, _config), do: :ok

  @impl true
  def metadata(_asset, _partition, _config), do: {:error, :not_implemented}

  defp resolve_bucket(config, partition) do
    case config[:bucket] do
      fun when is_function(fun, 1) -> fun.(partition)
      bucket when is_binary(bucket) -> bucket
      _ -> "bucket"
    end
  end

  defp resolve_key(asset, partition, config) do
    case config[:path] do
      fun when is_function(fun, 1) -> fun.(partition)
      nil -> "#{asset}/#{FlowStone.Partition.serialize(partition)}.json"
      other -> other
    end
  end
end
