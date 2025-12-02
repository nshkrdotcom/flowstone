defmodule FlowStone.Sensors.Worker do
  @moduledoc """
  Generic sensor polling worker.
  """

  use GenServer
  require Logger

  def start_link(sensor) do
    GenServer.start_link(__MODULE__, sensor)
  end

  @impl true
  def init(sensor) do
    {:ok, state} = sensor.module.init(sensor.config)
    schedule_poll(sensor.poll_interval)
    {:ok, %{sensor: sensor, state: state}}
  end

  @impl true
  def handle_info(:poll, %{sensor: sensor, state: state} = data) do
    new_state =
      case sensor.module.poll(state) do
        {:trigger, partition, next} ->
          sensor.on_trigger.(partition)

          FlowStone.PubSub.broadcast(
            "sensors",
            {:sensor_triggered, sensor.name},
            sensor.pubsub || FlowStone.PubSub.Server
          )

          next

        {:no_trigger, next} ->
          next

        {:error, reason, next} ->
          Logger.warning("Sensor #{sensor.name} poll failed: #{inspect(reason)}")
          next
      end

    schedule_poll(sensor.poll_interval)
    {:noreply, %{data | state: new_state}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end
end
