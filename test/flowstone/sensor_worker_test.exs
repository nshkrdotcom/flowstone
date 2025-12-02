defmodule FlowStone.SensorWorkerTest do
  use FlowStone.TestCase, isolation: :full_isolation

  defmodule DummySensor do
    @behaviour FlowStone.Sensor

    def init(config), do: {:ok, config}

    def poll(%{trigger?: true} = state), do: {:trigger, :partition, %{state | trigger?: false}}
    def poll(state), do: {:no_trigger, state}
  end

  test "triggers on poll and broadcasts" do
    {:ok, _} =
      start_supervised({FlowStone.PubSub, name: :sensor_pubsub, adapter: Phoenix.PubSub.PG2})

    :ok = FlowStone.PubSub.subscribe("sensors", :sensor_pubsub)

    test_pid = self()

    sensor = %{
      name: :dummy,
      module: DummySensor,
      config: %{trigger?: true},
      poll_interval: 10,
      on_trigger: fn _partition -> send(test_pid, :triggered_from_sensor) end,
      pubsub: :sensor_pubsub
    }

    {:ok, pid} = start_supervised({FlowStone.Sensors.Worker, sensor})

    send(pid, :poll)

    assert_receive :triggered_from_sensor
    assert_receive {:sensor_triggered, :dummy}
  end
end
