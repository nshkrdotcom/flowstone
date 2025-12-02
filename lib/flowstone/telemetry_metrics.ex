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
      summary("flowstone.materialization.duration", unit: {:native, :millisecond}),
      counter("flowstone.materialization.count"),
      counter("flowstone.materialization.exception"),
      summary("flowstone.io.load.duration", unit: {:native, :millisecond}),
      summary("flowstone.io.store.duration", unit: {:native, :millisecond}),
      counter("flowstone.checkpoint.requested"),
      counter("flowstone.checkpoint.approved"),
      counter("flowstone.checkpoint.rejected")
    ]
  end
end
