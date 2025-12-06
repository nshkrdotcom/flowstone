defmodule Examples.SensorExample do
  @moduledoc false

  def run do
    ensure_started(FlowStone.Registry, name: :examples_sensor_registry)
    ensure_started(FlowStone.IO.Memory, name: :examples_sensor_io)

    FlowStone.register(Pipeline, registry: :examples_sensor_registry)

    sensor = %{
      name: :demo_sensor,
      module: FlowStone.Sensors.S3FileArrival,
      config: %{
        bucket: "demo-bucket",
        prefix: "incoming/",
        list_fun: &mock_list/2,
        partition_fn: &partition_from_key/1
      },
      poll_interval: 10,
      on_trigger: fn partition ->
        FlowStone.materialize_async(:sensor_asset,
          partition: partition,
          registry: :examples_sensor_registry,
          io: [config: %{agent: :examples_sensor_io}],
          resource_server: nil,
          use_repo: false
        )
      end,
      pubsub: FlowStone.PubSub.Server
    }

    {:ok, pid} = FlowStone.Sensors.Worker.start_link(sensor)

    send(pid, :poll)
    FlowStone.ObanHelpers.drain()

    FlowStone.IO.load(:sensor_asset, ~D[2024-01-01], config: %{agent: :examples_sensor_io})
  end

  defp mock_list(_bucket, _prefix) do
    {:ok, MapSet.new(["incoming/2024-01-01/data.csv"])}
  end

  defp partition_from_key(key) do
    key
    |> String.split("/")
    |> Enum.at(1)
    |> Date.from_iso8601!()
  end

  defp ensure_started(mod, opts) do
    case Process.whereis(opts[:name]) do
      nil -> mod.start_link(opts)
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defmodule Pipeline do
    use FlowStone.Pipeline

    asset :sensor_asset do
      partitioned_by(:date)
      execute fn ctx, _deps -> {:ok, {:from_sensor, ctx.partition}} end
    end
  end
end
