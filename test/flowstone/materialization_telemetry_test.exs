defmodule FlowStone.MaterializationTelemetryTest do
  use FlowStone.TestCase, isolation: :full_isolation

  defmodule Pipeline do
    use FlowStone.Pipeline

    asset :a do
      execute fn _, _ -> {:ok, :a} end
    end
  end

  setup do
    {:ok, _} = start_supervised({FlowStone.Registry, name: :tele_registry})
    {:ok, _} = start_supervised({FlowStone.IO.Memory, name: :tele_mem})
    FlowStone.register(Pipeline, registry: :tele_registry)
    %{io_opts: [config: %{agent: :tele_mem}]}
  end

  test "emits telemetry events", %{io_opts: io_opts} do
    self = self()

    handler = fn event, meas, meta, pid ->
      send(pid, {:event, event, meas, meta})
    end

    :telemetry.attach_many(
      "telemetry-materialization-test",
      [
        [:flowstone, :materialization, :start],
        [:flowstone, :materialization, :stop]
      ],
      handler,
      self
    )

    result =
      FlowStone.materialize(:a,
        partition: :p,
        registry: :tele_registry,
        io: io_opts,
        resource_server: nil
      )

    assert result == :ok or match?({:ok, %Oban.Job{}}, result)

    FlowStone.ObanHelpers.drain()

    assert_receive {:event, [:flowstone, :materialization, :start], _, %{asset: :a}}
    assert_receive {:event, [:flowstone, :materialization, :stop], %{duration: _}, %{asset: :a}}
  after
    :telemetry.detach("telemetry-materialization-test")
  end
end
