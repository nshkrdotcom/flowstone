defmodule FlowStone.Sensors.S3FileArrival do
  @moduledoc """
  Sensor that triggers on new S3 object keys.
  """

  @behaviour FlowStone.Sensor

  def init(config) do
    {:ok,
     %{
       bucket: config.bucket,
       prefix: config.prefix,
       last_keys: MapSet.new(),
       partition_fn: config[:partition_fn] || (&default_partition/1),
       list_fun: config[:list_fun] || (&list_objects/2)
     }}
  end

  def poll(state) do
    case state.list_fun.(state.bucket, state.prefix) do
      {:ok, keys} ->
        new_keys = MapSet.difference(keys, state.last_keys)

        case MapSet.to_list(new_keys) do
          [] ->
            {:no_trigger, %{state | last_keys: keys}}

          [key | _] ->
            partition = state.partition_fn.(key)
            {:trigger, partition, %{state | last_keys: keys}}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp default_partition(key), do: key

  defp list_objects(bucket, prefix) do
    # Placeholder; in production use ExAws.S3.list_objects
    {:error, {:not_configured, bucket, prefix}}
  end
end
