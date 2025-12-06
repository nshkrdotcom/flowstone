defmodule Examples.TelemetryExample do
  @moduledoc false

  def run do
    ensure_started(FlowStone.Registry, name: :examples_telemetry_registry)
    ensure_started(FlowStone.IO.Memory, name: :examples_telemetry_io)

    FlowStone.register(Pipeline, registry: :examples_telemetry_registry)

    handler = fn event, measurements, metadata, pid ->
      send(pid, {:event, event, measurements, metadata})
    end

    :telemetry.attach_many(
      "examples-telemetry",
      [
        [:flowstone, :materialization, :start],
        [:flowstone, :materialization, :stop],
        [:flowstone, :materialization, :exception]
      ],
      handler,
      self()
    )

    FlowStone.materialize(:telemetry_asset,
      partition: :tele,
      registry: :examples_telemetry_registry,
      io: [config: %{agent: :examples_telemetry_io}],
      resource_server: nil
    )

    FlowStone.ObanHelpers.drain()

    events = collect_events([])
    :telemetry.detach("examples-telemetry")
    events
  end

  defp collect_events(acc) do
    receive do
      {:event, event, measurements, metadata} ->
        collect_events([{event, measurements, metadata} | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  defp ensure_started(mod, opts) do
    case Process.whereis(opts[:name]) do
      nil -> mod.start_link(opts)
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defmodule Pipeline do
    use FlowStone.Pipeline

    asset :telemetry_asset do
      execute fn _, _ -> {:ok, :telemetry_done} end
    end
  end
end
