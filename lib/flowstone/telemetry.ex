defmodule FlowStone.Telemetry do
  @moduledoc """
  Central event names for FlowStone telemetry.

  ## Materialization Events

  - `[:flowstone, :materialization, :start]` - Asset execution started
  - `[:flowstone, :materialization, :stop]` - Asset execution completed
  - `[:flowstone, :materialization, :exception]` - Asset execution failed

  ## Scatter Events

  - `[:flowstone, :scatter, :start]` - Scatter barrier created
  - `[:flowstone, :scatter, :complete]` - All scatter instances finished
  - `[:flowstone, :scatter, :failed]` - Scatter exceeded failure threshold
  - `[:flowstone, :scatter, :cancel]` - Scatter barrier cancelled
  - `[:flowstone, :scatter, :instance_complete]` - Single scatter instance completed
  - `[:flowstone, :scatter, :instance_fail]` - Single scatter instance failed
  - `[:flowstone, :scatter, :gather_ready]` - Scatter ready for downstream gather

  ## Signal Gate Events

  - `[:flowstone, :signal_gate, :create]` - Gate created, waiting for signal
  - `[:flowstone, :signal_gate, :signal]` - Signal received
  - `[:flowstone, :signal_gate, :timeout]` - Gate timed out
  - `[:flowstone, :signal_gate, :timeout_retry]` - Gate timeout, will retry
  - `[:flowstone, :signal_gate, :cancel]` - Gate cancelled

  ## Rate Limiting Events

  - `[:flowstone, :rate_limit, :check]` - Rate limit checked
  - `[:flowstone, :rate_limit, :wait]` - Operation rate limited
  - `[:flowstone, :rate_limit, :slot_acquired]` - Semaphore slot acquired
  - `[:flowstone, :rate_limit, :slot_released]` - Semaphore slot released
  """

  @events [
    # Materialization
    [:flowstone, :materialization, :start],
    [:flowstone, :materialization, :stop],
    [:flowstone, :materialization, :exception],
    # I/O
    [:flowstone, :io, :load, :start],
    [:flowstone, :io, :load, :stop],
    [:flowstone, :io, :store, :start],
    [:flowstone, :io, :store, :stop],
    # Checkpoints
    [:flowstone, :checkpoint, :requested],
    [:flowstone, :checkpoint, :approved],
    [:flowstone, :checkpoint, :rejected],
    [:flowstone, :checkpoint, :timeout],
    # Sensors
    [:flowstone, :sensor, :poll],
    [:flowstone, :sensor, :trigger],
    # Errors
    [:flowstone, :error],
    # Scatter
    [:flowstone, :scatter, :start],
    [:flowstone, :scatter, :complete],
    [:flowstone, :scatter, :failed],
    [:flowstone, :scatter, :cancel],
    [:flowstone, :scatter, :instance_complete],
    [:flowstone, :scatter, :instance_fail],
    [:flowstone, :scatter, :gather_ready],
    # Signal Gate
    [:flowstone, :signal_gate, :create],
    [:flowstone, :signal_gate, :signal],
    [:flowstone, :signal_gate, :timeout],
    [:flowstone, :signal_gate, :timeout_retry],
    [:flowstone, :signal_gate, :cancel],
    # Rate Limiting
    [:flowstone, :rate_limit, :check],
    [:flowstone, :rate_limit, :wait],
    [:flowstone, :rate_limit, :slot_acquired],
    [:flowstone, :rate_limit, :slot_released]
  ]

  def events, do: @events
end
