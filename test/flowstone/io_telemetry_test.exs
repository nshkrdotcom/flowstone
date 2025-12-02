defmodule FlowStone.IOTelemetryTest do
  use FlowStone.TestCase, isolation: :full_isolation

  test "emits telemetry around load/store" do
    {:ok, _} = start_supervised({FlowStone.IO.Memory, name: :telemetry_mem})
    io_opts = [config: %{agent: :telemetry_mem}]
    parent = self()

    :telemetry.attach_many(
      "io-telemetry-test",
      [
        [:flowstone, :io, :load, :start],
        [:flowstone, :io, :load, :stop],
        [:flowstone, :io, :store, :start],
        [:flowstone, :io, :store, :stop]
      ],
      fn event, _meas, metadata, _ ->
        send(parent, {:io_event, event, metadata})
      end,
      nil
    )

    :ok = FlowStone.IO.store(:asset, :data, :p, io_opts)
    assert {:ok, :data} = FlowStone.IO.load(:asset, :p, io_opts)

    assert_receive {:io_event, [:flowstone, :io, :store, :start], _}
    assert_receive {:io_event, [:flowstone, :io, :store, :stop], _}
    assert_receive {:io_event, [:flowstone, :io, :load, :start], _}
    assert_receive {:io_event, [:flowstone, :io, :load, :stop], _}
  after
    :telemetry.detach("io-telemetry-test")
  end
end
