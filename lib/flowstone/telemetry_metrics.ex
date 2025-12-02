defmodule FlowStone.TelemetryMetrics do
  @moduledoc """
  Telemetry metrics definitions.
  """

  import Telemetry.Metrics

  def metrics do
    [
      counter("flowstone.error.count", tags: [:type, :asset, :retryable]),
      distribution("flowstone.io.load.duration",
        unit: {:native, :millisecond},
        tags: [:asset, :io_manager]
      ),
      distribution("flowstone.io.store.duration",
        unit: {:native, :millisecond},
        tags: [:asset, :io_manager]
      ),
      counter("flowstone.io.load.count", tags: [:asset, :io_manager]),
      counter("flowstone.io.store.count", tags: [:asset, :io_manager])
    ]
  end
end
