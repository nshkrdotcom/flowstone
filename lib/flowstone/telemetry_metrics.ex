defmodule FlowStone.TelemetryMetrics do
  @moduledoc """
  Telemetry metrics definitions for FlowStone.
  """

  import Telemetry.Metrics

  @doc """
  Return a list of metrics for materialization and IO events.
  """
  def metrics do
    [
      summary("flowstone.materialization.duration",
        event_name: [:flowstone, :materialization, :stop],
        measurement: :duration,
        unit: :millisecond
      ),
      counter("flowstone.materialization.start",
        event_name: [:flowstone, :materialization, :start]
      ),
      counter("flowstone.materialization.stop", event_name: [:flowstone, :materialization, :stop]),
      counter("flowstone.materialization.exception",
        event_name: [:flowstone, :materialization, :exception]
      ),
      summary("flowstone.io.load.duration",
        event_name: [:flowstone, :io, :load, :stop],
        measurement: :duration,
        unit: {:native, :millisecond}
      ),
      summary("flowstone.io.store.duration",
        event_name: [:flowstone, :io, :store, :stop],
        measurement: :duration,
        unit: {:native, :millisecond}
      ),
      counter("flowstone.checkpoint.requested", event_name: [:flowstone, :checkpoint, :requested]),
      counter("flowstone.checkpoint.approved", event_name: [:flowstone, :checkpoint, :approved]),
      counter("flowstone.checkpoint.rejected", event_name: [:flowstone, :checkpoint, :rejected]),
      counter("flowstone.checkpoint.timeout", event_name: [:flowstone, :checkpoint, :timeout])
    ]
  end
end
