defmodule FlowStone.Telemetry do
  @moduledoc """
  Central event names for FlowStone telemetry.
  """

  @events [
    [:flowstone, :materialization, :start],
    [:flowstone, :materialization, :stop],
    [:flowstone, :materialization, :exception],
    [:flowstone, :io, :load, :start],
    [:flowstone, :io, :load, :stop],
    [:flowstone, :io, :store, :start],
    [:flowstone, :io, :store, :stop],
    [:flowstone, :checkpoint, :requested],
    [:flowstone, :checkpoint, :approved],
    [:flowstone, :checkpoint, :rejected],
    [:flowstone, :checkpoint, :timeout],
    [:flowstone, :sensor, :poll],
    [:flowstone, :sensor, :trigger],
    [:flowstone, :error]
  ]

  def events, do: @events
end
